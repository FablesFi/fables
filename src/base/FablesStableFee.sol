// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {FablesHookCore} from "./FablesHookCore.sol";
import {StableFeeCalculation} from "../libraries/StableFeeCalculation.sol";
import {DiscountLib} from "../libraries/DiscountLib.sol";

/// @notice Per-pool fee config; same fields, order and widths as StablePair's `StableFeeConfig`.
struct StableFeeConfig {
    uint24 k; // per-block decay factor, Q24: share of the excess over the target fee kept each block
    uint24 optimalFeeE6; // optimal band half-width in price space, 1e6 precision (max 1e4 = 1%)
    uint8 targetMultiplier; // 1..100: target = far - close * targetMultiplier / 100
    uint160 referenceSqrtPriceX96;
}

/// @notice Fee state, written on the first swap of each clock block and reset by every config write.
struct StableFeeState {
    uint40 decayingFeeE12;
    uint160 sqrtAmmPriceX96;
    uint40 blockNumber;
}

/// @title FablesStableFee
/// @notice Uniswap StablePair's fee (v4-hooks-public @ e4eabe5, MIT) plus a per-pool whitelist discount applied after
///         it. Fees in pips.
/// @dev Same fee math, revert bytes and views as StablePair, except: the fee charged is capped at `STABLE_MAX_FEE`,
///      the formula reads the price clamped to within 10% of the reference, `targetMultiplier` >= 1, pools are
///      created only by `configureStablePool` (reference write-once), roles via AccessManager. Two words per pool;
///      bits below 216 (cfg) and 240 (state) follow StablePair's struct packing:
///        cfg    k [0,24) | optimalFeeE6 [24,48) | targetMultiplier [48,56) | referenceSqrtPriceX96 [56,216)
///               | bloom32 [216,248) | seed8 [248,256)
///        state  decayingFeeE12 [0,40) | sqrtAmmPriceX96 [40,200) | blockNumber [200,240) | spare [240,256)
abstract contract FablesStableFee is FablesHookCore {
    using LPFeeLibrary for uint24;
    using PoolIdLibrary for PoolKey;

    error InvalidK(uint256 k);
    error InvalidOptimalFeeE6(uint256 optimalFeeE6);
    error InvalidReferenceSqrtPriceX96(uint256 invalidSqrtPrice);
    error InvalidTargetMultiplier(uint256 targetMultiplier);
    /// @notice The pool was not created through this hook.
    error PoolNotInitialized(PoolId poolId);
    error MustUseDynamicFee(uint24 lpFee);
    error InvalidHookAddress(address hookAddress);
    error InvalidInitializer(address caller);

    error PoolAlreadyConfigured();
    /// @notice The swap-entry fallback received a selector other than beforeSwap.
    error HookNotImplemented();
    error InvalidDiscount();

    event FeeConfigUpdated(PoolId indexed poolId, StableFeeConfig feeConfig);
    event PoolInitialized(PoolKey indexed poolKey, uint160 sqrtPriceX96, StableFeeConfig feeConfig);
    /// @dev Same shapes as FablesFeeEngine's discount events (the 32-bit filter is widened to uint64).
    event DiscountSet(
        PoolId indexed poolId, address indexed account, uint16 bps, uint24 minFee, uint8 dirs, uint40 expiry
    );
    event DiscountRevoked(PoolId indexed poolId, address indexed account);
    event DiscountFilterSet(PoolId indexed poolId, uint8 seed, uint64 bloom);

    /// @notice Max optimal band half-width: 1e4 = 1% (1e6 precision).
    uint256 public constant MAX_OPTIMAL_FEE_E6 = 1e4;
    uint256 public constant MAX_TARGET_MULTIPLIER = 100;
    /// @notice Fee ceiling in pips (10%); also written to `maxFee[id]` as the configured marker.
    uint24 public constant STABLE_MAX_FEE = 100_000;
    uint40 public constant MAX_DISCOUNT_TERM = 90 days;
    uint256 public constant MAX_DISCOUNT_BPS = DiscountLib.MAX_DISCOUNT_BPS;

    /// @dev Fee window: below a 0.9 price ratio to the reference (Q96) the formula reads the edge, sqrt price =
    ///      reference x or / sqrt(0.9); beyond it the far-boundary fee already exceeds the 10% cap.
    uint256 internal constant MIN_FEE_PRICE_RATIO_X96 = 71305346262837903834189555302;
    uint256 internal constant SQRT_MIN_FEE_PRICE_RATIO_X96 = 75162434512514379355924140470;
    uint256 internal constant Q96 = 1 << 96;

    uint32 private constant ARB_SYS_SELECTOR = 0xa3b1b31d;
    uint8 private constant ARB_SYS_ADDRESS = 0x64;
    /// @dev Gas cap for the constructor's ArbSys probe, so INVALID code at 0x64 cannot burn most of the deploy gas.
    uint256 private constant ARB_SYS_PROBE_GAS = 50_000;

    uint256 internal constant MASK8 = 0xff;
    uint256 internal constant MASK24 = 0xffffff;
    uint256 internal constant MASK32 = 0xffffffff;
    uint256 internal constant MASK40 = 0xffffffffff;
    uint256 internal constant MASK160 = (1 << 160) - 1;

    uint256 internal constant CFG_K_SHIFT = 0;
    uint256 internal constant CFG_OPT_SHIFT = 24;
    uint256 internal constant CFG_TM_SHIFT = 48;
    uint256 internal constant CFG_REF_SHIFT = 56;
    uint256 internal constant CFG_BLOOM_SHIFT = 216;
    uint256 internal constant CFG_SEED_SHIFT = 248;
    uint256 internal constant CFG_WHITELIST_MASK = ~((uint256(1) << CFG_BLOOM_SHIFT) - 1);

    uint256 internal constant STATE_FEE_SHIFT = 0;
    uint256 internal constant STATE_PRICE_SHIFT = 40;
    uint256 internal constant STATE_BLOCK_SHIFT = 200;
    uint256 internal constant STATE_SPARE_MASK = ~((uint256(1) << 240) - 1);

    /// @notice True: the clock is `ArbSys(0x64).arbBlockNumber()` (Arbitrum/Orbit chains); false: `block.number`.
    bool public immutable USE_ARB_SYS;

    struct StableWords {
        uint256 cfg;
        uint256 state;
    }

    mapping(PoolId poolId => StableWords words) internal _words;
    mapping(PoolId poolId => mapping(address account => uint256 entry)) internal _entry;

    constructor(IPoolManager poolManager_, address authority_) FablesHookCore(poolManager_, authority_) {
        // as BlockNumberish (probe gas capped): ArbSys if 0x64 has code and answers 32 bytes, else block.number
        bool useArbSys;
        assembly ("memory-safe") {
            if extcodesize(ARB_SYS_ADDRESS) {
                mstore(0x00, ARB_SYS_SELECTOR)
                let success := staticcall(ARB_SYS_PROBE_GAS, ARB_SYS_ADDRESS, 0x1c, 0x04, 0x00, 0x20)
                useArbSys := and(success, eq(returndatasize(), 0x20))
            }
        }
        USE_ARB_SYS = useArbSys;
    }

    function _hookPermissions() internal pure virtual returns (Hooks.Permissions memory permissions) {
        permissions.beforeInitialize = true;
        permissions.beforeSwap = true;
    }

    /// @dev BlockNumberish._getBlockNumberish, verbatim; reverts (empty) if the ArbSys call fails.
    function _getBlockNumberish() internal view returns (uint256 blockNumber) {
        if (USE_ARB_SYS) {
            assembly ("memory-safe") {
                mstore(0x00, ARB_SYS_SELECTOR)
                let success := staticcall(gas(), ARB_SYS_ADDRESS, 0x1c, 0x04, 0x00, 0x20)
                if or(iszero(success), iszero(eq(returndatasize(), 0x20))) { revert(0, 0) }
                blockNumber := mload(0x00)
            }
        } else {
            blockNumber = block.number;
        }
    }

    /// @notice Always reverts: pools are created only by `configureStablePool` (v4 skips the hook on its self-call).
    function beforeInitialize(address sender, PoolKey calldata, uint160)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        revert InvalidInitializer(sender);
    }

    /// @notice Validates and stores a pool's fee config, then initializes the pool from the hook. ERC20 pools only.
    /// @dev Checks and validators run in StablePair's order, with its revert bytes.
    function configureStablePool(PoolKey calldata key, uint160 sqrtPriceX96, StableFeeConfig calldata config)
        external
        restricted
        returns (int24 tick)
    {
        if (!key.fee.isDynamicFee()) revert MustUseDynamicFee(key.fee);
        if (key.hooks != IHooks(address(this))) revert InvalidHookAddress(address(key.hooks));
        if (key.currency0.isAddressZero() && !_nativeAllowed()) revert NativeNotSupported();
        PoolId poolId = key.toId();
        if (_referenceOf(poolId) != 0) revert PoolAlreadyConfigured();
        _validateFeeConfig(config.k, config.optimalFeeE6, config.targetMultiplier, config.referenceSqrtPriceX96);
        _resetFeeState(poolId);
        _writeFeeConfig(poolId, config.k, config.optimalFeeE6, config.targetMultiplier, config.referenceSqrtPriceX96);
        maxFee[poolId] = STABLE_MAX_FEE;
        tick = poolManager.initialize(key, sqrtPriceX96);
        emit PoolInitialized(key, sqrtPriceX96, config);
    }

    /// @notice Updates k, optimalFeeE6 and targetMultiplier (the reference is fixed) and resets the fee state.
    function updateFeeConfig(PoolKey calldata key, uint24 k, uint24 optimalFeeE6, uint8 targetMultiplier)
        external
        restricted
    {
        PoolId poolId = key.toId();
        _checkPoolInitialized(poolId);
        uint160 referenceSqrtPriceX96 = uint160(_referenceOf(poolId));
        _validateFeeConfig(k, optimalFeeE6, targetMultiplier, referenceSqrtPriceX96);
        _resetFeeState(poolId);
        _writeFeeConfig(poolId, k, optimalFeeE6, targetMultiplier, referenceSqrtPriceX96);
        _checkFeeConfigUpdate(poolId);
        emit FeeConfigUpdated(poolId, StableFeeConfig(k, optimalFeeE6, targetMultiplier, referenceSqrtPriceX96));
    }

    function _checkFeeConfigUpdate(PoolId poolId) internal view virtual {}

    /// @notice Per-direction fee a swap pays this block, sender-free (no discount). StablePair's `getFee`.
    function getFee(PoolKey calldata key) external view returns (uint24 feeE6ZeroForOne, uint24 feeE6OneForZero) {
        PoolId poolId = key.toId();
        _checkPoolInitialized(poolId);
        (uint256 cfg, uint256 st, uint256 sqrtAmmPriceX96, bool isNewBlock, uint256 clock) = _viewState(poolId);
        (uint256 feeE12ZeroForOne,) = _getFee(cfg, st, sqrtAmmPriceX96, isNewBlock, true, clock);
        (uint256 feeE12OneForZero,) = _getFee(cfg, st, sqrtAmmPriceX96, isNewBlock, false, clock);
        feeE6ZeroForOne = _toPips(feeE12ZeroForOne);
        feeE6OneForZero = _toPips(feeE12OneForZero);
    }

    /// @notice One direction's fee this block, sender-free.
    function currentFee(PoolId poolId, bool zeroForOne) external view returns (uint24) {
        _checkPoolInitialized(poolId);
        (uint256 cfg, uint256 st, uint256 sqrtAmmPriceX96, bool isNewBlock, uint256 clock) = _viewState(poolId);
        (uint256 feeE12,) = _getFee(cfg, st, sqrtAmmPriceX96, isNewBlock, zeroForOne, clock);
        return _toPips(feeE12);
    }

    /// @notice Exact fee `sender` (the PoolManager.swap caller) pays this block in one direction, discount applied.
    function feeFor(PoolKey calldata key, bool zeroForOne, address sender) external view returns (uint24) {
        PoolId poolId = key.toId();
        _checkPoolInitialized(poolId);
        (uint256 cfg, uint256 st, uint256 sqrtAmmPriceX96, bool isNewBlock, uint256 clock) = _viewState(poolId);
        (uint256 feeE12,) = _getFee(cfg, st, sqrtAmmPriceX96, isNewBlock, zeroForOne, clock);
        return _discounted(_toPips(feeE12), cfg, poolId, zeroForOne, sender);
    }

    /// @notice StablePair's `feeConfig`.
    function feeConfig(PoolId poolId)
        public
        view
        returns (uint24 k, uint24 optimalFeeE6, uint8 targetMultiplier, uint160 referenceSqrtPriceX96)
    {
        uint256 cfg = _words[poolId].cfg;
        k = uint24((cfg >> CFG_K_SHIFT) & MASK24);
        optimalFeeE6 = uint24((cfg >> CFG_OPT_SHIFT) & MASK24);
        targetMultiplier = uint8((cfg >> CFG_TM_SHIFT) & MASK8);
        referenceSqrtPriceX96 = uint160((cfg >> CFG_REF_SHIFT) & MASK160);
    }

    /// @notice StablePair's `feeState`.
    function feeState(PoolId poolId)
        public
        view
        returns (uint40 decayingFeeE12, uint160 sqrtAmmPriceX96, uint40 blockNumber)
    {
        uint256 st = _words[poolId].state;
        decayingFeeE12 = uint40((st >> STATE_FEE_SHIFT) & MASK40);
        sqrtAmmPriceX96 = uint160((st >> STATE_PRICE_SHIFT) & MASK160);
        blockNumber = uint40((st >> STATE_BLOCK_SHIFT) & MASK40);
    }

    /// @notice A pool's whitelist hash seed and Bloom filter, in FablesFeeEngine's order.
    function discountFilter(PoolId poolId) external view returns (uint8 seed, uint32 bloom) {
        uint256 cfg = _words[poolId].cfg;
        seed = uint8(cfg >> CFG_SEED_SHIFT);
        bloom = uint32((cfg >> CFG_BLOOM_SHIFT) & MASK32);
    }

    /// @notice An executor's whitelist entry on a pool (all zero = none).
    function discountOf(PoolId poolId, address account)
        external
        view
        returns (uint16 bps, uint24 minFee, uint8 dirs, uint40 expiry)
    {
        DiscountLib.Entry memory e = DiscountLib.unpack(_entry[poolId][account]);
        return (e.bps, e.minFee, e.dirs, e.expiry);
    }

    /// @notice Grants (bps > 0) or deletes (bps == 0) executor `account`'s discount on each pool: `bps` off the fee
    ///         (rounded up, never below `minFee`) in `dirs` (1 zeroForOne, 2 oneForZero, 3 both) until `expiry`.
    /// @dev A delete keeps the Bloom bit: one extra SLOAD on that account's swaps, never a discount.
    function setDiscount(
        PoolId[] calldata poolIds,
        address account,
        uint16 bps,
        uint24 minFee,
        uint8 dirs,
        uint40 expiry
    ) external restricted {
        if (account == address(0) || bps > MAX_DISCOUNT_BPS) revert InvalidDiscount();
        if (bps != 0) {
            if (dirs == 0 || dirs > DiscountLib.DIR_BOTH) revert InvalidDiscount();
            // forge-lint: disable-next-line(block-timestamp)
            if (expiry <= block.timestamp || expiry > block.timestamp + MAX_DISCOUNT_TERM) revert InvalidDiscount();
        }
        for (uint256 i; i < poolIds.length; i++) {
            PoolId poolId = poolIds[i];
            _checkPoolInitialized(poolId);
            if (bps == 0) {
                delete _entry[poolId][account];
                emit DiscountSet(poolId, account, 0, 0, 0, 0);
            } else {
                _entry[poolId][account] = DiscountLib.pack(bps, minFee, dirs, expiry);
                StableWords storage w = _words[poolId];
                uint256 cfg = w.cfg;
                uint256 bloom = ((cfg >> CFG_BLOOM_SHIFT) & MASK32) | DiscountLib.mask32(account, cfg >> CFG_SEED_SHIFT);
                w.cfg = (cfg & ~(MASK32 << CFG_BLOOM_SHIFT)) | (bloom << CFG_BLOOM_SHIFT);
                emit DiscountSet(poolId, account, bps, minFee, dirs, expiry);
            }
        }
    }

    /// @notice Deletes every (pool, account) entry in the cross product, without a pool check.
    function revokeDiscount(PoolId[] calldata poolIds, address[] calldata accounts) external restricted {
        for (uint256 i; i < poolIds.length; i++) {
            for (uint256 j; j < accounts.length; j++) {
                delete _entry[poolIds[i]][accounts[j]];
                emit DiscountRevoked(poolIds[i], accounts[j]);
            }
        }
    }

    /// @notice Re-seeds a pool's Bloom filter and rebuilds it from the listed accounts that hold an entry.
    /// @dev Pre-filter only: an omitted account keeps its entry (and may still hit); `revokeDiscount` removes it.
    function setDiscountFilter(PoolId poolId, uint8 seed, address[] calldata accounts) external restricted {
        _checkPoolInitialized(poolId);
        uint256 bloom;
        for (uint256 i; i < accounts.length; i++) {
            if (_entry[poolId][accounts[i]] != 0) bloom |= DiscountLib.mask32(accounts[i], seed);
        }
        StableWords storage w = _words[poolId];
        w.cfg = (w.cfg & ~CFG_WHITELIST_MASK) | (bloom << CFG_BLOOM_SHIFT) | (uint256(seed) << CFG_SEED_SHIFT);
        emit DiscountFilterSet(poolId, seed, uint64(bloom));
    }

    /// Fee for one swap in pips, discount applied; writes the state word on the first swap of a clock block.
    /// @param sqrtP The pool's sqrt price if the caller already read it, else 0.
    /// @dev Reverts only where StablePair does; the discount path never reverts.
    function _stableFee(PoolId poolId, uint160 sqrtP, bool zeroForOne, address sender) internal returns (uint24) {
        StableWords storage w = _words[poolId];
        uint256 cfg = w.cfg;
        uint256 st = w.state;
        uint256 clock = _getBlockNumberish();

        (uint256 sqrtAmmPriceX96, bool isNewBlock) = _loadPrice(poolId, st, clock, sqrtP);

        (uint256 lpFeeE12, uint256 stateLow) = _getFee(cfg, st, sqrtAmmPriceX96, isNewBlock, zeroForOne, clock);

        if (isNewBlock) {
            w.state = (st & STATE_SPARE_MASK) | stateLow | ((clock & MASK40) << STATE_BLOCK_SHIFT);
        }

        return (cfg >> CFG_BLOOM_SHIFT) == 0
            ? _toPips(lpFeeE12)
            : _discounted(_toPips(lpFeeE12), cfg, poolId, zeroForOne, sender);
    }

    /// StablePair's `toFeeE6` (pips, rounded up) capped at `STABLE_MAX_FEE`; the decay state stays uncapped.
    function _toPips(uint256 feeE12) internal pure returns (uint24 fee) {
        fee = StableFeeCalculation.toFeeE6(feeE12);
        if (fee > STABLE_MAX_FEE) fee = STABLE_MAX_FEE;
    }

    /// StablePairHook._loadPrice: the price cached at the block's first swap, or a fresh one on a new block or reset.
    function _loadPrice(PoolId poolId, uint256 st, uint256 clock, uint160 sqrtP)
        internal
        view
        returns (uint256 sqrtAmmPriceX96, bool isNewBlock)
    {
        uint256 cachedSqrtPriceX96 = (st >> STATE_PRICE_SHIFT) & MASK160;
        isNewBlock = (clock > ((st >> STATE_BLOCK_SHIFT) & MASK40)) || cachedSqrtPriceX96 == 0;
        if (isNewBlock) {
            sqrtAmmPriceX96 = sqrtP != 0 ? sqrtP : _poolSqrtPrice(poolId);
        } else {
            sqrtAmmPriceX96 = cachedSqrtPriceX96;
        }
    }

    function _poolSqrtPrice(PoolId poolId) internal view virtual returns (uint256) {
        return uint256(poolManager.extsload(StateLibrary._getPoolStateSlot(poolId))) & MASK160;
    }

    function _viewState(PoolId poolId)
        internal
        view
        returns (uint256 cfg, uint256 st, uint256 sqrtAmmPriceX96, bool isNewBlock, uint256 clock)
    {
        StableWords storage w = _words[poolId];
        cfg = w.cfg;
        st = w.state;
        clock = _getBlockNumberish();
        (sqrtAmmPriceX96, isNewBlock) = _loadPrice(poolId, st, clock, 0);
    }

    /// StablePairHook._getFee on the packed words, same statements and order, at the price clamped to the fee window.
    /// @return lpFeeE12 The fee.
    /// @return stateLow State bits [0, 200) to persist: the decaying fee and the price the formula read.
    function _getFee(uint256 cfg, uint256 st, uint256 sqrtAmmPriceX96, bool isNewBlock, bool zeroForOne, uint256 clock)
        internal
        pure
        returns (uint256 lpFeeE12, uint256 stateLow)
    {
        uint256 sqrtReferencePriceX96 = (cfg >> CFG_REF_SHIFT) & MASK160;
        uint256 optimalFeeE6 = (cfg >> CFG_OPT_SHIFT) & MASK24;

        uint256 priceRatioX96 = StableFeeCalculation.calculatePriceRatioX96(sqrtAmmPriceX96, sqrtReferencePriceX96);
        if (priceRatioX96 < MIN_FEE_PRICE_RATIO_X96) {
            // ref < 2^160, so neither product overflows
            sqrtAmmPriceX96 = sqrtAmmPriceX96 < sqrtReferencePriceX96
                ? sqrtReferencePriceX96 * SQRT_MIN_FEE_PRICE_RATIO_X96 / Q96
                : sqrtReferencePriceX96 * Q96 / SQRT_MIN_FEE_PRICE_RATIO_X96;
            priceRatioX96 = StableFeeCalculation.calculatePriceRatioX96(sqrtAmmPriceX96, sqrtReferencePriceX96);
        }

        int256 closeBoundaryFeeE12 = StableFeeCalculation.calculateCloseBoundaryFee(priceRatioX96, optimalFeeE6);

        // the cached price picks the side, so a within-block crossing of the reference shows only next block
        bool ammPriceBelowRP = sqrtAmmPriceX96 < sqrtReferencePriceX96;

        if (closeBoundaryFeeE12 <= 0) {
            lpFeeE12 = StableFeeCalculation.calculateInsideOptimalRangeFee(
                priceRatioX96, optimalFeeE6, ammPriceBelowRP, zeroForOne
            );
            stateLow = StableFeeCalculation.UNDEFINED_DECAYING_FEE_E12;
        } else {
            if (isNewBlock) {
                stateLow = _calculateDecayingFee(
                    cfg,
                    st,
                    sqrtAmmPriceX96,
                    sqrtReferencePriceX96,
                    uint256(closeBoundaryFeeE12),
                    StableFeeCalculation.calculateFarBoundaryFee(priceRatioX96, optimalFeeE6),
                    ammPriceBelowRP,
                    clock
                );
            } else {
                stateLow = (st >> STATE_FEE_SHIFT) & MASK40;
            }

            lpFeeE12 = (ammPriceBelowRP == zeroForOne) ? 0 : stateLow;
        }
        // decaying fee [0, 40) (always < 2^40), price [40, 200)
        stateLow = (stateLow & MASK40) | (sqrtAmmPriceX96 << STATE_PRICE_SHIFT);
    }

    function _calculateDecayingFee(
        uint256 cfg,
        uint256 st,
        uint256 sqrtAmmPriceX96,
        uint256 sqrtReferencePriceX96,
        uint256 closeBoundaryFeeE12,
        uint256 farBoundaryFeeE12,
        bool ammPriceBelowRP,
        uint256 clock
    ) internal pure returns (uint256 decayingFeeE12) {
        // start fee from how the price moved since the last swap
        uint256 decayStartFeeE12 =
            _decayStartFee(st, sqrtAmmPriceX96, sqrtReferencePriceX96, farBoundaryFeeE12, ammPriceBelowRP);

        uint256 targetFeeE12 =
            farBoundaryFeeE12 - closeBoundaryFeeE12 * ((cfg >> CFG_TM_SHIFT) & MASK8) / MAX_TARGET_MULTIPLIER;

        // clamp the start up to the target so the decay never underflows
        if (decayStartFeeE12 < targetFeeE12) {
            decayStartFeeE12 = targetFeeE12;
        }

        decayingFeeE12 = StableFeeCalculation.calculateDecayingFee(
            targetFeeE12, decayStartFeeE12, (cfg >> CFG_K_SHIFT) & MASK24, _blocksPassed(st, clock)
        );
    }

    function _blocksPassed(uint256 st, uint256 clock) internal pure returns (uint256) {
        uint256 blockNumber = (st >> STATE_BLOCK_SHIFT) & MASK40;
        return clock > blockNumber ? clock - blockNumber : 0;
    }

    function _decayStartFee(
        uint256 st,
        uint256 sqrtAmmPriceX96,
        uint256 sqrtReferencePriceX96,
        uint256 farBoundaryFeeE12,
        bool ammPriceBelowRP
    ) internal pure returns (uint256 decayStartFeeE12) {
        uint256 previousSqrtAmmPriceX96 = (st >> STATE_PRICE_SHIFT) & MASK160;
        uint256 previousDecayingFeeE12 = (st >> STATE_FEE_SHIFT) & MASK40;

        if (
            previousDecayingFeeE12 == StableFeeCalculation.UNDEFINED_DECAYING_FEE_E12
                || (previousSqrtAmmPriceX96 < sqrtReferencePriceX96) != ammPriceBelowRP
        ) {
            decayStartFeeE12 = farBoundaryFeeE12;
        } else if (ammPriceBelowRP == (sqrtAmmPriceX96 < previousSqrtAmmPriceX96)) {
            uint256 priceMovementRatioX96 =
                StableFeeCalculation.calculatePriceRatioX96(sqrtAmmPriceX96, previousSqrtAmmPriceX96);
            decayStartFeeE12 =
                StableFeeCalculation.adjustPreviousFeeForPriceMovement(priceMovementRatioX96, previousDecayingFeeE12);
        } else if (previousDecayingFeeE12 > farBoundaryFeeE12) {
            decayStartFeeE12 = farBoundaryFeeE12;
        } else {
            decayStartFeeE12 = previousDecayingFeeE12;
        }
    }

    /// The whitelist discount: never reverts or raises a fee, keeps 0 at 0; reads the entry only on a Bloom hit.
    function _discounted(uint24 fee, uint256 cfg, PoolId poolId, bool zeroForOne, address sender)
        internal
        view
        returns (uint24)
    {
        uint32 bloom = uint32((cfg >> CFG_BLOOM_SHIFT) & MASK32);
        if (bloom == 0 || fee == 0 || !DiscountLib.hit32(bloom, sender, cfg >> CFG_SEED_SHIFT)) return fee;
        uint256 e = _entry[poolId][sender];
        if (e == 0) return fee;
        // fee < 2^24 and the result is <= fee: the cast cannot truncate
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint24(DiscountLib.applyEntry(fee, 0, e, zeroForOne, block.timestamp));
    }

    function _referenceOf(PoolId poolId) internal view returns (uint256) {
        return (_words[poolId].cfg >> CFG_REF_SHIFT) & MASK160;
    }

    function _checkPoolInitialized(PoolId poolId) internal view {
        if (_referenceOf(poolId) == 0) revert PoolNotInitialized(poolId);
    }

    /// Writes config bits [0,216); the whitelist bits are kept.
    function _writeFeeConfig(
        PoolId poolId,
        uint24 k,
        uint24 optimalFeeE6,
        uint8 targetMultiplier,
        uint160 referenceSqrtPriceX96
    ) internal {
        StableWords storage w = _words[poolId];
        w.cfg = (w.cfg & CFG_WHITELIST_MASK) | (uint256(k) << CFG_K_SHIFT) | (uint256(optimalFeeE6) << CFG_OPT_SHIFT)
            | (uint256(targetMultiplier) << CFG_TM_SHIFT) | (uint256(referenceSqrtPriceX96) << CFG_REF_SHIFT);
    }

    /// StableFeeConfiguration._resetFeeState: UNDEFINED fee, current clock, zero cached price (next swap reads fresh).
    function _resetFeeState(PoolId poolId) internal {
        StableWords storage w = _words[poolId];
        w.state = (w.state & STATE_SPARE_MASK) | (StableFeeCalculation.UNDEFINED_DECAYING_FEE_E12 << STATE_FEE_SHIFT)
            | ((_getBlockNumberish() & MASK40) << STATE_BLOCK_SHIFT);
    }

    function _validateFeeConfig(
        uint256 k,
        uint256 optimalFeeE6,
        uint256 targetMultiplier,
        uint256 referenceSqrtPriceX96
    ) internal pure {
        _validateK(k);
        _validateOptimalFeeE6(optimalFeeE6);
        _validateTargetMultiplier(targetMultiplier);
        _validateReferenceSqrtPriceX96(referenceSqrtPriceX96);
    }

    function _validateK(uint256 _k) internal pure {
        if (_k == 0) {
            revert InvalidK(_k);
        }
    }

    function _validateOptimalFeeE6(uint256 _optimalFeeE6) internal pure {
        if (_optimalFeeE6 > MAX_OPTIMAL_FEE_E6) {
            revert InvalidOptimalFeeE6(_optimalFeeE6);
        }
    }

    /// 1..100; StablePair also accepts 0, under which 100% is a fixed point of the decay.
    function _validateTargetMultiplier(uint256 _targetMultiplier) internal pure {
        if (_targetMultiplier == 0 || _targetMultiplier > MAX_TARGET_MULTIPLIER) {
            revert InvalidTargetMultiplier(_targetMultiplier);
        }
    }

    /// Verbatim StablePair: the widest optimal band, [ref * sqrt(1 - f), ref / sqrt(1 - f)], must fit v4's price range.
    function _validateReferenceSqrtPriceX96(uint256 _referenceSqrtPriceX96) internal pure {
        uint256 oneMinusMaxFee = StableFeeCalculation.ONE_E6 - MAX_OPTIMAL_FEE_E6;
        uint256 sqrtOneMinusMaxFeeE6 = FixedPointMathLib.sqrt(oneMinusMaxFee * StableFeeCalculation.ONE_E6);
        uint256 minBoundedReferenceSqrtPrice =
            (uint256(TickMath.MIN_SQRT_PRICE) * StableFeeCalculation.ONE_E6 + sqrtOneMinusMaxFeeE6 - 1)
                / sqrtOneMinusMaxFeeE6;
        uint256 maxBoundedReferenceSqrtPrice =
            uint256(TickMath.MAX_SQRT_PRICE) * sqrtOneMinusMaxFeeE6 / StableFeeCalculation.ONE_E6;

        if (
            _referenceSqrtPriceX96 < minBoundedReferenceSqrtPrice
                || _referenceSqrtPriceX96 >= maxBoundedReferenceSqrtPrice
        ) {
            revert InvalidReferenceSqrtPriceX96(_referenceSqrtPriceX96);
        }
    }
}
