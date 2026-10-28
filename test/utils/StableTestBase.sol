// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {console} from "forge-std/console.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";

import {HooklessBaseline} from "./RCBytecodeHarness.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockArbSys, ArbSysHelper} from "./mocks/MockArbSys.sol";
import {StablePairBytecode} from "./StablePairBytecode.sol";
import {StableBuild} from "./Artifacts.sol";
import {FablesStableHookLite, FablesStableHookLiteTyped} from "../../src/FablesStableHookLite.sol";
import {FablesStableFee, StableFeeConfig} from "../../src/base/FablesStableFee.sol";
import {StableFeeCalculation} from "../../src/libraries/StableFeeCalculation.sol";
import {FablesExclusiveLiquidityV2} from "../../src/base/FablesExclusiveLiquidityV2.sol";

/// @notice ABI of the deployed Uniswap StablePair hook (proxy).
interface IStablePair {
    function initialize(address admin, address poolInitializer, address configManager) external;
    function initializePool(PoolKey calldata key, uint160 sqrtPriceX96, StableFeeConfig calldata cfg)
        external
        returns (int24);
    function updateFeeConfig(PoolId poolId, StableFeeConfig calldata cfg) external;
    function getFee(PoolKey calldata key) external view returns (uint24, uint24);
    function feeConfig(PoolId poolId) external view returns (uint24, uint24, uint8, uint160);
    function feeState(PoolId poolId) external view returns (uint40, uint160, uint40);
}

/// @notice Swaps against the PoolManager and reports success or revert bytes.
contract SeqSwapper is IUnlockCallback {
    IPoolManager internal immutable pm;

    constructor(IPoolManager _pm) {
        pm = _pm;
    }

    function swap(PoolKey memory key, bool zeroForOne, int256 amountSpecified, uint160 limit)
        external
        returns (bool ok, bytes memory err)
    {
        try pm.unlock(abi.encode(key, zeroForOne, amountSpecified, limit)) {
            ok = true;
        } catch (bytes memory e) {
            err = e;
        }
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(pm), "pm");
        (PoolKey memory key, bool z, int256 amt, uint160 lim) = abi.decode(data, (PoolKey, bool, int256, uint160));
        BalanceDelta d =
            pm.swap(key, IPoolManager.SwapParams({zeroForOne: z, amountSpecified: amt, sqrtPriceLimitX96: lim}), "");
        _settle(key.currency0, d.amount0());
        _settle(key.currency1, d.amount1());
        return "";
    }

    function _settle(Currency c, int128 a) internal {
        if (a < 0) {
            pm.sync(c);
            MockERC20(Currency.unwrap(c)).transfer(address(pm), uint128(-a));
            pm.settle();
        } else if (a > 0) {
            pm.take(c, address(this), uint128(a));
        }
    }
}

/// @notice Fixture for the Stable Lite tests: the deployed StablePair as reference, the Fables builds at flag
///         addresses, and adapters for both ABIs. Suites run on FablesStableHookLite unless `_exclusive()` is
///         overridden to pick FablesStableHookLiteExclusive.
abstract contract StableTestBase is HooklessBaseline {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint160 internal constant SQRT_1_1 = SQRT_PRICE_1_1;
    uint128 internal constant AMT = 1e18;
    int24 internal constant TS = 60;
    int24 internal constant INIT_TICK = MID_WORD_TICK;
    uint24 internal constant DYN = DYNAMIC_FEE;
    uint24 internal constant K07 = 11744051;
    uint256 internal constant UNDEF = 1e12 + 1;
    uint256 internal constant BIG = 1e45;

    uint160 internal constant BI = Hooks.BEFORE_INITIALIZE_FLAG;
    uint160 internal constant AINIT = Hooks.AFTER_INITIALIZE_FLAG;
    uint160 internal constant BAL = Hooks.BEFORE_ADD_LIQUIDITY_FLAG;
    uint160 internal constant AAL = Hooks.AFTER_ADD_LIQUIDITY_FLAG;
    uint160 internal constant BS = Hooks.BEFORE_SWAP_FLAG;
    uint160 internal constant AS = Hooks.AFTER_SWAP_FLAG;
    uint160 internal constant SP_FLAGS = BI | AINIT | BAL | AAL | BS | AS;
    uint160 internal constant LITE_FLAGS = FLAGS_STABLE_LITE;
    uint160 internal constant LITE_EXCLUSIVE_FLAGS = FLAGS_STABLE_LITE_EXCLUSIVE;

    bytes32 internal constant SP_LOC = 0x4e65cbff7fdec8e7b73e40370c540338cf2b602902c10f166d6a73c4a7ee9e00;
    bytes32 internal constant IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    uint256 internal constant WORDS_SLOT = 2;
    uint256 internal constant ENTRY_SLOT = 3;

    bytes32 internal constant SWAP_TOPIC =
        keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");

    uint24 internal constant FABLES_FEE_CAP = 100_000;

    AccessManager internal authority;
    mapping(address hook => bool) internal isFables;

    function setUpChain() internal {
        setUpRC();
        authority = new AccessManager(address(this));
        MockERC20(Currency.unwrap(c0)).mint(address(liq), BIG);
        MockERC20(Currency.unwrap(c1)).mint(address(liq), BIG);
        MockERC20(Currency.unwrap(c0)).mint(address(this), BIG);
        MockERC20(Currency.unwrap(c1)).mint(address(this), BIG);
    }

    function _key(Currency a, Currency b, uint24 fee, address hook) internal pure returns (PoolKey memory) {
        return PoolKey(a, b, fee, TS, IHooks(hook));
    }

    function _cfgSlot(PoolId id) internal pure returns (bytes32) {
        return keccak256(abi.encode(id, WORDS_SLOT));
    }

    function _stateSlot(PoolId id) internal pure returns (bytes32) {
        return bytes32(uint256(_cfgSlot(id)) + 1);
    }

    function _deploySP(string memory tag) internal returns (address h) {
        bytes memory impl_ = StablePairBytecode.implCreationCode();
        bytes memory proxy_ = StablePairBytecode.proxyRuntimeCode();
        require(sha256(impl_) == StablePairBytecode.IMPL_CREATION_SHA256, "StablePair creation code");
        require(sha256(proxy_) == StablePairBytecode.PROXY_RUNTIME_SHA256, "StablePair proxy runtime");
        bytes memory creation = abi.encodePacked(impl_, abi.encode(PM_ADDR));
        address impl;
        assembly {
            impl := create(0, add(creation, 0x20), mload(creation))
        }
        require(impl != address(0), "impl");
        h = flagged(tag, SP_FLAGS);
        vm.etch(h, proxy_);
        vm.store(h, IMPL_SLOT, bytes32(uint256(uint160(impl))));
        IStablePair(h).initialize(address(this), address(this), address(this));
        vm.label(h, "StablePair(deployed)");
    }

    /// @notice The build under test: false = FablesStableHookLite, true = FablesStableHookLiteExclusive.
    function _exclusive() internal pure virtual returns (bool) {
        return false;
    }

    function _liteFlags() internal pure returns (uint160) {
        return StableBuild.flags(_exclusive());
    }

    function _deployLite(string memory tag) internal returns (address h) {
        h = _deployBuild(tag, _exclusive());
    }

    function _deployBuild(string memory tag, bool exclusive) internal returns (address h) {
        h = flagged(tag, StableBuild.flags(exclusive));
        deployCodeTo(StableBuild.artifact(exclusive), abi.encode(PM_ADDR, address(authority)), h);
        _registerFables(h, StableBuild.name(exclusive));
    }

    function _deployTyped(string memory tag) internal returns (address h) {
        h = flagged(tag, LITE_FLAGS);
        deployCodeTo("FablesStableHookLite.sol:FablesStableHookLiteTyped", abi.encode(PM_ADDR, address(authority)), h);
        _registerFables(h, "FablesStableHookLiteTyped");
    }

    function _registerFables(address h, string memory label) internal {
        isFables[h] = true;
        vm.label(h, label);
        MockERC20(Currency.unwrap(c0)).approve(h, type(uint256).max);
        MockERC20(Currency.unwrap(c1)).approve(h, type(uint256).max);
        MockERC20(Currency.unwrap(c2)).approve(h, type(uint256).max);
    }

    function _etchArbSysSlot(uint256 start) internal {
        ArbSysHelper.install(vm, start);
    }

    function _etchArbSysNumber() internal {
        ArbSysHelper.install(vm, block.number);
    }

    function _arbSet(uint256 n) internal {
        ArbSysHelper.set(n);
    }

    function _arbAdvance(uint256 n) internal {
        ArbSysHelper.advance(n);
    }

    function _rollClock(uint256 n) internal {
        vm.roll(block.number + n);
        if (ArbSysHelper.installed()) ArbSysHelper.advance(n);
    }

    function _createPool(address h, PoolKey memory key, uint160 sqrtP, StableFeeConfig memory c) internal {
        if (isFables[h]) FablesStableHookLite(h).configureStablePool(key, sqrtP, c);
        else IStablePair(h).initializePool(key, sqrtP, c);
    }

    function _updateConfig(address h, PoolKey memory key, StableFeeConfig memory c) internal {
        if (isFables[h]) FablesStableHookLite(h).updateFeeConfig(key, c.k, c.optimalFeeE6, c.targetMultiplier);
        else IStablePair(h).updateFeeConfig(key.toId(), c);
    }

    /// @notice Moves the reference: Fables' bounded `updateReferencePrice`, StablePair's `updateFeeConfig` with the rest
    ///         of the config unchanged. Both reset the fee state.
    function _moveRef(address h, PoolKey memory key, uint160 ref) internal {
        if (isFables[h]) {
            FablesStableHookLite(h).updateReferencePrice(key, ref);
        } else {
            (uint24 k, uint24 opt, uint8 tm,) = IStablePair(h).feeConfig(key.toId());
            IStablePair(h).updateFeeConfig(key.toId(), StableFeeConfig(k, opt, tm, ref));
        }
    }

    function _addLiq(address h, PoolKey memory key, int24 lo, int24 hi, uint128 L) internal {
        if (isFables[h]) {
            FablesStableHookLite(h).deposit(key, lo, hi, L, type(uint128).max, type(uint128).max, block.timestamp);
        } else {
            liq.modify(key, lo, hi, int256(uint256(L)), 0);
        }
    }

    function _removeLiq(address h, PoolKey memory key, int24 lo, int24 hi, uint128 L) internal {
        if (isFables[h]) {
            FablesStableHookLite(h).withdraw(key, lo, hi, L, address(this), 0, 0, block.timestamp);
        } else {
            liq.modify(key, lo, hi, -int256(uint256(L)), 0);
        }
    }

    /// @notice Liquidity added around the ledger (LiqHelper position, salt 0).
    function _addDirect(PoolKey memory key, int24 lo, int24 hi, uint128 L) internal returns (BalanceDelta) {
        return liq.modify(key, lo, hi, int256(uint256(L)), 0);
    }

    function _removeDirect(PoolKey memory key, int24 lo, int24 hi, uint128 L) internal returns (BalanceDelta) {
        return liq.modify(key, lo, hi, -int256(uint256(L)), 0);
    }

    /// @notice Revert bytes of a direct add refused by the Exclusive gate.
    function _gateRevert(address h) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            h,
            IHooks.beforeAddLiquidity.selector,
            abi.encodeWithSelector(FablesExclusiveLiquidityV2.LiquidityOnlyViaLedger.selector),
            abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        );
    }

    function _capped(uint24 f) internal pure returns (uint24) {
        return f > FABLES_FEE_CAP ? FABLES_FEE_CAP : f;
    }

    function _refSqrt() internal pure returns (uint160) {
        return TickMath.getSqrtPriceAtTick(INIT_TICK);
    }

    function _cfgIn() internal pure returns (StableFeeConfig memory c, uint160 sqrtP) {
        c = StableFeeConfig({k: K07, optimalFeeE6: 50, targetMultiplier: 100, referenceSqrtPriceX96: _refSqrt()});
        sqrtP = _refSqrt();
    }

    function _cfgOut() internal pure returns (StableFeeConfig memory c, uint160 sqrtP) {
        c = StableFeeConfig({k: K07, optimalFeeE6: 7, targetMultiplier: 100, referenceSqrtPriceX96: _refSqrt()});
        sqrtP = uint160(uint256(_refSqrt()) * 1000290 / 1000000);
    }

    function _getFee(address h, PoolKey memory key) internal view returns (uint24 f0, uint24 f1) {
        return IStablePair(h).getFee(key);
    }

    function _getFeeRaw(address h, PoolKey memory key) internal view returns (bool ok, bytes memory ret) {
        (ok, ret) = h.staticcall(abi.encodeCall(IStablePair.getFee, (key)));
        if (!ok && ret.length == 36 && bytes4(ret) == FablesStableFee.PoolNotInitialized.selector) {
            ret = abi.encodePacked(FablesStableFee.PoolNotInitialized.selector);
        }
    }

    function _stateBytes(address h, PoolId id) internal view returns (bytes memory) {
        (bool ok1, bytes memory a) = h.staticcall(abi.encodeCall(IStablePair.feeState, (id)));
        (bool ok2, bytes memory b) = h.staticcall(abi.encodeCall(IStablePair.feeConfig, (id)));
        require(ok1 && ok2 && a.length == 96 && b.length == 128, "views");
        return bytes.concat(a, b);
    }

    function _beforeSwapCall(address h, PoolKey memory key, bool zfo, address sender)
        internal
        returns (bool ok, bytes memory ret)
    {
        bytes memory cd = abi.encodeCall(
            IHooks.beforeSwap,
            (
                sender,
                key,
                IPoolManager.SwapParams({
                    zeroForOne: zfo,
                    amountSpecified: -1e18,
                    sqrtPriceLimitX96: zfo ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
                }),
                bytes("")
            )
        );
        vm.prank(PM_ADDR);
        (ok, ret) = h.call(cd);
    }

    function _normRevert(bytes memory err) internal pure returns (bytes memory) {
        if (err.length < 4 || bytes4(err) != CustomRevert.WrappedError.selector) return err;
        (, bytes4 sel, bytes memory reason, bytes memory details) =
            abi.decode(_tail(err, 4), (address, bytes4, bytes, bytes));
        return abi.encode(sel, reason, details);
    }

    function _tail(bytes memory b, uint256 skip) internal pure returns (bytes memory t) {
        t = new bytes(b.length - skip);
        for (uint256 i; i < t.length; i++) {
            t[i] = b[i + skip];
        }
    }

    function _swapEventFee(Vm.Log[] memory logs, PoolId id) internal pure returns (bool found, uint24 fee) {
        for (uint256 j; j < logs.length; j++) {
            if (logs[j].emitter == PM_ADDR && logs[j].topics[0] == SWAP_TOPIC && logs[j].topics[1] == PoolId.unwrap(id))
            {
                (,,,,, fee) = abi.decode(logs[j].data, (int128, int128, uint160, uint128, int24, uint24));
                found = true;
            }
        }
    }
}
