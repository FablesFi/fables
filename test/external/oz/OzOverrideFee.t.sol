// SPDX-License-Identifier: MIT
// Adapted from OpenZeppelin Uniswap Hooks v1.3.0 (MIT, Copyright (c) 2016-2026 Zeppelin Group Ltd).
pragma solidity ^0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IERC20Minimal} from "v4-core/src/interfaces/external/IERC20Minimal.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {ProtocolFeeLibrary} from "v4-core/src/libraries/ProtocolFeeLibrary.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";

import {FablesHookCore} from "../../../src/base/FablesHookCore.sol";
import {FablesFeeEngine} from "../../../src/base/FablesFeeEngine.sol";
import {FablesLedgerV2} from "../../../src/base/FablesLedgerV2.sol";
import {FablesStableHookLite} from "../../../src/FablesStableHookLite.sol";
import {FablesStableFee, StableFeeConfig} from "../../../src/base/FablesStableFee.sol";
import {MockWETH9} from "../../utils/mocks/MockWETH9.sol";
import {IEngineQuote, IStableQuote} from "./OzHookHandler.sol";

/// @notice OpenZeppelin `BaseOverrideFee` and `BaseHook` tests, run on all six builds: the override fee and its
///         composition with the protocol fee, the stored LP fee, dynamic-fee keys only, and which callbacks are live.
contract OzOverrideFeeTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using ProtocolFeeLibrary for uint16;

    struct Build {
        string name;
        uint160 flags;
        bool eth;
        bool exclusive;
        bool stable;
    }

    bytes32 internal constant SWAP_TOPIC =
        keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");

    uint256 internal constant BUILDS = 6;

    Build[BUILDS] internal builds;
    PoolKey[BUILDS] internal keys;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();
        vm.deal(address(this), 1e30);
        AccessManager authority = new AccessManager(address(this));
        address weth = address(new MockWETH9());
        builds[0] = Build("FablesHook", 0x2080, false, false, false);
        builds[1] = Build("FablesHookETH", 0x2080, true, false, false);
        builds[2] = Build("FablesHookExclusive", 0x2880, false, true, false);
        builds[3] = Build("FablesHookETHExclusive", 0x2880, true, true, false);
        builds[4] = Build("FablesStableHookLite", 0x2080, false, false, true);
        builds[5] = Build("FablesStableHookLiteExclusive", 0x2880, false, true, true);
        for (uint256 i; i < BUILDS; ++i) {
            Build memory b = builds[i];
            address hook = address(uint160((0x0F00 + i) << 144) | b.flags);
            bytes memory args =
                b.eth ? abi.encode(manager, address(authority), weth) : abi.encode(manager, address(authority));
            deployCodeTo(string.concat(b.name, ".sol:", b.name), args, hook);
            Currency first = b.eth ? CurrencyLibrary.ADDRESS_ZERO : currency0;
            keys[i] = PoolKey(first, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(hook));
            if (b.stable) {
                FablesStableHookLite(hook).configureStablePool(keys[i], SQRT_PRICE_1_1, _stableConfig());
            } else {
                FablesFeeEngine(hook).setCategory(1, 0, 100_000, 100_000, "ANY");
                FablesFeeEngine(hook).configurePool(keys[i], 1, 3000, 3000, 500, 50_000);
                FablesFeeEngine(hook).initializePool(keys[i], SQRT_PRICE_1_1);
            }
            IERC20Minimal(Currency.unwrap(currency0)).approve(hook, type(uint256).max);
            IERC20Minimal(Currency.unwrap(currency1)).approve(hook, type(uint256).max);
            // one position, as `HookTest.initPoolAndAddLiquidity`, so a swap has a single priced step
            FablesLedgerV2(payable(hook)).deposit{value: b.eth ? 1e18 : 0}(
                keys[i], -120, 120, 1e18, b.eth ? 1e18 : type(uint128).max, type(uint128).max, block.timestamp
            );
        }
    }

    function _stableConfig() internal pure returns (StableFeeConfig memory) {
        return StableFeeConfig({
            k: 11_744_051, optimalFeeE6: 50, targetMultiplier: 100, referenceSqrtPriceX96: SQRT_PRICE_1_1
        });
    }

    /// @notice `test_swap_fuzz_succeeds`: the swap pays the hook's quote composed with the protocol fee, the
    ///         protocol takes its exact share, and the stored LP fee stays 0.
    /// forge-config: default.fuzz.runs = 256
    function test_swapPaysTheOverrideAndTheProtocolShare(
        bool zeroForOne,
        uint16 protocolFee0,
        uint16 protocolFee1,
        int256 amountSpecified
    ) public {
        protocolFee0 = uint16(bound(protocolFee0, 0, 1000));
        protocolFee1 = uint16(bound(protocolFee1, 0, 1000));
        amountSpecified = bound(amountSpecified, -1e24, 1e24);
        vm.assume(amountSpecified != 0);
        uint24 protocolFee = (uint24(protocolFee1) << 12) | uint24(protocolFee0);
        uint16 side = zeroForOne ? protocolFee0 : protocolFee1;

        for (uint256 i; i < BUILDS; ++i) {
            _checkSwapFees(i, zeroForOne, protocolFee, side, amountSpecified);
        }
    }

    function _checkSwapFees(uint256 i, bool zeroForOne, uint24 protocolFee, uint16 side, int256 amountSpecified)
        internal
    {
        PoolKey memory key = keys[i];
        vm.prank(feeController);
        manager.setProtocolFee(key, protocolFee);
        uint24 lpFee = _quote(i, key, zeroForOne);
        Currency input = zeroForOne ? key.currency0 : key.currency1;
        uint256 accruedBefore = manager.protocolFeesAccrued(input);

        vm.recordLogs();
        BalanceDelta delta = _swap(i, zeroForOne, amountSpecified);

        string memory name = builds[i].name;
        assertEq(_swapEventFee(key), side == 0 ? lpFee : side.calculateSwapFee(lpFee), name);
        uint256 paid = uint256(uint128(-(zeroForOne ? delta.amount0() : delta.amount1())));
        uint256 expected = paid * side / 1e6;
        // with no LP fee the protocol fee is the whole swap fee, rounded up
        if (lpFee == 0 && (paid * side) % 1e6 != 0) expected++;
        assertEq(manager.protocolFeesAccrued(input) - accruedBefore, expected, name);
        assertEq(_storedLpFee(key), 0, name);
    }

    function _swap(uint256 i, bool zeroForOne, int256 amountSpecified) internal returns (BalanceDelta) {
        return swapRouter.swap{value: builds[i].eth ? 1e24 : 0}(
            keys[i],
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );
    }

    /// @notice `test_updateDynamicLPFee_callerNotHook_reverts`.
    function test_updateDynamicLPFee_callerNotHook_reverts() public {
        for (uint256 i; i < BUILDS; ++i) {
            vm.expectRevert(IPoolManager.UnauthorizedDynamicLPFeeUpdate.selector);
            manager.updateDynamicLPFee(keys[i], 123);
        }
    }

    /// @notice `test_afterInitialize_staticFee_reverts`: a static-fee key is refused, and the PoolManager cannot
    ///         initialize a pool around the hook.
    function test_staticFeeKeyIsRefused() public {
        for (uint256 i; i < BUILDS; ++i) {
            PoolKey memory key = keys[i];
            key.fee = 3000;
            key.tickSpacing = 30;
            address hook = address(key.hooks);
            if (builds[i].stable) {
                vm.expectRevert(abi.encodeWithSelector(FablesStableFee.MustUseDynamicFee.selector, uint24(3000)));
                FablesStableHookLite(hook).configureStablePool(key, SQRT_PRICE_1_1, _stableConfig());
            } else {
                vm.expectRevert(FablesFeeEngine.NotDynamicFeePool.selector);
                FablesFeeEngine(hook).configurePool(key, 1, 3000, 3000, 500, 50_000);
            }
            vm.expectRevert(
                abi.encodeWithSelector(
                    CustomRevert.WrappedError.selector,
                    hook,
                    IHooks.beforeInitialize.selector,
                    abi.encodeWithSelector(FablesFeeEngine.InvalidInitializer.selector, address(this)),
                    abi.encodeWithSelector(Hooks.HookCallFailed.selector)
                )
            );
            manager.initialize(key, SQRT_PRICE_1_1);
        }
    }

    /// @notice `test_all_notPoolManager_reverts`: every callback, and the unlock callback, refuses any other caller.
    function test_callbacksRefuseAnyCallerButThePoolManager() public {
        bytes memory notPoolManager = abi.encodeWithSelector(FablesHookCore.NotPoolManager.selector);
        for (uint256 i; i < BUILDS; ++i) {
            address hook = address(keys[i].hooks);
            bytes[10] memory cds = _callbacks(keys[i]);
            for (uint256 c; c < cds.length; ++c) {
                (bool ok, bytes memory ret) = hook.call(cds[c]);
                assertFalse(ok, builds[i].name);
                assertEq(ret, notPoolManager, builds[i].name);
            }
            vm.expectRevert(FablesHookCore.NotPoolManager.selector);
            IUnlockCallback(hook).unlockCallback("");
        }
    }

    /// @notice `getHookPermissions` and `HookNotImplemented`: only beforeInitialize, beforeSwap and (Exclusive builds)
    ///         beforeAddLiquidity are live, no return-delta flag is set, and every other callback reverts even when
    ///         the PoolManager calls it.
    function test_onlyTheDocumentedCallbacksAreLive() public {
        uint160[10] memory flags = [
            Hooks.BEFORE_INITIALIZE_FLAG,
            Hooks.AFTER_INITIALIZE_FLAG,
            Hooks.BEFORE_ADD_LIQUIDITY_FLAG,
            Hooks.AFTER_ADD_LIQUIDITY_FLAG,
            Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG,
            Hooks.AFTER_REMOVE_LIQUIDITY_FLAG,
            Hooks.BEFORE_SWAP_FLAG,
            Hooks.AFTER_SWAP_FLAG,
            Hooks.BEFORE_DONATE_FLAG,
            Hooks.AFTER_DONATE_FLAG
        ];
        for (uint256 i; i < BUILDS; ++i) {
            IHooks hook = keys[i].hooks;
            bytes[10] memory cds = _callbacks(keys[i]);
            for (uint256 c; c < flags.length; ++c) {
                bool live = c == 0 || c == 6 || (c == 2 && builds[i].exclusive);
                assertEq(Hooks.hasPermission(hook, flags[c]), live, builds[i].name);
                if (live) continue;
                vm.prank(address(manager));
                (bool ok,) = address(hook).call(cds[c]);
                assertFalse(ok, builds[i].name);
            }
            assertFalse(Hooks.hasPermission(hook, Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG), builds[i].name);
            assertFalse(Hooks.hasPermission(hook, Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG), builds[i].name);
            assertFalse(Hooks.hasPermission(hook, Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG), builds[i].name);
            assertFalse(Hooks.hasPermission(hook, Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG), builds[i].name);
        }
    }

    function _callbacks(PoolKey memory key) internal view returns (bytes[10] memory cds) {
        IPoolManager.ModifyLiquidityParams memory lp = IPoolManager.ModifyLiquidityParams(-120, 120, 1e18, 0);
        IPoolManager.SwapParams memory sp = IPoolManager.SwapParams(true, -100, MIN_PRICE_LIMIT);
        BalanceDelta zero;
        address s = address(this);
        cds[0] = abi.encodeCall(IHooks.beforeInitialize, (s, key, SQRT_PRICE_1_1));
        cds[1] = abi.encodeCall(IHooks.afterInitialize, (s, key, SQRT_PRICE_1_1, 0));
        cds[2] = abi.encodeCall(IHooks.beforeAddLiquidity, (s, key, lp, ZERO_BYTES));
        cds[3] = abi.encodeCall(IHooks.afterAddLiquidity, (s, key, lp, zero, zero, ZERO_BYTES));
        cds[4] = abi.encodeCall(IHooks.beforeRemoveLiquidity, (s, key, lp, ZERO_BYTES));
        cds[5] = abi.encodeCall(IHooks.afterRemoveLiquidity, (s, key, lp, zero, zero, ZERO_BYTES));
        cds[6] = abi.encodeCall(IHooks.beforeSwap, (s, key, sp, ZERO_BYTES));
        cds[7] = abi.encodeCall(IHooks.afterSwap, (s, key, sp, zero, ZERO_BYTES));
        cds[8] = abi.encodeCall(IHooks.beforeDonate, (s, key, 1, 1, ZERO_BYTES));
        cds[9] = abi.encodeCall(IHooks.afterDonate, (s, key, 1, 1, ZERO_BYTES));
    }

    function _quote(uint256 i, PoolKey memory key, bool zeroForOne) internal view returns (uint24) {
        if (builds[i].stable) return IStableQuote(address(key.hooks)).feeFor(key, zeroForOne, address(swapRouter));
        return IEngineQuote(address(key.hooks)).feeFor(key.toId(), zeroForOne, address(swapRouter));
    }

    function _swapEventFee(PoolKey memory key) internal view returns (uint24 fee) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 id = PoolId.unwrap(key.toId());
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(manager) || logs[i].topics.length < 2) continue;
            if (logs[i].topics[0] != SWAP_TOPIC || logs[i].topics[1] != id) continue;
            (,,,,, fee) = abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
            return fee;
        }
        revert("no Swap event");
    }

    function _storedLpFee(PoolKey memory key) internal view returns (uint24 lpFee) {
        (,,, lpFee) = manager.getSlot0(key.toId());
    }
}
