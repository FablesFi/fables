// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {FablesStableFee, StableFeeConfig} from "./base/FablesStableFee.sol";
import {FablesLedgerV2} from "./base/FablesLedgerV2.sol";
import {StableFeeCalculation} from "./libraries/StableFeeCalculation.sol";

/// @title FablesStableHookLite
/// @notice Stable-pair hook: StablePair fee with whitelist discount and the LP ledger. The reference price moves in
///         bounded steps and every swap can carry a minimum fee.
/// @dev Flags 0x2080 (beforeInitialize | beforeSwap). The swap entry is an assembly `fallback` around `_stableFee`.
contract FablesStableHookLite is FablesStableFee, FablesLedgerV2 {
    using PoolIdLibrary for PoolKey;

    // POOLS_SLOT = StateLibrary.POOLS_SLOT
    uint256 private constant SEL_BEFORE_SWAP = 0x575e24b4;
    uint256 private constant SEL_NOT_POOL_MANAGER = 0xae18210a;
    uint256 private constant SEL_HOOK_NOT_IMPLEMENTED = 0x0a85dc29;
    uint256 private constant OVERRIDE_FEE_FLAG = 0x400000;
    uint256 private constant SEL_EXTSLOAD = 0x1e2eaeaf;
    uint256 private constant POOLS_SLOT = 6;

    /// @notice Largest reference move per `updateReferencePrice` call, in price, 1e6 precision (1_000 = 0.1%).
    uint256 public constant MAX_REFERENCE_STEP_E6 = 1_000;
    /// @notice Minimum time between two reference moves on a pool, in seconds.
    uint256 public constant REFERENCE_UPDATE_INTERVAL = 60;
    uint256 internal constant MIN_REFERENCE_RATIO_X96 = Q96 * (1e6 - MAX_REFERENCE_STEP_E6) / 1e6;

    /// @notice Time of a pool's last reference move (0 = never moved).
    mapping(PoolId poolId => uint256 timestamp) public referenceUpdatedAt;

    error ReferenceStepTooLarge();
    error ReferenceUpdateTooSoon();

    event MinimumFeeSet(PoolId indexed poolId, uint16 minimumFee);

    constructor(IPoolManager poolManager_, address authority_) FablesStableFee(poolManager_, authority_) {
        Hooks.validateHookPermissions(IHooks(address(this)), _hookPermissions());
    }

    /// @notice Moves a pool's reference price by at most `MAX_REFERENCE_STEP_E6`, at most once per
    ///         `REFERENCE_UPDATE_INTERVAL`, and resets the fee state.
    function updateReferencePrice(PoolKey calldata key, uint160 referenceSqrtPriceX96) external restricted {
        PoolId poolId = key.toId();
        _checkPoolInitialized(poolId);
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp < referenceUpdatedAt[poolId] + REFERENCE_UPDATE_INTERVAL) revert ReferenceUpdateTooSoon();
        (uint24 k, uint24 optimalFeeE6, uint8 targetMultiplier, uint160 previous) = feeConfig(poolId);
        _validateReferenceSqrtPriceX96(referenceSqrtPriceX96);
        if (StableFeeCalculation.calculatePriceRatioX96(referenceSqrtPriceX96, previous) < MIN_REFERENCE_RATIO_X96) {
            revert ReferenceStepTooLarge();
        }
        referenceUpdatedAt[poolId] = block.timestamp;
        _resetFeeState(poolId);
        _writeFeeConfig(poolId, k, optimalFeeE6, targetMultiplier, referenceSqrtPriceX96);
        emit FeeConfigUpdated(poolId, StableFeeConfig(k, optimalFeeE6, targetMultiplier, referenceSqrtPriceX96));
    }

    /// @notice Sets a pool's minimum fee in pips: every swap pays at least it, no discount goes below it.
    /// @dev Lowering it resets the fee state (the falling fee restarts); 0 removes the minimum.
    function setMinimumFee(PoolKey calldata key, uint16 minimumFee_) external restricted {
        PoolId poolId = key.toId();
        _checkPoolInitialized(poolId);
        StableWords storage w = _words[poolId];
        uint256 st = w.state;
        w.state = (st & ~STATE_MIN_FEE_MASK) | (uint256(minimumFee_) << STATE_MIN_FEE_SHIFT);
        if (minimumFee_ < st >> STATE_MIN_FEE_SHIFT) _resetFeeState(poolId);
        emit MinimumFeeSet(poolId, minimumFee_);
    }

    /// @notice A pool's minimum fee in pips.
    function minimumFee(PoolId poolId) external view returns (uint16) {
        // the top 16 bits of the state word
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint16(_words[poolId].state >> STATE_MIN_FEE_SHIFT);
    }

    /// @notice beforeSwap entry; reverts NotPoolManager() for other callers, HookNotImplemented() for other selectors.
    /// @dev Calldata: sender 0x04, PoolKey 0x24..0xc4 (keccak = PoolId), zeroForOne 0xc4. The key is hashed and the
    ///      reply written at the free-memory pointer, which is never moved.
    fallback() external {
        address pm = address(poolManager);
        PoolId poolId;
        bool zeroForOne;
        address sender;
        uint160 sqrtP;
        assembly ("memory-safe") {
            if iszero(eq(caller(), pm)) {
                mstore(0x00, SEL_NOT_POOL_MANAGER)
                revert(0x1c, 0x04)
            }
            if iszero(eq(shr(224, calldataload(0x00)), SEL_BEFORE_SWAP)) {
                mstore(0x00, SEL_HOOK_NOT_IMPLEMENTED)
                revert(0x1c, 0x04)
            }
            let p := mload(0x40)
            calldatacopy(p, 0x24, 0xa0)
            poolId := keccak256(p, 0xa0)
            zeroForOne := iszero(iszero(calldataload(0xc4)))
            sender := and(calldataload(0x04), 0xffffffffffffffffffffffffffffffffffffffff)
            // slot0.sqrtPriceX96 = PoolManager.extsload(keccak256(poolId . POOLS_SLOT)), low 160 bits
            mstore(0x00, poolId)
            mstore(0x20, POOLS_SLOT)
            let slot := keccak256(0x00, 0x40)
            mstore(0x00, shl(224, SEL_EXTSLOAD))
            mstore(0x04, slot)
            // separate statement: returndatasize() must be read after the call (Yul evaluates right to left)
            let ok := staticcall(gas(), pm, 0x00, 0x24, 0x00, 0x20)
            if or(iszero(ok), lt(returndatasize(), 0x20)) { revert(0x00, 0x00) }
            sqrtP := and(mload(0x00), 0xffffffffffffffffffffffffffffffffffffffff)
        }
        uint24 fee = _stableFee(poolId, sqrtP, zeroForOne, sender);
        assembly ("memory-safe") {
            let p := mload(0x40)
            mstore(p, shl(224, SEL_BEFORE_SWAP))
            mstore(add(p, 0x20), 0) // BeforeSwapDeltaLibrary.ZERO_DELTA
            mstore(add(p, 0x40), or(fee, OVERRIDE_FEE_FLAG))
            return(p, 0x60)
        }
    }
}

/// @title FablesStableHookLiteTyped
/// @notice Test fixture, not for deployment: the same hook with a typed `beforeSwap` that shadows the fallback.
contract FablesStableHookLiteTyped is FablesStableHookLite {
    using PoolIdLibrary for PoolKey;

    constructor(IPoolManager poolManager_, address authority_) FablesStableHookLite(poolManager_, authority_) {}

    function beforeSwap(address sender, PoolKey calldata key, IPoolManager.SwapParams calldata params, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        return (
            IHooks.beforeSwap.selector,
            BeforeSwapDeltaLibrary.ZERO_DELTA,
            _stableFee(key.toId(), 0, params.zeroForOne, sender) | LPFeeLibrary.OVERRIDE_FEE_FLAG
        );
    }
}
