// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import "../../utils/StableTestBase.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {IAccessManaged} from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FablesHookCore} from "../../../src/base/FablesHookCore.sol";
import {FablesExclusiveLiquidityV2} from "../../../src/base/FablesExclusiveLiquidityV2.sol";
import {DiscountLib} from "../../../src/libraries/DiscountLib.sol";

/// @notice Stable Lite build: exact swap-entry revert set vs StablePair, pool creation through the hook, config
///         validation, clock latch, flags, storage slots and ledger wiring.
abstract contract StableLiteUnitBase is StableTestBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    address sp;
    address lite;
    address typed;
    address stranger = makeAddr("stranger");

    function setUp() public {
        setUpChain();
        sp = _deploySP("u-sp");
        lite = _deployLite("u-lite");
        typed = _deployTyped("u-typed");
    }

    function _k(address h) internal view returns (PoolKey memory) {
        return PoolKey(c0, c1, DYN, 1, IHooks(h));
    }

    function _ids(PoolId id) internal pure returns (PoolId[] memory a) {
        a = new PoolId[](1);
        a[0] = id;
    }

    function test_selectorsPinned() public pure {
        assertEq(IHooks.beforeSwap.selector, bytes4(0x575e24b4));
        assertEq(FablesHookCore.NotPoolManager.selector, bytes4(0xae18210a));
        assertEq(FablesStableFee.HookNotImplemented.selector, bytes4(0x0a85dc29));
        assertEq(uint24(LPFeeLibrary.OVERRIDE_FEE_FLAG), uint24(0x400000));
    }

    function test_gate_nonPoolManagerRevertsNotPoolManager_anySelector() public {
        PoolKey memory k = _k(lite);
        bytes memory cd = abi.encodeCall(
            IHooks.beforeSwap,
            (
                address(this),
                k,
                IPoolManager.SwapParams({zeroForOne: true, amountSpecified: -1, sqrtPriceLimitX96: 1}),
                bytes("")
            )
        );
        (bool ok, bytes memory ret) = lite.call(cd);
        assertFalse(ok);
        assertEq(ret, abi.encodeWithSelector(FablesHookCore.NotPoolManager.selector), "beforeSwap from a stranger");
        (ok, ret) = lite.call(abi.encodeWithSelector(bytes4(0x12345678)));
        assertFalse(ok);
        assertEq(
            ret, abi.encodeWithSelector(FablesHookCore.NotPoolManager.selector), "unknown selector from a stranger"
        );
        (ok, ret) = typed.call(cd);
        assertFalse(ok);
        assertEq(ret, abi.encodeWithSelector(FablesHookCore.NotPoolManager.selector));
        (ok, ret) = sp.call(cd);
        assertFalse(ok);
        assertEq(bytes4(ret), FablesHookCore.NotPoolManager.selector);
    }

    function test_gate_poolManagerWithUnknownSelectorRevertsHookNotImplemented() public {
        vm.prank(PM_ADDR);
        (bool ok, bytes memory ret) = lite.call(abi.encodeWithSelector(bytes4(0x12345678), uint256(1)));
        assertFalse(ok);
        assertEq(ret, abi.encodeWithSelector(FablesStableFee.HookNotImplemented.selector));
        vm.prank(PM_ADDR);
        (ok, ret) = lite.call(abi.encodeWithSelector(IHooks.afterSwap.selector));
        assertFalse(ok);
        assertEq(ret, abi.encodeWithSelector(FablesStableFee.HookNotImplemented.selector));
    }

    function test_gate_isNonPayable() public {
        vm.deal(PM_ADDR, 1 ether);
        vm.prank(PM_ADDR);
        (bool ok,) = lite.call{value: 1}(abi.encodeWithSelector(IHooks.beforeSwap.selector));
        assertFalse(ok, "value refused");
    }

    function test_afterGate_uninitializedPoolRevertsWithStablePairsBytes() public {
        (bool okS, bytes memory rS) = _beforeSwapCall(sp, _k(sp), true, UR_ADDR);
        (bool okL, bytes memory rL) = _beforeSwapCall(lite, _k(lite), true, UR_ADDR);
        (bool okT, bytes memory rT) = _beforeSwapCall(typed, _k(typed), true, UR_ADDR);
        assertFalse(okS);
        assertFalse(okL);
        assertFalse(okT);
        assertEq(rL, rS, "Lite revert bytes == StablePair");
        assertEq(rT, rS, "Typed revert bytes == StablePair");
        assertEq(bytes4(rS), bytes4(0x4e487b71), "Panic");
        assertEq(abi.decode(_tail(rS, 4), (uint256)), 0x12, "division by zero");
    }

    function test_beforeSwapReturnShape() public {
        (StableFeeConfig memory c, uint160 p0) = _cfgIn();
        _createPool(sp, _k(sp), p0, c);
        _createPool(lite, _k(lite), p0, c);
        _createPool(typed, _k(typed), p0, c);
        (bool okS, bytes memory rS) = _beforeSwapCall(sp, _k(sp), true, UR_ADDR);
        (bool okL, bytes memory rL) = _beforeSwapCall(lite, _k(lite), true, UR_ADDR);
        (bool okT, bytes memory rT) = _beforeSwapCall(typed, _k(typed), true, UR_ADDR);
        assertTrue(okS && okL && okT);
        assertEq(rL.length, 96);
        assertEq(rL, rS);
        assertEq(rT, rS);
        (bytes4 sel, int256 delta, uint256 fee) = abi.decode(rL, (bytes4, int256, uint256));
        assertEq(sel, IHooks.beforeSwap.selector);
        assertEq(delta, 0);
        assertEq(fee & 0x400000, 0x400000, "override flag");
        (uint24 f0,) = _getFee(lite, _k(lite));
        assertEq(fee & 0xffffff, f0 | 0x400000);
    }

    function test_directInitializeRejected_exactBytes() public {
        PoolKey memory k = _k(lite);
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                lite,
                IHooks.beforeInitialize.selector,
                abi.encodeWithSelector(FablesStableFee.InvalidInitializer.selector, address(this)),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        pm.initialize(k, SQRT_1_1);
        vm.expectRevert();
        pm.initialize(_k(sp), SQRT_1_1);
    }

    function test_configureStablePool_guards() public {
        (StableFeeConfig memory c, uint160 p0) = _cfgIn();
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger));
        FablesStableHookLite(lite).configureStablePool(_k(lite), p0, c);
        vm.expectRevert(abi.encodeWithSelector(FablesStableFee.MustUseDynamicFee.selector, uint24(500)));
        FablesStableHookLite(lite).configureStablePool(PoolKey(c0, c1, 500, 1, IHooks(lite)), p0, c);
        vm.expectRevert(abi.encodeWithSelector(FablesStableFee.InvalidHookAddress.selector, sp));
        FablesStableHookLite(lite).configureStablePool(_k(sp), p0, c);
        vm.expectRevert(FablesHookCore.NativeNotSupported.selector);
        FablesStableHookLite(lite)
            .configureStablePool(PoolKey(Currency.wrap(address(0)), c1, DYN, 1, IHooks(lite)), p0, c);
        c.targetMultiplier = 0;
        vm.expectRevert(abi.encodeWithSelector(FablesStableFee.InvalidTargetMultiplier.selector, uint256(0)));
        FablesStableHookLite(lite).configureStablePool(_k(lite), p0, c);
    }

    function test_configureStablePool_happyPath_andWriteOnce() public {
        (StableFeeConfig memory c, uint160 p0) = _cfgIn();
        PoolId id = _k(lite).toId();
        vm.expectEmit(true, false, false, true, lite);
        emit FablesStableFee.PoolInitialized(_k(lite), p0, c);
        int24 tick = FablesStableHookLite(lite).configureStablePool(_k(lite), p0, c);
        assertEq(tick, INIT_TICK);
        assertEq(FablesStableHookLite(lite).maxFee(id), 100_000, "configured marker (10% cap)");
        _assertConfigAndFreshState(id, c);
        (uint160 sqrtP,,,) = pm.getSlot0(id);
        assertEq(sqrtP, p0, "pool initialized at the given price");
        vm.expectRevert(FablesStableFee.PoolAlreadyConfigured.selector);
        FablesStableHookLite(lite).configureStablePool(_k(lite), p0, c);
    }

    function _assertConfigAndFreshState(PoolId id, StableFeeConfig memory c) internal view {
        (uint24 k, uint24 o, uint8 tm, uint160 ref) = FablesStableHookLite(lite).feeConfig(id);
        assertEq(k, c.k);
        assertEq(o, c.optimalFeeE6);
        assertEq(tm, c.targetMultiplier);
        assertEq(ref, c.referenceSqrtPriceX96);
        (uint40 dec, uint160 cached, uint40 blk) = FablesStableHookLite(lite).feeState(id);
        assertEq(uint256(dec), UNDEF);
        assertEq(cached, 0);
        assertEq(blk, uint40(block.number));
    }

    function testFuzz_configValidationMatchesStablePair(uint24 k, uint24 opt, uint8 tm, uint160 r, uint160 p, uint8 sel)
        public
    {
        if (sel % 4 == 0) r = uint160(bound(r, 4295128739, 1461446703485210103287273052203988822378723970342));
        if (sel % 3 == 0) opt = uint24(bound(opt, 0, 10_001));
        if (sel % 5 == 0) tm = uint8(bound(tm, 0, 101));
        if (sel % 2 == 0) p = uint160(bound(p, 4295128739, 1461446703485210103287273052203988822378723970341));
        StableFeeConfig memory c =
            StableFeeConfig({k: k, optimalFeeE6: opt, targetMultiplier: tm, referenceSqrtPriceX96: r});
        if (!_cmpCreate(p, c)) return;
        _cmpUpdate(
            StableFeeConfig({
                k: uint24(uint256(keccak256(abi.encode(k, "k2"))) % (1 << 24)),
                optimalFeeE6: uint24(uint256(keccak256(abi.encode(opt, "o2"))) % 10_050),
                targetMultiplier: uint8(uint256(keccak256(abi.encode(tm, "t2"))) % 103),
                referenceSqrtPriceX96: r
            })
        );
    }

    function _isDeviation(StableFeeConfig memory c) internal pure returns (bool) {
        return c.targetMultiplier == 0 && c.k != 0 && c.optimalFeeE6 <= 10_000;
    }

    function _cmpCreate(uint160 p, StableFeeConfig memory c) internal returns (bool) {
        (bool okS, bytes memory rS) = sp.call(abi.encodeCall(IStablePair.initializePool, (_k(sp), p, c)));
        (bool okL, bytes memory rL) = lite.call(abi.encodeCall(FablesStableFee.configureStablePool, (_k(lite), p, c)));
        if (_isDeviation(c)) {
            assertFalse(okL, "tm 0 refused");
            assertEq(rL, abi.encodeWithSelector(FablesStableFee.InvalidTargetMultiplier.selector, uint256(0)));
            return false;
        }
        assertEq(okL, okS, "outcome");
        assertEq(rL, rS, okS ? "returned tick" : "revert bytes");
        return okS;
    }

    function _cmpUpdate(StableFeeConfig memory c2) internal {
        (bool okUS, bytes memory rUS) = sp.call(abi.encodeCall(IStablePair.updateFeeConfig, (_k(sp).toId(), c2)));
        (bool okUL, bytes memory rUL) = lite.call(
            abi.encodeCall(FablesStableFee.updateFeeConfig, (_k(lite), c2.k, c2.optimalFeeE6, c2.targetMultiplier))
        );
        if (_isDeviation(c2)) {
            assertFalse(okUL);
            assertEq(rUL, abi.encodeWithSelector(FablesStableFee.InvalidTargetMultiplier.selector, uint256(0)));
        } else {
            assertEq(okUL, okUS, "update outcome");
            assertEq(rUL, rUS, "update revert bytes");
        }
    }

    function test_updateFeeConfig_cannotTouchReference_resetsState_validates() public {
        (StableFeeConfig memory c, uint160 p0) = _cfgOut();
        PoolKey memory k = _k(lite);
        PoolId id = k.toId();
        vm.expectRevert(abi.encodeWithSelector(FablesStableFee.PoolNotInitialized.selector, id));
        FablesStableHookLite(lite).updateFeeConfig(k, 1, 1, 1);
        _createPool(lite, k, p0, c);
        _addLiq(lite, k, -887272, 887272, 1e24);
        _beforeSwapCall(lite, k, true, UR_ADDR);
        (uint40 dec, uint160 cached,) = FablesStableHookLite(lite).feeState(id);
        assertTrue(cached != 0 && dec != uint40(UNDEF), "state written by the swap");
        vm.roll(block.number + 5);
        vm.expectEmit(true, false, false, true, lite);
        emit FablesStableFee.FeeConfigUpdated(id, StableFeeConfig(16_609_443, 9, 50, c.referenceSqrtPriceX96));
        FablesStableHookLite(lite).updateFeeConfig(k, 16_609_443, 9, 50);
        (uint24 kk, uint24 o, uint8 tm, uint160 ref) = FablesStableHookLite(lite).feeConfig(id);
        assertEq(kk, 16_609_443);
        assertEq(o, 9);
        assertEq(tm, 50);
        assertEq(ref, c.referenceSqrtPriceX96, "reference unchanged");
        (uint40 dec2, uint160 cached2, uint40 blk2) = FablesStableHookLite(lite).feeState(id);
        assertEq(uint256(dec2), UNDEF);
        assertEq(cached2, 0);
        assertEq(blk2, uint40(block.number));
        vm.expectRevert(abi.encodeWithSelector(FablesStableFee.InvalidK.selector, uint256(0)));
        FablesStableHookLite(lite).updateFeeConfig(k, 0, 9, 50);
        vm.expectRevert(abi.encodeWithSelector(FablesStableFee.InvalidOptimalFeeE6.selector, uint256(10_001)));
        FablesStableHookLite(lite).updateFeeConfig(k, 1, 10_001, 50);
        vm.expectRevert(abi.encodeWithSelector(FablesStableFee.InvalidTargetMultiplier.selector, uint256(101)));
        FablesStableHookLite(lite).updateFeeConfig(k, 1, 9, 101);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger));
        FablesStableHookLite(lite).updateFeeConfig(k, 1, 9, 50);
        FablesStableHookLite(lite).setDiscount(_ids(id), stranger, 100, 0, 3, uint40(block.timestamp + 1 days));
        (uint8 s0, uint32 b0) = FablesStableHookLite(lite).discountFilter(id);
        assertTrue(b0 != 0);
        FablesStableHookLite(lite).updateFeeConfig(k, 1, 9, 50);
        (uint8 s1, uint32 b1) = FablesStableHookLite(lite).discountFilter(id);
        assertEq(b1, b0);
        assertEq(s1, s0);
    }

    function test_getFee_uninitializedPoolReverts_withPoolId() public {
        PoolKey memory k = _k(lite);
        (bool ok, bytes memory ret) = lite.staticcall(abi.encodeCall(IStablePair.getFee, (k)));
        assertFalse(ok);
        assertEq(ret, abi.encodeWithSelector(FablesStableFee.PoolNotInitialized.selector, k.toId()));
        vm.expectRevert(abi.encodeWithSelector(FablesStableFee.PoolNotInitialized.selector, k.toId()));
        FablesStableHookLite(lite).currentFee(k.toId(), true);
        vm.expectRevert(abi.encodeWithSelector(FablesStableFee.PoolNotInitialized.selector, k.toId()));
        FablesStableHookLite(lite).feeFor(k, true, stranger);
    }

    function test_clockLatchedAtConstruction() public {
        assertFalse(FablesStableHookLite(lite).USE_ARB_SYS(), "no code at 0x64 -> block.number");
        _etchArbSysSlot(123_456);
        address a = _deployLite("clk-a");
        assertTrue(FablesStableHookLite(a).USE_ARB_SYS());
        ArbSysHelper.setMode(MockArbSys.Mode.ShortReturn);
        address b = _deployLite("clk-b");
        assertFalse(FablesStableHookLite(b).USE_ARB_SYS());
        (StableFeeConfig memory c, uint160 p0) = _cfgIn();
        ArbSysHelper.setMode(MockArbSys.Mode.Normal);
        _createPool(a, _k(a), p0, c);
        (,, uint40 blk) = FablesStableHookLite(a).feeState(_k(a).toId());
        assertEq(blk, 123_456, "state block = ArbSys clock");
        ArbSysHelper.setMode(MockArbSys.Mode.Revert);
        (bool ok, bytes memory ret) = a.staticcall(abi.encodeCall(IStablePair.getFee, (_k(a))));
        assertFalse(ok);
        assertEq(ret.length, 0, "empty revert from the clock read");
        (ok, ret) = _beforeSwapCall(a, _k(a), true, UR_ADDR);
        assertFalse(ok);
        assertEq(ret.length, 0);
    }

    function test_flagsValidatedAgainstTheMinedAddress() public {
        address bad = flagged("bad-flags", _exclusive() ? LITE_FLAGS : LITE_EXCLUSIVE_FLAGS);
        vm.expectRevert();
        deployCodeTo(StableBuild.artifact(_exclusive()), abi.encode(PM_ADDR, address(authority)), bad);
        assertEq(uint160(lite) & 0x3FFF, _liteFlags(), "flags of the build");
    }

    function test_storageSlotsPinned() public {
        (StableFeeConfig memory c, uint160 p0) = _cfgOut();
        PoolKey memory k = _k(lite);
        PoolId id = k.toId();
        _createPool(lite, k, p0, c);
        uint256 cfgW = uint256(vm.load(lite, _cfgSlot(id)));
        uint256 expectCfg = uint256(c.k) | (uint256(c.optimalFeeE6) << 24) | (uint256(c.targetMultiplier) << 48)
            | (uint256(c.referenceSqrtPriceX96) << 56);
        assertEq(cfgW, expectCfg, "config word at slot 2");
        uint256 stW = uint256(vm.load(lite, _stateSlot(id)));
        assertEq(stW, UNDEF | (uint256(block.number) << 200), "state word at cfg slot + 1");
        assertEq(uint256(vm.load(lite, keccak256(abi.encode(id, uint256(1))))), 100_000, "maxFee at slot 1");
        FablesStableHookLite(lite).setDiscount(_ids(id), stranger, 1234, 5, 3, uint40(block.timestamp + 7 days));
        uint256 e = uint256(vm.load(lite, keccak256(abi.encode(stranger, keccak256(abi.encode(id, ENTRY_SLOT))))));
        assertEq(e, DiscountLib.pack(1234, 5, 3, uint40(block.timestamp + 7 days)), "entry at slot 3");
        (uint8 seed, uint32 bloom) = FablesStableHookLite(lite).discountFilter(id);
        assertEq(bloom, DiscountLib.mask32(stranger, 0));
        assertEq(seed, 0);
        uint256 cfgW2 = uint256(vm.load(lite, _cfgSlot(id)));
        assertEq(cfgW2, expectCfg | (uint256(bloom) << 216), "bloom at [216,248)");
    }

    function test_whitelistAdmin_bounds_roles_events() public {
        (StableFeeConfig memory c, uint160 p0) = _cfgOut();
        PoolKey memory k = _k(lite);
        PoolId id = k.toId();
        uint40 exp = uint40(block.timestamp + 1 days);
        vm.expectRevert(abi.encodeWithSelector(FablesStableFee.PoolNotInitialized.selector, id));
        FablesStableHookLite(lite).setDiscount(_ids(id), stranger, 100, 0, 3, exp);
        _createPool(lite, k, p0, c);
        vm.expectRevert(FablesStableFee.InvalidDiscount.selector);
        FablesStableHookLite(lite).setDiscount(_ids(id), address(0), 100, 0, 3, exp);
        vm.expectRevert(FablesStableFee.InvalidDiscount.selector);
        FablesStableHookLite(lite).setDiscount(_ids(id), stranger, 5001, 0, 3, exp);
        vm.expectRevert(FablesStableFee.InvalidDiscount.selector);
        FablesStableHookLite(lite).setDiscount(_ids(id), stranger, 100, 0, 0, exp);
        vm.expectRevert(FablesStableFee.InvalidDiscount.selector);
        FablesStableHookLite(lite).setDiscount(_ids(id), stranger, 100, 0, 4, exp);
        vm.expectRevert(FablesStableFee.InvalidDiscount.selector);
        FablesStableHookLite(lite).setDiscount(_ids(id), stranger, 100, 0, 3, uint40(block.timestamp));
        vm.expectRevert(FablesStableFee.InvalidDiscount.selector);
        FablesStableHookLite(lite).setDiscount(_ids(id), stranger, 100, 0, 3, uint40(block.timestamp + 90 days + 1));
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger));
        FablesStableHookLite(lite).setDiscount(_ids(id), stranger, 100, 0, 3, exp);
        address[] memory acc = new address[](1);
        acc[0] = stranger;
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger));
        FablesStableHookLite(lite).revokeDiscount(_ids(id), acc);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger));
        FablesStableHookLite(lite).setDiscountFilter(id, 1, acc);
    }

    function test_whitelistAdmin_grantDeleteFilterRevoke() public {
        (StableFeeConfig memory c, uint160 p0) = _cfgOut();
        PoolKey memory k = _k(lite);
        PoolId id = k.toId();
        uint40 exp = uint40(block.timestamp + 1 days);
        _createPool(lite, k, p0, c);
        address[] memory acc = new address[](1);
        acc[0] = stranger;
        _grantAndDelete(id, exp);
        vm.expectEmit(true, false, false, true, lite);
        emit FablesStableFee.DiscountFilterSet(id, 9, 0);
        FablesStableHookLite(lite).setDiscountFilter(id, 9, acc);
        (uint8 s, uint32 bl) = FablesStableHookLite(lite).discountFilter(id);
        assertEq(bl, 0);
        assertEq(s, 9);
        FablesStableHookLite(lite).setDiscount(_ids(id), stranger, 100, 0, 3, exp);
        (, bl) = FablesStableHookLite(lite).discountFilter(id);
        assertEq(bl, DiscountLib.mask32(stranger, 9));
        vm.expectEmit(true, true, false, true, lite);
        emit FablesStableFee.DiscountRevoked(id, stranger);
        FablesStableHookLite(lite).revokeDiscount(_ids(id), acc);
        (uint16 b,,,) = FablesStableHookLite(lite).discountOf(id, stranger);
        assertEq(b, 0);
    }

    function _grantAndDelete(PoolId id, uint40 exp) internal {
        vm.expectEmit(true, true, false, true, lite);
        emit FablesStableFee.DiscountSet(id, stranger, 2500, 7, 1, exp);
        FablesStableHookLite(lite).setDiscount(_ids(id), stranger, 2500, 7, 1, exp);
        (uint16 b, uint24 m, uint8 d, uint40 e) = FablesStableHookLite(lite).discountOf(id, stranger);
        assertEq(b, 2500);
        assertEq(m, 7);
        assertEq(d, 1);
        assertEq(e, exp);
        (, uint32 bloomBefore) = FablesStableHookLite(lite).discountFilter(id);
        vm.expectEmit(true, true, false, true, lite);
        emit FablesStableFee.DiscountSet(id, stranger, 0, 0, 0, 0);
        FablesStableHookLite(lite).setDiscount(_ids(id), stranger, 0, 0, 3, 0);
        (b,,,) = FablesStableHookLite(lite).discountOf(id, stranger);
        assertEq(b, 0);
        (, uint32 bloomAfter) = FablesStableHookLite(lite).discountFilter(id);
        assertEq(bloomAfter, bloomBefore, "delete keeps the bloom bit");
    }
}

/// @notice FablesStableHookLite (open liquidity).
contract StableLiteUnitTest is StableLiteUnitBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    function test_ledgerCycleNextToDirectLiquidity() public {
        (StableFeeConfig memory c, uint160 p0) = _cfgOut();
        PoolKey memory k = _k(lite);
        PoolId id = k.toId();
        _createPool(lite, k, p0, c);
        _addDirect(k, INIT_TICK - 60, INIT_TICK + 60, 1e21);
        _addLiq(lite, k, INIT_TICK - 60, INIT_TICK + 60, 1e21);
        assertEq(pm.getLiquidity(id), 2e21, "direct and ledger liquidity side by side");
        SeqSwapper s = new SeqSwapper(pm);
        MockERC20(Currency.unwrap(c0)).mint(address(s), BIG);
        MockERC20(Currency.unwrap(c1)).mint(address(s), BIG);
        vm.recordLogs();
        (bool ok,) = s.swap(k, true, -1e18, TickMath.MIN_SQRT_PRICE + 1);
        assertTrue(ok);
        (, uint24 f) = _swapEventFee(vm.getRecordedLogs(), id);
        assertGt(f, 0, "corrective side charged");
        uint256 before0 = IERC20(Currency.unwrap(c0)).balanceOf(address(this));
        FablesStableHookLite(lite).claimFees(k, INIT_TICK - 60, INIT_TICK + 60, address(this), type(uint16).max);
        assertGt(IERC20(Currency.unwrap(c0)).balanceOf(address(this)) - before0, 0, "fees claimed in currency0");
        _removeDirect(k, INIT_TICK - 60, INIT_TICK + 60, 1e21);
        assertEq(pm.getLiquidity(id), 1e21, "only the ledger's liquidity is left");
        _removeLiq(lite, k, INIT_TICK - 60, INIT_TICK + 60, 1e21);
        assertEq(pm.getLiquidity(id), 0, "withdrawn");
    }
}

/// @notice FablesStableHookLiteExclusive (ledger-only liquidity).
contract StableLiteUnitExclusiveTest is StableLiteUnitBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    function _exclusive() internal pure override returns (bool) {
        return true;
    }

    function test_ledgerCycleThroughTheExclusiveGate() public {
        (StableFeeConfig memory c, uint160 p0) = _cfgOut();
        PoolKey memory k = _k(lite);
        PoolId id = k.toId();
        _createPool(lite, k, p0, c);
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                lite,
                IHooks.beforeAddLiquidity.selector,
                abi.encodeWithSelector(FablesExclusiveLiquidityV2.LiquidityOnlyViaLedger.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        liq.modify(k, -60, 60, 1e18, 0);
        _addLiq(lite, k, INIT_TICK - 60, INIT_TICK + 60, 1e21);
        assertEq(pm.getLiquidity(id), 1e21, "all liquidity is ledger liquidity");
        SeqSwapper s = new SeqSwapper(pm);
        MockERC20(Currency.unwrap(c0)).mint(address(s), BIG);
        MockERC20(Currency.unwrap(c1)).mint(address(s), BIG);
        vm.recordLogs();
        (bool ok,) = s.swap(k, true, -1e18, TickMath.MIN_SQRT_PRICE + 1);
        assertTrue(ok);
        (, uint24 f) = _swapEventFee(vm.getRecordedLogs(), id);
        assertGt(f, 0, "corrective side charged");
        uint256 before0 = IERC20(Currency.unwrap(c0)).balanceOf(address(this));
        FablesStableHookLite(lite).claimFees(k, INIT_TICK - 60, INIT_TICK + 60, address(this), type(uint16).max);
        assertGt(IERC20(Currency.unwrap(c0)).balanceOf(address(this)) - before0, 0, "fees claimed in currency0");
        _removeLiq(lite, k, INIT_TICK - 60, INIT_TICK + 60, 1e21);
        assertEq(pm.getLiquidity(id), 0, "withdrawn");
    }
}
