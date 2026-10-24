// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {FeeRef} from "../../src/libraries/FeeRef.sol";
import {PoolWordLib} from "../../src/libraries/PoolWordLib.sol";
import {DiscountLib} from "../../src/libraries/DiscountLib.sol";

/// @notice `FeeRef.resolve` against an independent model over pokes, discounts and the CF.
contract FeeRefModelFuzzTest is Test {
    using PoolWordLib for uint256;

    uint256 internal constant NOW = 1_800_000_000;

    struct In {
        uint24 base0;
        uint24 base1;
        uint24 floor_;
        uint24 cap;
        uint24 poke0;
        uint24 poke1;
        uint32 ttl;
        bool expired;
        address sender;
        bool listed;
        uint16 bps;
        uint24 minFee;
        uint8 dirs;
        uint32 dTtl;
        bool dExpired;
        bool cfOn;
        uint8 mode;
        uint16 k;
        uint24 cfCap;
        uint16 band16;
        uint16 tau;
        uint8 period;
        uint16 dt;
        int24 tick;
        int24 anchorTicks;
        bool zeroForOne;
    }

    struct Case {
        uint256 w;
        uint256 entry;
        uint256 cf;
        int24 tick;
        uint256 nowTs;
    }

    function _case(In memory i) internal pure returns (Case memory c) {
        c.nowTs = NOW;
        i.cap = uint24(bound(i.cap, 1, 100_000));
        i.floor_ = uint24(bound(i.floor_, 0, i.cap));
        i.base0 = uint24(bound(i.base0, i.floor_, i.cap));
        i.base1 = uint24(bound(i.base1, i.floor_, i.cap));
        i.poke0 = i.poke0 % 4 == 0 ? 0 : uint24(bound(i.poke0, 1, 100_000));
        i.poke1 = i.poke1 % 4 == 0 ? 0 : uint24(bound(i.poke1, 1, 100_000));
        uint256 expiry = i.expired ? bound(i.ttl, 0, NOW) : NOW + bound(i.ttl, 1, 72 hours);
        uint256 w = uint256(0).withBases(i.base0, i.base1).withBounds(i.floor_, i.cap);
        w = w.withPokes(i.poke0, i.poke1, uint40(expiry));
        uint8 seed = uint8(uint160(i.sender) % 128);
        if (i.listed) w = w.withSeed(seed).withBloom(DiscountLib.mask64(i.sender, seed));
        c.w = w.withCfOn(i.cfOn);
        uint256 dExpiry = i.dExpired ? bound(i.dTtl, 0, NOW) : NOW + bound(i.dTtl, 1, 90 days);
        c.entry =
            DiscountLib.pack(uint16(bound(i.bps, 0, 6_000)), i.minFee, uint8(bound(i.dirs, 0, 3)), uint40(dExpiry));
        uint16 tau = uint16(bound(i.tau, 5, 300));
        uint256 maxAge = 5 * uint256(tau) > 255 ? 255 : 5 * uint256(tau);
        c.tick = int24(bound(i.tick, -500_000, 500_000));
        c.cf = FeeRef.packCF(
            FeeRef.CFWord({
                tLast: uint40(NOW - bound(i.dt, 0, 400)),
                anchor: int32(int256(c.tick) * 256 + int256(bound(i.anchorTicks, -5_000, 5_000)) * 256),
                decay1: FeeRef.decay1Q32(tau),
                kQ8: uint16(bound(i.k, 1, 256)),
                cfCap: uint24(bound(i.cfCap, 1, 2_500)),
                band16: uint16(bound(i.band16, 0, 800)),
                maxAge: uint8(maxAge),
                period: uint8(bound(i.period, 1, maxAge - 1 < 60 ? maxAge - 1 : 60)),
                tau: tau,
                mode: uint8(i.mode % 2)
            })
        );
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    function _max(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a : b;
    }

    function _modelKeeperFee(uint256 w, bool zfo, uint256 nowTs) internal pure returns (uint256 fee) {
        uint256 base_ = zfo ? w.base0() : w.base1();
        uint256 poke_ = zfo ? w.poke0() : w.poke1();
        fee = base_;
        if (nowTs < w.expiry() && poke_ != 0) fee = _max(poke_, _max(w.floor(), _min(base_, w.cap()) / 2));
        fee = _min(fee, w.cap());
    }

    function _modelDiscount(uint256 fee, uint256 w, uint256 e, bool zfo, uint256 nowTs)
        internal
        pure
        returns (uint256)
    {
        uint256 bps = e & 0xffff;
        bool dir = ((e >> 40) & 0xff) & (zfo ? 1 : 2) != 0;
        if (bps == 0 || nowTs >= (e >> 48) & 0xffffffffff || !dir) return fee;
        bps = _min(bps, 5_000);
        uint256 d = FixedPointMathLib.divUp(fee * (10_000 - bps), 10_000);
        d = _max(d, _max(w.floor(), (e >> 16) & 0xffffff));
        return _min(d, fee);
    }

    function _modelSurcharge(uint256 cf, int256 anchor, int256 tick, bool zfo) internal pure returns (uint256) {
        int256 m = zfo ? anchor - tick * 256 : tick * 256 - anchor;
        if ((cf >> 192) & 1 == 1) m = -m;
        int256 x = m - int256((cf >> 144) & 0xffff) * 16;
        if (x <= 0) return 0;
        return _min((((cf >> 104) & 0xffff) * uint256(x) * 100) / 65_536, (cf >> 120) & 0xffffff);
    }

    function _anchor(uint256 cf) internal pure returns (int256) {
        return int256(int32(uint32(cf >> 40)));
    }

    /// forge-config: default.fuzz.runs = 4096
    /// forge-config: deep.fuzz.runs = 100000
    function testFuzz_resolveMatchesTheModel(In memory i) public pure {
        Case memory c = _case(i);
        (uint256 fee, uint256 cfNew) = FeeRef.resolve(c.w, i.zeroForOne, i.sender, c.entry, c.cf, c.tick, c.nowTs);

        uint256 expect = _modelKeeperFee(c.w, i.zeroForOne, c.nowTs);
        assertEq(FeeRef.keeperFee(c.w, i.zeroForOne, c.nowTs), expect, "keeperFee");
        if (i.listed) expect = _modelDiscount(expect, c.w, c.entry, i.zeroForOne, c.nowTs);

        if (!i.cfOn) {
            assertEq(fee, expect, "fee without CF");
            assertEq(cfNew, c.cf, "CF word passes through while off");
            return;
        }
        uint256 dt = c.nowTs - (c.cf & 0xffffffffff);
        int256 t = int256(c.tick) * 256;
        int256 a0 = _anchor(c.cf);
        if (dt < (c.cf >> 168) & 0xff) {
            assertEq(cfNew, c.cf, "inside the period: untouched");
        } else {
            assertEq(cfNew & 0xffffffffff, c.nowTs, "tLast = now");
            assertEq(cfNew >> 72, c.cf >> 72, "parameters untouched");
            int256 a1 = _anchor(cfNew);
            if (dt >= (c.cf >> 160) & 0xff) assertEq(a1, t, "maxAge: snapped to the tick");
            assertTrue((a1 - t) * (a0 - t) >= 0 && _absI(a1 - t) <= _absI(a0 - t), "new anchor between old and tick");
        }
        uint256 s = _modelSurcharge(c.cf, _anchor(cfNew), c.tick, i.zeroForOne);
        assertLe(s, (c.cf >> 120) & 0xffffff, "s <= cfCap");
        assertEq(fee, _min(expect + s, c.w.cap()), "fee = min(poke/discounted + s, cap)");
    }

    function _absI(int256 x) internal pure returns (uint256) {
        return x < 0 ? uint256(-x) : uint256(x);
    }

    /// forge-config: default.fuzz.runs = 2048
    /// forge-config: deep.fuzz.runs = 50000
    function testFuzz_decayFactorMatchesRpow(uint16 tau, uint16 dt) public pure {
        tau = uint16(bound(tau, 5, 300));
        uint256 maxAge = 5 * uint256(tau) > 255 ? 255 : 5 * uint256(tau);
        uint256 cf = FeeRef.packCF(
            FeeRef.CFWord({
                tLast: 0,
                anchor: 0,
                decay1: FeeRef.decay1Q32(tau),
                kQ8: 1,
                cfCap: 1,
                band16: 0,
                maxAge: uint8(maxAge),
                period: 1,
                tau: tau,
                mode: 0
            })
        );
        uint256 d = bound(dt, 0, 300);
        uint256 f = FeeRef.decayFactor(cf, d);
        if (d >= maxAge) {
            assertEq(f, 0, "full reset at maxAge");
            return;
        }
        assertLe(f, 1 << 32);
        if (d == 0) assertEq(f, 1 << 32);
        uint256 ref = FixedPointMathLib.rpow(FeeRef.decay1Q32(tau), d, 1 << 32);
        assertApproxEqAbs(f, ref, 2 * d + 2, "within the propagated truncation");
        if (d + 1 < maxAge) assertLe(FeeRef.decayFactor(cf, d + 1), f, "non-increasing");
    }

    /// forge-config: default.fuzz.runs = 2048
    /// forge-config: deep.fuzz.runs = 50000
    function testFuzz_decay1MatchesExp(uint16 tau) public pure {
        tau = uint16(bound(tau, 5, 300));
        uint256 expWad = uint256(FixedPointMathLib.expWad(-int256(1e18 / uint256(tau))));
        uint256 ref = (expWad << 32) / 1e18;
        assertApproxEqAbs(uint256(FeeRef.decay1Q32(tau)), ref, 2, "exp(-1/tau) in Q32");
    }

    function test_extremeTickAnchorFitsInt32() public pure {
        int256 a = int256(TickMath.MAX_TICK) * 256;
        assertLe(a, type(int32).max);
        assertGe(int256(TickMath.MIN_TICK) * 256, type(int32).min);
    }
}
