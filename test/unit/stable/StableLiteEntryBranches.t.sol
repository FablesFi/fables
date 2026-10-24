// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import "../../utils/StableTestBase.sol";
import {FablesHookCore} from "../../../src/base/FablesHookCore.sol";

/// @notice Exposes `StableFeeCalculation` internals.
contract StableCalcProbe {
    function fastPow(uint256 k, uint256 n) external pure returns (uint256) {
        return StableFeeCalculation.fastPow(k, n);
    }

    function decaying(uint256 target, uint256 prev, uint256 k, uint256 n) external pure returns (uint256) {
        return StableFeeCalculation.calculateDecayingFee(target, prev, k, n);
    }
}

/// @notice Each inline-assembly branch on the Stable Lite path, both ways: swap entry gates, ArbSys clock probe and
///         `fastPow` cases.
abstract contract StableLiteEntryBranchesBase is StableTestBase {
    using PoolIdLibrary for PoolKey;

    address internal lite;
    address internal typed;
    StableCalcProbe internal calc;

    function setUp() public {
        setUpChain();
        lite = _deployLite("edge-lite");
        typed = _deployTyped("edge-typed");
        calc = new StableCalcProbe();
    }

    function _k(address h) internal view returns (PoolKey memory) {
        return PoolKey(c0, c1, DYN, 1, IHooks(h));
    }

    function test_gate_strangerRevertsNotPoolManager() public {
        (bool ok, bytes memory ret) = lite.call(abi.encodeWithSelector(IHooks.beforeSwap.selector));
        assertFalse(ok);
        assertEq(ret, abi.encodeWithSelector(FablesHookCore.NotPoolManager.selector));
    }

    function test_gate_poolManagerOtherSelectorReverts() public {
        vm.prank(PM_ADDR);
        (bool ok, bytes memory ret) = lite.call(abi.encodeWithSelector(IHooks.afterSwap.selector, uint256(7)));
        assertFalse(ok);
        assertEq(ret, abi.encodeWithSelector(FablesStableFee.HookNotImplemented.selector));
    }

    function test_entry_servedFeeMatchesTwinAndViews() public {
        (StableFeeConfig memory cIn, uint160 pIn) = _cfgIn();
        (StableFeeConfig memory cOut, uint160 pOut) = _cfgOut();
        PoolKey memory kIn = PoolKey(c0, c1, DYN, 1, IHooks(lite));
        PoolKey memory kOut = PoolKey(c0, c2, DYN, 1, IHooks(lite));
        PoolKey memory tIn = PoolKey(c0, c1, DYN, 1, IHooks(typed));
        PoolKey memory tOut = PoolKey(c0, c2, DYN, 1, IHooks(typed));
        if (Currency.unwrap(c2) < Currency.unwrap(c0)) {
            kOut = PoolKey(c2, c0, DYN, 1, IHooks(lite));
            tOut = PoolKey(c2, c0, DYN, 1, IHooks(typed));
        }
        _createPool(lite, kIn, pIn, cIn);
        _createPool(lite, kOut, pOut, cOut);
        _createPool(typed, tIn, pIn, cIn);
        _createPool(typed, tOut, pOut, cOut);
        for (uint256 i; i < 4; ++i) {
            bool zfo = i % 2 == 0;
            PoolKey memory k = i < 2 ? kIn : kOut;
            PoolKey memory t = i < 2 ? tIn : tOut;
            uint24 viewFee = FablesStableHookLite(lite).feeFor(k, zfo, UR_ADDR);
            (bool ok, bytes memory ret) = _beforeSwapCall(lite, k, zfo, UR_ADDR);
            (bool okT, bytes memory retT) = _beforeSwapCall(typed, t, zfo, UR_ADDR);
            assertTrue(ok && okT, "served");
            (bytes4 sel, int256 delta, uint256 fee) = abi.decode(ret, (bytes4, int256, uint256));
            assertEq(sel, IHooks.beforeSwap.selector);
            assertEq(delta, 0);
            assertEq(fee, uint256(viewFee) | 0x400000, "fee == feeFor | OVERRIDE");
            assertEq(ret, retT, "assembly entry == typed twin");
        }
        (uint24 f0, uint24 f1) = FablesStableHookLite(lite).getFee(kOut);
        assertTrue(f0 != f1, "out of band: one side pays the decaying fee, the other 0");
    }

    function test_entry_extsloadRevertRevertsEmpty() public {
        (StableFeeConfig memory c, uint160 p) = _cfgIn();
        _createPool(lite, _k(lite), p, c);
        vm.mockCallRevert(PM_ADDR, abi.encodeWithSelector(bytes4(0x1e2eaeaf)), "down");
        (bool ok, bytes memory ret) = _beforeSwapCall(lite, _k(lite), true, UR_ADDR);
        assertFalse(ok);
        assertEq(ret.length, 0, "empty revert");
    }

    function test_entry_extsloadShortReplyRevertsEmpty() public {
        (StableFeeConfig memory c, uint160 p) = _cfgIn();
        _createPool(lite, _k(lite), p, c);
        vm.mockCall(PM_ADDR, abi.encodeWithSelector(bytes4(0x1e2eaeaf)), hex"01");
        (bool ok, bytes memory ret) = _beforeSwapCall(lite, _k(lite), true, UR_ADDR);
        assertFalse(ok);
        assertEq(ret.length, 0, "empty revert");
    }

    function test_clock_noArbSysUsesBlockNumber() public {
        assertFalse(FablesStableHookLite(lite).USE_ARB_SYS());
        vm.roll(777);
        (StableFeeConfig memory c, uint160 p) = _cfgIn();
        _createPool(lite, _k(lite), p, c);
        (,, uint40 blk) = FablesStableHookLite(lite).feeState(_k(lite).toId());
        assertEq(blk, 777);
    }

    function test_clock_arbSysLatchedAndReadAndFailureReverts() public {
        _etchArbSysSlot(55_555);
        address a = _deployLite("edge-arb");
        assertTrue(FablesStableHookLite(a).USE_ARB_SYS());
        (StableFeeConfig memory c, uint160 p) = _cfgIn();
        vm.roll(9);
        _createPool(a, _k(a), p, c);
        (,, uint40 blk) = FablesStableHookLite(a).feeState(_k(a).toId());
        assertEq(blk, 55_555, "ArbSys clock, not block.number");
        ArbSysHelper.setMode(MockArbSys.Mode.ShortReturn);
        (bool ok, bytes memory ret) = _beforeSwapCall(a, _k(a), true, UR_ADDR);
        assertFalse(ok);
        assertEq(ret.length, 0, "short ArbSys reply reverts empty");
        ArbSysHelper.setMode(MockArbSys.Mode.Revert);
        (ok, ret) = a.staticcall(abi.encodeCall(FablesStableFee.currentFee, (_k(a).toId(), true)));
        assertFalse(ok);
        assertEq(ret.length, 0, "reverting ArbSys reverts empty");
        ArbSysHelper.remove(vm);
    }

    function test_fastPow_everyCase() public view {
        uint256 k = K07;
        assertEq(calc.fastPow(k, 0), 1 << 24);
        assertEq(calc.fastPow(k, 1), k);
        assertEq(calc.fastPow(k, 2), (k * k) >> 24);
        assertEq(calc.fastPow(k, 3), (k * k * k) >> 48);
        assertEq(calc.fastPow(k, 4), (k * k * k * k) >> 72);
        assertEq(calc.fastPow(k, 5), 0, "no case: 0 (callers pass n <= 4)");
    }

    function test_decay_fastPathPerBlockAndSlowPathContinuity() public view {
        uint256 target = 1e9;
        uint256 prev = 5e9;
        uint256 last = type(uint256).max;
        for (uint256 n; n <= 6; ++n) {
            uint256 d = calc.decaying(target, prev, K07, n);
            if (n <= 4) assertEq(d, target + ((calc.fastPow(K07, n) * (prev - target)) >> 24), "fast path");
            assertLe(d, last, "monotone in n");
            last = d;
        }
    }
}

/// @notice On FablesStableHookLite.
contract StableLiteEntryBranchesTest is StableLiteEntryBranchesBase {}

/// @notice On FablesStableHookLiteExclusive.
contract StableLiteEntryBranchesExclusiveTest is StableLiteEntryBranchesBase {
    function _exclusive() internal pure override returns (bool) {
        return true;
    }
}
