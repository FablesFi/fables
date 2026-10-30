// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

// Beyond +-10% of the reference the stable fee reads the real price, as StablePair, and only floors the decay target
// at its value at 10%. Side by side with the deployed StablePair bytecode: after a dump past the window the trade back
// pays at least min(StablePair, 10%) (a carried fee rises with the further move); with targetMultiplier < 100 the fee
// keeps StablePair's capped level; a fresh jump keeps the cap as long as StablePair; a walk through empty ticks still
// pays the edge target; inside the window the two are identical.

import "../utils/StableTestBase.sol";
import {StableFeeCalculation} from "../../src/libraries/StableFeeCalculation.sol";

abstract contract StableWindowFloorBase is StableTestBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint256 internal constant WINDOW_X96 = 71305346262837903834189555302; // 0.9 in Q96

    SeqSwapper internal sw;
    address internal sp;
    address internal lite;
    PoolKey internal ksp;
    PoolKey internal kl;

    struct Out {
        uint24 fee;
        int128 a0;
        int128 a1;
    }

    function _fables(string memory tag) internal virtual returns (address);

    /// Both pools: same config, same reference, full-range dust plus a deep book `lo..hi` around the reference.
    function _pair(uint24 k, uint24 opt, uint8 tm, int24 lo, int24 hi, bool fullRange) internal {
        setUpChain();
        sw = new SeqSwapper(pm);
        MockERC20(Currency.unwrap(c0)).mint(address(sw), BIG);
        MockERC20(Currency.unwrap(c1)).mint(address(sw), BIG);
        sp = _deploySP("wf-sp");
        lite = _fables("wf-lite");
        StableFeeConfig memory c =
            StableFeeConfig({k: k, optimalFeeE6: opt, targetMultiplier: tm, referenceSqrtPriceX96: _refSqrt()});
        ksp = PoolKey(c0, c1, DYN, 1, IHooks(sp));
        kl = PoolKey(c0, c1, DYN, 1, IHooks(lite));
        _createPool(sp, ksp, _refSqrt(), c);
        _createPool(lite, kl, _refSqrt(), c);
        if (fullRange) {
            _addLiq(sp, ksp, -887272, 887272, 1e21);
            _addLiq(lite, kl, -887272, 887272, 1e21);
        }
        _addLiq(sp, ksp, INIT_TICK + lo, INIT_TICK + hi, 1e24);
        _addLiq(lite, kl, INIT_TICK + lo, INIT_TICK + hi, 1e24);
    }

    function _swapOne(PoolKey memory k, bool zfo, int256 amt, uint160 lim) internal returns (Out memory o) {
        vm.recordLogs();
        (bool ok,) = sw.swap(k, zfo, amt, lim);
        require(ok, "swap failed");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 j; j < logs.length; j++) {
            if (
                logs[j].emitter == PM_ADDR && logs[j].topics[0] == SWAP_TOPIC
                    && logs[j].topics[1] == PoolId.unwrap(k.toId())
            ) {
                (o.a0, o.a1,,,, o.fee) = abi.decode(logs[j].data, (int128, int128, uint160, uint128, int24, uint24));
            }
        }
    }

    /// Both pools to sqrt price `to` (a full walk: one swap each, limit `to`).
    function _walkBoth(uint160 to) internal returns (uint24 fsp, uint24 fl) {
        (uint160 p,,,) = pm.getSlot0(ksp.toId());
        bool zfo = to < p;
        fsp = _swapOne(ksp, zfo, -1e30, to).fee;
        fl = _swapOne(kl, zfo, -1e30, to).fee;
        (uint160 a,,,) = pm.getSlot0(ksp.toId());
        (uint160 b,,,) = pm.getSlot0(kl.toId());
        require(a == to && b == to, "walk did not reach the target");
    }

    /// A dust away swap on both pools, so each block's state roll happens as on a live pool.
    function _touchBoth() internal {
        _swapOne(ksp, true, -1e3, TickMath.MIN_SQRT_PRICE + 1);
        _swapOne(kl, true, -1e3, TickMath.MIN_SQRT_PRICE + 1);
    }

    /// The reference sqrt price x `sqrtRatioE6` / 1e6.
    function _p(uint256 sqrtRatioE6) internal pure returns (uint160) {
        return uint160(uint256(_refSqrt()) * sqrtRatioE6 / 1_000_000);
    }

    function _assertNotBelow(string memory tag) internal view {
        (uint24 s0, uint24 s1) = _getFee(sp, ksp);
        (uint24 l0, uint24 l1) = _getFee(lite, kl);
        assertGe(l0, _capped(s0), string.concat(tag, ": 0for1 below min(StablePair, 10%)"));
        assertGe(l1, _capped(s1), string.concat(tag, ": 1for0 below min(StablePair, 10%)"));
    }

    function _edgeTargetPips(uint24 opt, uint8 tm) internal pure returns (uint24) {
        uint256 far = StableFeeCalculation.calculateFarBoundaryFee(WINDOW_X96, opt);
        uint256 close = uint256(StableFeeCalculation.calculateCloseBoundaryFee(WINDOW_X96, opt));
        return StableFeeCalculation.toFeeE6(far - close * tm / 100);
    }

    /* ------------------------------------------------- (a) ------------------------------------------------- */

    /// Parked at -9% with a decayed fee, dumped to -20% at 0 fee: the next block's trade back pays at least
    /// min(StablePair, 10%) and takes no more token0 out than on StablePair.
    function test_a_dumpPastTheWindowRaisesTheCarriedFee() public {
        _pair(K07, 50, 100, -3000, 600, true);
        _rollClock(1);
        _walkBoth(_p(953_939)); // price ratio 0.91
        _rollClock(100);
        (uint24 dSp, uint24 dL) = _walkBoth(_p(894_427)); // 0.80, away: 0 fee
        assertEq(dSp, 0);
        assertEq(dL, 0);
        _rollClock(1);
        _assertNotBelow("after the dump");
        Out memory oSp = _swapOne(ksp, false, -1e21, TickMath.MAX_SQRT_PRICE - 1);
        Out memory oL = _swapOne(kl, false, -1e21, TickMath.MAX_SQRT_PRICE - 1);
        assertGe(oL.fee, _capped(oSp.fee), "the trade back pays at least min(StablePair, 10%)");
        assertGt(oL.fee, 80_000, "~8.5%, not ~0.8%");
        assertLe(uint256(uint128(oL.a0)), uint256(uint128(oSp.a0)), "no extra token0 out of the Fables pool");
    }

    /// The whole decay after the dump stays at or above StablePair's (capped) path.
    function test_a_feePathAfterTheDumpFollowsStablePair() public {
        _pair(K07, 50, 100, -3000, 600, true);
        _rollClock(1);
        _walkBoth(_p(953_939));
        _rollClock(100);
        _walkBoth(_p(894_427));
        for (uint256 b = 1; b <= 12; b++) {
            _rollClock(1);
            _assertNotBelow(string.concat("block +", vm.toString(b)));
            _touchBoth();
        }
    }

    /// A further away move while already beyond the window (parked at -15%, then -25%) raises the carried fee too.
    function test_a_furtherMoveBeyondTheWindow() public {
        _pair(K07, 50, 100, -4000, 600, true);
        _rollClock(1);
        _walkBoth(_p(921_954)); // 0.85
        _rollClock(100);
        _touchBoth();
        _rollClock(1);
        _walkBoth(_p(866_025)); // 0.75
        _rollClock(1);
        _assertNotBelow("further beyond");
        (, uint24 l1) = _getFee(lite, kl);
        assertGt(l1, 50_000, "the move from 0.85 to 0.75 raises the fee");
    }

    /// One actor dumping and buying back loses on both pools: the higher fee goes to the LPs.
    function test_a_dumpAndBuyBackLosesOnBoth() public {
        _pair(K07, 50, 100, -3000, 600, true);
        uint160 p9 = _p(953_939);
        _rollClock(1);
        _walkBoth(p9);
        _rollClock(100);
        Out memory dSp = _swapOne(ksp, true, -1e30, _p(894_427));
        Out memory dL = _swapOne(kl, true, -1e30, _p(894_427));
        _rollClock(1);
        Out memory bSp = _swapOne(ksp, false, -1e30, p9);
        Out memory bL = _swapOne(kl, false, -1e30, p9);
        assertLe(int256(dSp.a0) + int256(bSp.a0), 1, "no token0 gained on StablePair");
        assertLe(int256(dL.a0) + int256(bL.a0), 1, "no token0 gained on Fables");
        assertLt(int256(dL.a1) + int256(bL.a1), 0, "token1 lost to the fee on Fables");
        assertLe(int256(dL.a1) + int256(bL.a1), int256(dSp.a1) + int256(bSp.a1) + 1e18, "Fables costs at least ~SP");
    }

    /* ------------------------------------------------- (b) ------------------------------------------------- */

    /// targetMultiplier 50, parked at -20%: StablePair's target is ~10%, so the capped fee stays at 10%.
    function test_b_tm50ParkedBeyondTheWindowKeepsTheCap() public {
        _pair(K07, 100, 50, -3000, 600, true);
        _rollClock(1);
        _walkBoth(_p(894_427));
        for (uint256 i = 0; i < 6; i++) {
            _rollClock(50);
            _touchBoth();
        }
        _rollClock(1);
        _assertNotBelow("TM 50 parked");
        (, uint24 l1) = _getFee(lite, kl);
        assertEq(l1, 100_000, "the 10% cap");
    }

    /* ------------------------------------------------- (c) ------------------------------------------------- */

    /// A fresh jump from the reference to -20%: StablePair's start (20%) keeps the cap for two blocks.
    function test_c_freshJumpKeepsTheCapAsLongAsStablePair() public {
        _pair(K07, 50, 100, -3000, 600, true);
        _rollClock(1);
        _walkBoth(_p(894_427));
        for (uint256 b = 1; b <= 6; b++) {
            _rollClock(1);
            _assertNotBelow(string.concat("fresh jump, block +", vm.toString(b)));
            _touchBoth();
        }
    }

    /* --------------------------------- a walk through empty ticks still pays --------------------------------- */

    /// A walk through the book and the empty ticks to 1% of the reference, a full decay, then buy the book back.
    /// StablePair's target there is ~0; the Fables trade back pays the target at the window edge.
    function _r53(uint24 opt) internal {
        _pair(K07, opt, 100, -200, 200, false);
        _rollClock(1);
        _walkBoth(_p(100_000));
        _rollClock(500);
        Out memory oSp = _swapOne(ksp, false, -1e30, _refSqrt());
        Out memory oL = _swapOne(kl, false, -1e30, _refSqrt());
        assertEq(oL.fee, _edgeTargetPips(opt, 100), "the target at the window edge");
        assertGt(oL.fee, oSp.fee, "above StablePair's ~0");
        assertGt(uint256(uint128(-oL.a1)), uint256(uint128(-oSp.a1)), "the buy-back pays more on Fables");
    }

    function test_r53_walkFarStillPaysTheEdgeTarget_opt50() public {
        _r53(50); // 91 pips vs StablePair 2
    }

    function test_r53_walkFarStillPaysTheEdgeTarget_opt1pct() public {
        _r53(10_000); // 18,091 pips vs StablePair 202
    }

    /* --------------------------------------------- inside: equal --------------------------------------------- */

    function test_insideTheWindowIdentical() public {
        _pair(K07, 50, 100, -3000, 600, true);
        _rollClock(1);
        _walkBoth(_p(974_679)); // 0.95
        _rollClock(30);
        _walkBoth(_p(959_166)); // 0.92
        _rollClock(1);
        (uint24 s0, uint24 s1) = _getFee(sp, ksp);
        (uint24 l0, uint24 l1) = _getFee(lite, kl);
        assertEq(l0, _capped(s0));
        assertEq(l1, _capped(s1));
        (uint40 dSp, uint160 pSp,) = IStablePair(sp).feeState(ksp.toId());
        (uint40 dL, uint160 pL,) = IStablePair(lite).feeState(kl.toId());
        assertEq(dL, dSp);
        assertEq(pL, pSp);
    }

    /* ------------------------------------------- the property, fuzzed ------------------------------------------- */

    /// forge-config: default.fuzz.runs = 200
    /// forge-config: deep.fuzz.runs = 3000
    /// Random walks over price ratios ~0.49 .. 1.69 (both sides, inside and beyond the window), block gaps and
    /// configs: the Fables fee is never below min(StablePair, 10%) in either direction.
    function testFuzz_neverBelowCappedStablePair(uint256 seed, uint24 opt, uint8 tm, uint24 k) public {
        opt = uint24(bound(opt, 1, 10_000));
        tm = uint8(bound(tm, 1, 100));
        k = uint24(bound(k, 1_677_722, 16_609_443)); // 0.1 .. 0.99 per block
        _pair(k, opt, tm, -7000, 7000, true);
        for (uint256 s = 0; s < 24; s++) {
            uint256 x = uint256(keccak256(abi.encode(seed, s)));
            if (x % 3 == 0) {
                _rollClock(1 + (x >> 8) % 40);
            } else {
                uint160 to = _p(700_000 + (x >> 16) % 600_001);
                (uint160 p,,,) = pm.getSlot0(ksp.toId());
                if (to != p) _walkBoth(to);
            }
            _assertNotBelow("walk");
        }
    }
}

/// FablesStableHookLiteExclusive (ledger-only liquidity).
contract StableWindowFloorExclusiveTest is StableWindowFloorBase {
    function _fables(string memory tag) internal override returns (address) {
        return _deployBuild(tag, true);
    }
}

/// FablesStableHookLite (open build).
contract StableWindowFloorTest is StableWindowFloorBase {
    function _fables(string memory tag) internal override returns (address) {
        return _deployBuild(tag, false);
    }
}
