// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import "../../utils/StableTestBase.sol";
import {DiscountLib} from "../../../src/libraries/DiscountLib.sol";
import {StableRefModel} from "../../utils/StableRefModel.sol";

/// @notice The minimum fee through real swaps: every swap pays max(StablePair's fee, minimum) (StablePair from the
///         independent model), views equal the charged fee, no discount goes below the minimum, parking the price at the
///         reference does not avoid it, and changing it restarts the falling fee.
abstract contract StableLiteMinimumFeeBase is StableTestBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    address lite;
    SeqSwapper[2] sws;

    struct M {
        PoolKey k;
        PoolId id;
        uint256 swaps;
        uint256 raisedInBand;
        uint256 raisedOutOfBand;
        uint256 raisedBothWays;
        uint256 discountFloored;
        uint256 minSets;
    }

    function setUp() public {
        setUpChain();
        lite = _deployLite("mf-lite");
        for (uint256 i; i < 2; i++) {
            sws[i] = new SeqSwapper(pm);
            MockERC20(Currency.unwrap(c0)).mint(address(sws[i]), BIG);
            MockERC20(Currency.unwrap(c1)).mint(address(sws[i]), BIG);
        }
    }

    function _r(uint256 s, uint256 i) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(s, i, "mf")));
    }

    function _pool(uint256 x, uint160 p0) internal returns (M memory m) {
        uint160 ref = TickMath.getSqrtPriceAtTick(0);
        StableFeeConfig memory c = StableFeeConfig({
            k: x % 3 == 0 ? K07 : uint24(1 + (x >> 8) % ((1 << 24) - 1)),
            optimalFeeE6: x % 2 == 0 ? 50 : uint24((x >> 40) % 10_001),
            targetMultiplier: uint8(1 + (x >> 64) % 100),
            referenceSqrtPriceX96: ref
        });
        m.k = PoolKey(c0, c1, DYN, 1, IHooks(lite));
        m.id = m.k.toId();
        _createPool(lite, m.k, p0 == 0 ? ref : p0, c);
        _addLiq(lite, m.k, -887272, 887272, 1e22);
        _addLiq(lite, m.k, -30, 30, 1e24);
    }

    function _live(PoolId id) internal view returns (uint160 p) {
        (p,,,) = pm.getSlot0(id);
    }

    function _charged(uint256 who, PoolKey memory k, bool z, int256 spec) internal returns (bool ok, uint24 fee) {
        vm.recordLogs();
        (ok,) = sws[who].swap(k, z, spec, z ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1);
        if (ok) (, fee) = _swapEventFee(vm.getRecordedLogs(), k.toId());
    }

    /// StablePair's fee for this swap from the independent model (capped), and with `sender`'s discount.
    function _model(PoolId id, bool z, address sender) internal view returns (uint24 raw, uint24 rawFor) {
        FablesStableHookLite h = FablesStableHookLite(lite);
        StableRefModel.Config memory c;
        {
            (uint24 k, uint24 opt, uint8 tm, uint160 ref) = h.feeConfig(id);
            c = StableRefModel.Config(k, opt, tm, ref);
        }
        StableRefModel.State memory st;
        {
            (uint40 d, uint160 sp, uint40 bn) = h.feeState(id);
            st = StableRefModel.State(d, sp, bn);
        }
        raw = _capped(StableRefModel.quote(c, st, _live(id), block.number, z).feeE6);
        rawFor = _modelDiscount(id, raw, z, sender);
    }

    function _modelDiscount(PoolId id, uint24 raw, bool z, address sender) internal view returns (uint24) {
        FablesStableHookLite h = FablesStableHookLite(lite);
        (uint8 seed, uint32 bloom) = h.discountFilter(id);
        uint256 entry;
        {
            (uint16 bps, uint24 mf, uint8 dirs, uint40 expiry) = h.discountOf(id, sender);
            entry = DiscountLib.pack(bps, mf, dirs, expiry);
        }
        return StableRefModel.discounted(raw, bloom, seed, sender, entry, z, block.timestamp);
    }

    function _minFee(uint256 x) internal pure returns (uint16) {
        uint256 sel = x % 10;
        if (sel < 2) return 0;
        if (sel < 6) return uint16(1 + (x >> 8) % 120);
        if (sel < 9) return uint16(1 + (x >> 8) % 5_000);
        return uint16((x >> 8) % 65_536);
    }

    /// forge-config: default.fuzz.runs = 256
    /// forge-config: deep.fuzz.runs = 4000
    function testFuzz_minimumFee(uint256 seed) public {
        M memory m = _setupWalk(seed, false);
        for (uint256 s = 1; s <= 30; s++) {
            _step(m, _r(seed, s));
        }
        assertGt(m.swaps, 0);
    }

    function _setupWalk(uint256 seed, bool discount) internal returns (M memory m) {
        uint256 x = _r(seed, 0);
        uint160 ref = TickMath.getSqrtPriceAtTick(0);
        uint160 p0 = (x >> 100) % 3 == 0 ? 0 : uint160(uint256(ref) * (999_000 + (x >> 120) % 2_001) / 1_000_000);
        m = _pool(x, p0);
        if (discount || (x >> 140) % 2 == 0) {
            PoolId[] memory ids = new PoolId[](1);
            ids[0] = m.id;
            uint8 dirs = discount ? uint8(DiscountLib.DIR_BOTH) : uint8(1 + (x >> 150) % 3);
            uint16 bps = discount ? 5_000 : uint16(1 + (x >> 160) % 5_000);
            FablesStableHookLite(lite).setDiscount(ids, address(sws[0]), bps, 0, dirs, uint40(block.timestamp + 1 days));
        }
        FablesStableHookLite(lite).setMinimumFee(m.k, _minFee(x >> 170));
    }

    function _step(M memory m, uint256 x) internal {
        if (x % 5 == 0) {
            _rollClock(1 + (x >> 8) % 20);
            return;
        }
        FablesStableHookLite h = FablesStableHookLite(lite);
        if (x % 7 == 1) {
            h.setMinimumFee(m.k, _minFee(x >> 16));
            m.minSets++;
            return;
        }
        bool z = (x >> 1) & 1 == 0;
        uint256 who = (x >> 2) % 2;
        uint24 gotFor = _checkViews(m, z, who);
        (bool ok, uint24 charged) = _charged(who, m.k, z, -int256(10 ** (15 + (x >> 40) % 8)));
        if (!ok) return;
        assertEq(charged, gotFor, "charged != feeFor");
        m.swaps++;
    }

    /// Views against max(model, minimum); returns the fee `sws[who]` should be charged.
    function _checkViews(M memory m, bool z, uint256 who) internal returns (uint24 gotFor) {
        FablesStableHookLite h = FablesStableHookLite(lite);
        (uint24 raw, uint24 rawFor) = _model(m.id, z, address(sws[who]));
        uint24 minFee = h.minimumFee(m.id);
        uint24 got = h.currentFee(m.id, z);
        gotFor = h.feeFor(m.k, z, address(sws[who]));
        (uint24 g0, uint24 g1) = h.getFee(m.k);
        assertEq(z ? g0 : g1, got, "getFee != currentFee");
        assertEq(got, minFee > raw ? minFee : raw, "currentFee != max(StablePair fee, minimum)");
        assertEq(gotFor, minFee > rawFor ? minFee : rawFor, "feeFor != max(discounted fee, minimum)");
        if (minFee > rawFor) {
            if (rawFor < raw) m.discountFloored++;
            (, uint24 opt,, uint160 ref) = h.feeConfig(m.id);
            uint256 ratio = StableFeeCalculation.calculatePriceRatioX96(_live(m.id), ref);
            if (StableFeeCalculation.calculateCloseBoundaryFee(ratio, opt) > 0) m.raisedOutOfBand++;
            else m.raisedInBand++;
            m.raisedBothWays |= z ? 1 : 2;
        }
    }

    function test_atReference_bothSidesRaised() public {
        M memory m = _pool(0, 0);
        FablesStableHookLite h = FablesStableHookLite(lite);
        // at the reference both sides pay the band (50)
        assertEq(h.currentFee(m.id, true), 50);
        assertEq(h.currentFee(m.id, false), 50);
        h.setMinimumFee(m.k, 30);
        assertEq(h.currentFee(m.id, true), 50, "minimum below the band: no change");
        assertEq(h.currentFee(m.id, false), 50, "minimum below the band: no change");
        h.setMinimumFee(m.k, 80);
        assertEq(h.currentFee(m.id, true), 80);
        assertEq(h.currentFee(m.id, false), 80);
        (bool ok, uint24 charged) = _charged(0, m.k, false, -1e18);
        assertTrue(ok);
        assertEq(charged, 80);
    }

    function test_outOfBand_awayNoLongerFree_backKeepsItsFee() public {
        uint160 ref = TickMath.getSqrtPriceAtTick(0);
        M memory m = _pool(1, uint160(uint256(ref) * 1_002_000 / 1_000_000));
        FablesStableHookLite h = FablesStableHookLite(lite);
        h.updateFeeConfig(m.k, K07, 7, 100);
        // price above the reference, outside the band: oneForZero (pushing up) pays 0 in StablePair
        assertEq(h.currentFee(m.id, false), 0, "StablePair: away pays 0");
        uint24 back = h.currentFee(m.id, true);
        assertGt(back, 100);
        h.setMinimumFee(m.k, 100);
        assertEq(h.currentFee(m.id, false), 100, "away pays the minimum");
        assertEq(h.currentFee(m.id, true), back, "back already pays more than the minimum");
        (bool ok, uint24 charged) = _charged(1, m.k, false, -1e18);
        assertTrue(ok);
        assertEq(charged, 100);
    }

    /// Parking the price at the reference in one block, then dumping through it in the next, still pays the minimum.
    function test_parkAtReferenceThenDump_paysTheMinimum() public {
        uint160 ref = TickMath.getSqrtPriceAtTick(0);
        M memory m = _pool(0, uint160(uint256(ref) * 999_995 / 1_000_000));
        FablesStableHookLite h = FablesStableHookLite(lite);
        h.setMinimumFee(m.k, 5_000);
        _rollClock(1);
        // block N: buy token0 up to exactly the reference
        sws[0].swap(m.k, false, -1e24, ref);
        assertEq(_live(m.id), ref, "parked at the reference");
        _rollClock(1);
        // block N+1: the dump through the reference pays the minimum
        assertEq(h.currentFee(m.id, true), 5_000);
        (bool ok, uint24 charged) = _charged(0, m.k, true, -1_000e18);
        assertTrue(ok);
        assertEq(charged, 5_000, "dump pays the minimum");
        assertLt(_live(m.id), ref, "price ends below the reference");
    }

    /// Lowering the minimum after a brake restarts the falling fee, so the held price gap goes back to auction.
    function test_lowerMinimum_restartsTheAuction() public {
        uint160 ref = TickMath.getSqrtPriceAtTick(0);
        M memory m = _pool(1, uint160(uint256(ref) * 1_002_000 / 1_000_000));
        FablesStableHookLite h = FablesStableHookLite(lite);
        h.updateFeeConfig(m.k, K07, 7, 100);
        h.setMinimumFee(m.k, 10_000);
        _rollClock(50);
        assertEq(h.currentFee(m.id, true), 10_000, "the brake binds the side back too");
        h.setMinimumFee(m.k, 0);
        assertGt(h.currentFee(m.id, true), 3_000, "the auction restarts at the far boundary");
        _rollClock(50);
        assertLt(h.currentFee(m.id, true), 100, "and falls again");
    }

    function test_discountFlooredAtMinimum() public {
        M memory m = _pool(0, 0);
        FablesStableHookLite h = FablesStableHookLite(lite);
        PoolId[] memory ids = new PoolId[](1);
        ids[0] = m.id;
        h.setDiscount(ids, address(sws[0]), 5_000, 0, uint8(DiscountLib.DIR_BOTH), uint40(block.timestamp + 1 days));
        assertEq(h.feeFor(m.k, false, address(sws[0])), 25, "50% off the band");
        h.setMinimumFee(m.k, 40);
        assertEq(h.feeFor(m.k, false, address(sws[0])), 40, "discount stops at the minimum");
        assertEq(h.feeFor(m.k, true, address(sws[0])), 40, "both directions");
        assertEq(h.feeFor(m.k, true, address(sws[1])), 50, "no discount: the band");
        (bool ok, uint24 charged) = _charged(0, m.k, false, -1e18);
        assertTrue(ok);
        assertEq(charged, 40);
    }

    function test_typedTwinChargesTheSame() public {
        address typed = _deployTyped("mf-typed");
        uint160 ref = TickMath.getSqrtPriceAtTick(0);
        StableFeeConfig memory c =
            StableFeeConfig({k: K07, optimalFeeE6: 7, targetMultiplier: 100, referenceSqrtPriceX96: ref});
        uint160 p0 = uint160(uint256(ref) * 1_001_000 / 1_000_000);
        address[2] memory hs = [lite, typed];
        uint24[2] memory charged;
        for (uint256 i; i < 2; i++) {
            PoolKey memory k = PoolKey(c0, c1, DYN, 1, IHooks(hs[i]));
            _createPool(hs[i], k, p0, c);
            _addLiq(hs[i], k, -600, 600, 1e22);
            FablesStableHookLite(hs[i]).setMinimumFee(k, 333);
            bool ok;
            (ok, charged[i]) = _charged(0, k, false, -1e18);
            assertTrue(ok);
        }
        assertEq(charged[0], 333);
        assertEq(charged[1], charged[0], "typed twin differs");
    }

    function test_walkReachesEveryRegime() public {
        M memory t;
        for (uint256 i = 1; i <= 12; i++) {
            uint256 snap = vm.snapshotState();
            M memory m = this.walkExt(uint256(keccak256(abi.encode("mf-walk", i))));
            vm.revertToState(snap);
            t.swaps += m.swaps;
            t.raisedInBand += m.raisedInBand;
            t.raisedOutOfBand += m.raisedOutOfBand;
            t.raisedBothWays |= m.raisedBothWays;
            t.discountFloored += m.discountFloored;
            t.minSets += m.minSets;
        }
        assertGt(t.raisedInBand, 0, "never raised in band");
        assertGt(t.raisedOutOfBand, 0, "never raised out of band");
        assertEq(t.raisedBothWays, 3, "not raised in both directions");
        assertGt(t.discountFloored, 0, "no discount stopped at the minimum");
        assertGt(t.minSets, 0, "the minimum never changed mid-walk");
    }

    function walkExt(uint256 seed) external returns (M memory m) {
        require(msg.sender == address(this));
        m = _setupWalk(seed, true);
        for (uint256 s = 1; s <= 30; s++) {
            _step(m, _r(seed, s));
        }
    }
}

/// @notice On FablesStableHookLite.
contract StableLiteMinimumFeeTest is StableLiteMinimumFeeBase {}

/// @notice On FablesStableHookLiteExclusive.
contract StableLiteMinimumFeeExclusiveTest is StableLiteMinimumFeeBase {
    function _exclusive() internal pure override returns (bool) {
        return true;
    }
}
