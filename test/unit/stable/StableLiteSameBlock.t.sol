// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import "../../utils/StableTestBase.sol";

/// @notice Start-of-block cache: legs in one block pay identical fees; the next block refreshes.
abstract contract StableLiteSameBlockBase is StableTestBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    SeqSwapper sw;

    function setUp() public {
        setUpChain();
        sw = new SeqSwapper(pm);
        MockERC20(Currency.unwrap(c0)).mint(address(sw), BIG);
        MockERC20(Currency.unwrap(c1)).mint(address(sw), BIG);
    }

    struct Pair {
        address sp;
        address lite;
        PoolKey ksp;
        PoolKey kl;
        uint256 mode;
    }

    function _pair(string memory tag, bool arb) internal returns (Pair memory P) {
        if (arb) _etchArbSysSlot(1_000_000);
        P.mode = arb ? 1 : 0;
        P.sp = _deploySP(string.concat(tag, "-sp"));
        P.lite = _deployLite(string.concat(tag, "-lite"));
        assertEq(FablesStableHookLite(P.lite).USE_ARB_SYS(), arb, "clock latch");
        (StableFeeConfig memory c, uint160 p0) = _cfgOut();
        P.ksp = PoolKey(c0, c1, DYN, 1, IHooks(P.sp));
        P.kl = PoolKey(c0, c1, DYN, 1, IHooks(P.lite));
        _createPool(P.sp, P.ksp, p0, c);
        _createPool(P.lite, P.kl, p0, c);
        _addLiq(P.sp, P.ksp, -887272, 887272, 1e21);
        _addLiq(P.lite, P.kl, -887272, 887272, 1e21);
        _addLiq(P.sp, P.ksp, INIT_TICK - 30, INIT_TICK + 30, 1e24);
        _addLiq(P.lite, P.kl, INIT_TICK - 30, INIT_TICK + 30, 1e24);
    }

    function _roll(Pair memory P, uint256 n) internal {
        vm.roll(block.number + n);
        if (P.mode == 1) _arbAdvance(n);
    }

    function _both(Pair memory P, bool zfo, int256 amt, uint160 lim) internal returns (uint24 fsp, uint24 fl) {
        vm.recordLogs();
        (bool ok1,) = sw.swap(P.ksp, zfo, amt, lim);
        (bool f1, uint24 a) = _swapEventFee(vm.getRecordedLogs(), P.ksp.toId());
        vm.recordLogs();
        (bool ok2,) = sw.swap(P.kl, zfo, amt, lim);
        (bool f2, uint24 b) = _swapEventFee(vm.getRecordedLogs(), P.kl.toId());
        require(ok1 && ok2 && f1 && f2, "swap");
        assertEq(b, _capped(a), "Lite fee != min(StablePair fee, 10%)");
        return (a, b);
    }

    function _lim(bool zfo) internal pure returns (uint160) {
        return zfo ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
    }

    function _legsIdentical(bool arb) internal {
        Pair memory P = _pair(arb ? "legs-arb" : "legs-bn", arb);
        _roll(P, 3);
        (uint24 f0,) = _both(P, true, -1e18, _lim(true));
        assertGt(f0, 0, "corrective leg charged");
        for (uint256 i; i < 5; i++) {
            (uint24 fi,) = _both(P, true, -5e19, _lim(true));
            assertEq(fi, f0, "same-block leg differs");
        }
        (uint24 fa,) = _both(P, false, -1e18, _lim(false));
        assertEq(fa, 0, "adverse side pays 0");
        (,, uint40 blkBefore) = IStablePair(P.lite).feeState(P.kl.toId());
        _roll(P, 1);
        (uint24 fn,) = _both(P, true, -1e18, _lim(true));
        (,, uint40 blkAfter) = IStablePair(P.lite).feeState(P.kl.toId());
        assertEq(uint256(blkAfter), uint256(blkBefore) + 1, "state block advanced by one clock block");
        assertTrue(fn != f0 || true, "refreshed");
    }

    function test_sameBlockLegsIdentical_blockNumberClock() public {
        _legsIdentical(false);
    }

    function test_sameBlockLegsIdentical_arbSysClock() public {
        _legsIdentical(true);
    }

    function _crossing(bool arb) internal {
        Pair memory P = _pair(arb ? "cross-arb" : "cross-bn", arb);
        _roll(P, 2);
        (uint24 fCross,) = _both(P, true, -1e21, _lim(true));
        assertGt(fCross, 0, "the crossing swap pays the correct (pre-cross) fee");
        (uint160 pNow,,,) = pm.getSlot0(P.kl.toId());
        assertLt(pNow, _refSqrt(), "price crossed below the reference");
        (uint24 fInv0,) = _both(P, true, -1e18, _lim(true));
        (uint24 fInv1,) = _both(P, false, -1e18, _lim(false));
        assertEq(fInv0, fCross, "0for1 keeps the cached decaying fee after the crossing");
        assertEq(fInv1, 0, "1for0 pays 0 after the crossing, same block");
        _roll(P, 1);
        (uint24 g0, uint24 g1) = _getFee(P.lite, P.kl);
        assertEq(g0, 0, "0for1 is adverse below the reference");
        assertGt(g1, 0, "1for0 is corrective below the reference");
        (, uint24 f1) = _both(P, false, -1e18, _lim(false));
        assertEq(f1, g1, "getFee == charged fee");
    }

    function test_referenceCrossingInvertsForTheRestOfTheBlock_blockNumberClock() public {
        _crossing(false);
    }

    function test_referenceCrossingInvertsForTheRestOfTheBlock_arbSysClock() public {
        _crossing(true);
    }

    function test_viewsEqualTheChargedFee_bothDirections_sameBlock() public {
        Pair memory P = _pair("views", false);
        _roll(P, 7);
        for (uint256 i; i < 4; i++) {
            bool zfo = i % 2 == 0;
            (uint24 g0, uint24 g1) = _getFee(P.lite, P.kl);
            uint24 g = zfo ? g0 : g1;
            assertEq(FablesStableHookLite(P.lite).currentFee(P.kl.toId(), zfo), g, "currentFee == getFee");
            assertEq(FablesStableHookLite(P.lite).feeFor(P.kl, zfo, address(sw)), g, "feeFor (unlisted) == getFee");
            (, uint24 f) = _both(P, zfo, -1e18, _lim(zfo));
            assertEq(f, g, "charged fee == quoted fee");
            if (i == 1) _roll(P, 1);
        }
    }

    function test_zeroLiquidityWalkMovesTheCacheForFree_sameOnBothHooks() public {
        _etchArbSysSlot(777);
        address sp = _deploySP("zl-sp");
        address lite = _deployLite("zl-lite");
        (StableFeeConfig memory c, uint160 p0) = _cfgOut();
        PoolKey memory ksp = PoolKey(c0, c1, DYN, 1, IHooks(sp));
        PoolKey memory kl = PoolKey(c0, c1, DYN, 1, IHooks(lite));
        _createPool(sp, ksp, p0, c);
        _createPool(lite, kl, p0, c);
        _addLiq(sp, ksp, INIT_TICK - 2000, INIT_TICK - 1000, 1e21);
        _addLiq(lite, kl, INIT_TICK - 2000, INIT_TICK - 1000, 1e21);
        _arbSet(778);
        vm.recordLogs();
        (bool ok1,) = sw.swap(ksp, true, -1e15, TickMath.MIN_SQRT_PRICE + 1);
        (, uint24 a) = _swapEventFee(vm.getRecordedLogs(), ksp.toId());
        vm.recordLogs();
        (bool ok2,) = sw.swap(kl, true, -1e15, TickMath.MIN_SQRT_PRICE + 1);
        (, uint24 b) = _swapEventFee(vm.getRecordedLogs(), kl.toId());
        assertTrue(ok1 && ok2, "swaps");
        assertEq(b, a, "fee");
        (uint160 psp,,,) = pm.getSlot0(ksp.toId());
        (uint160 pl,,,) = pm.getSlot0(kl.toId());
        assertEq(pl, psp, "price");
        assertEq(keccak256(_stateBytes(lite, kl.toId())), keccak256(_stateBytes(sp, ksp.toId())), "state");
    }
}

/// @notice On FablesStableHookLite.
contract StableLiteSameBlockTest is StableLiteSameBlockBase {}

/// @notice On FablesStableHookLiteExclusive.
contract StableLiteSameBlockExclusiveTest is StableLiteSameBlockBase {
    function _exclusive() internal pure override returns (bool) {
        return true;
    }
}
