// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {PoolWordLib} from "../../src/libraries/PoolWordLib.sol";
import {DiscountLib} from "../../src/libraries/DiscountLib.sol";
import {FeeRef} from "../../src/libraries/FeeRef.sol";

/// @notice Symbolic checks (halmos `check_*`) over PoolWordLib, DiscountLib and FeeRef.
contract HalmosFeeLibs {
    using PoolWordLib for uint256;

    uint256 internal constant ABSOLUTE_MAX_FEE = 100_000;
    uint256 internal constant ALL = type(uint256).max;

    function check_poolWord_unpackPackIdentity(uint256 w) public pure {
        assert(PoolWordLib.pack(PoolWordLib.unpack(w)) == w);
    }

    function check_poolWord_packUnpackRoundTrip(
        uint24 b0,
        uint24 b1,
        uint24 p0,
        uint24 p1,
        uint40 exp,
        uint24 fl,
        uint24 cap,
        uint64 bloom,
        uint8 seed,
        bool cfOn
    ) public pure {
        PoolWordLib.PoolWord memory q = PoolWordLib.unpack(
            PoolWordLib.pack(PoolWordLib.PoolWord(b0, b1, p0, p1, exp, fl, cap, bloom, seed, cfOn))
        );
        assert(q.base0 == b0 && q.base1 == b1);
        assert(q.poke0 == p0 && q.poke1 == p1 && q.expiry == exp);
        assert(q.floor == fl && q.cap == cap);
        assert(q.bloom == bloom && q.seed == (seed & 0x7f) && q.cfOn == cfOn);
    }

    function check_poolWord_groupMasksTile() public pure {
        uint256[6] memory m = [
            PoolWordLib.BASES_MASK,
            PoolWordLib.POKES_MASK,
            PoolWordLib.BOUNDS_MASK,
            PoolWordLib.BLOOM_MASK,
            PoolWordLib.SEED_MASK,
            PoolWordLib.CF_ON_MASK
        ];
        uint256 union;
        for (uint256 i = 0; i < 6; ++i) {
            assert(union & m[i] == 0);
            union |= m[i];
        }
        assert(union == ALL);
    }

    function check_withBases_isolated(uint256 w, uint24 a, uint24 b) public pure {
        uint256 v = w.withBases(a, b);
        assert(v.base0() == a && v.base1() == b);
        assert((v ^ w) & ~PoolWordLib.BASES_MASK == 0);
    }

    function check_withPokes_isolated(uint256 w, uint24 a, uint24 b, uint40 e) public pure {
        uint256 v = w.withPokes(a, b, e);
        assert(v.poke0() == a && v.poke1() == b && v.expiry() == e);
        assert((v ^ w) & ~PoolWordLib.POKES_MASK == 0);
    }

    function check_withPokesCleared_isolated(uint256 w) public pure {
        uint256 v = w.withPokesCleared();
        assert(v.poke0() == 0 && v.poke1() == 0 && v.expiry() == 0);
        assert((v ^ w) & ~PoolWordLib.POKES_MASK == 0);
    }

    function check_withBounds_isolated(uint256 w, uint24 f, uint24 c) public pure {
        uint256 v = w.withBounds(f, c);
        assert(v.floor() == f && v.cap() == c);
        assert((v ^ w) & ~PoolWordLib.BOUNDS_MASK == 0);
    }

    function check_withBloom_isolated(uint256 w, uint64 b) public pure {
        uint256 v = w.withBloom(b);
        assert(v.bloom() == b);
        assert((v ^ w) & ~PoolWordLib.BLOOM_MASK == 0);
    }

    function check_withSeed_isolated(uint256 w, uint8 s) public pure {
        uint256 v = w.withSeed(s);
        assert(v.seed() == (s & 0x7f));
        assert((v ^ w) & ~PoolWordLib.SEED_MASK == 0);
        assert(v.cfOn() == w.cfOn());
    }

    function check_withCfOn_isolated(uint256 w, bool on) public pure {
        uint256 v = w.withCfOn(on);
        assert(v.cfOn() == on);
        assert((v ^ w) & ~PoolWordLib.CF_ON_MASK == 0);
    }

    function check_poolWord_sideGetters(uint256 w, bool z) public pure {
        assert(w.base(z) == (z ? w.base0() : w.base1()));
        assert(w.poke(z) == (z ? w.poke0() : w.poke1()));
    }

    function check_applyDiscount_band(uint256 fee, uint256 bps, uint256 minFee, uint256 floor_) public pure {
        if (fee >= 1 << 24) return;
        uint256 d = DiscountLib.applyDiscount(fee, bps, minFee, floor_);
        assert(d <= fee);
        assert(2 * d >= fee);
        if (fee == 0) assert(d == 0);
    }

    function check_applyDiscount_band_boundaryBps(uint256 fee, uint256 minFee, uint256 floor_) public pure {
        if (fee >= 1 << 24) return;
        uint16[8] memory bs = [uint16(0), 1, 2_500, 4_999, 5_000, 5_001, 10_000, type(uint16).max];
        for (uint256 i = 0; i < 8; ++i) {
            uint256 d = DiscountLib.applyDiscount(fee, bs[i], minFee, floor_);
            assert(d <= fee);
            assert(2 * d >= fee);
            if (fee == 0) assert(d == 0);
        }
    }

    function check_applyDiscount_exactWhenUnbound(uint256 fee, uint256 bps) public pure {
        if (fee >= 1 << 24 || bps > 5_000) return;
        uint256 d = DiscountLib.applyDiscount(fee, bps, 0, 0);
        assert(d == (fee * (10_000 - bps) + 9_999) / 10_000);
    }

    function check_applyDiscount_respectsLowerBound(uint256 fee, uint256 bps, uint256 minFee, uint256 floor_)
        public
        pure
    {
        if (fee >= 1 << 24) return;
        uint256 lo = floor_ > minFee ? floor_ : minFee;
        uint256 d = DiscountLib.applyDiscount(fee, bps, minFee, floor_);
        if (fee >= lo) assert(d >= lo);
        else assert(d == fee);
    }

    function check_applyEntry_onlyWhenLive(uint256 fee, uint256 floor_, uint256 e, bool z, uint256 nowTs) public pure {
        if (fee >= 1 << 24) return;
        uint256 r = DiscountLib.applyEntry(fee, floor_, e, z, nowTs);
        if (!DiscountLib.isLive(e, z, nowTs)) assert(r == fee);
        else assert(r <= fee && 2 * r >= fee);
    }

    function check_entry_roundTrip(uint16 bps, uint24 minFee, uint8 dirs, uint40 expiry) public pure {
        DiscountLib.Entry memory x = DiscountLib.unpack(DiscountLib.pack(bps, minFee, dirs, expiry));
        assert(x.bps == bps && x.minFee == minFee && x.dirs == dirs && x.expiry == expiry);
    }

    function check_bloom64_noFalseNegative(address account, uint256 seed, uint64 other) public pure {
        seed &= 0x7f;
        uint64 m = DiscountLib.mask64(account, seed);
        assert(m != 0);
        assert(DiscountLib.hit64(other | m, account, seed));
    }

    function check_bloom32_noFalseNegative(address account, uint256 seed, uint32 other) public pure {
        seed &= 0xff;
        uint32 m = DiscountLib.mask32(account, seed);
        assert(m != 0);
        assert(DiscountLib.hit32(other | m, account, seed));
    }

    function check_keeperFee_leCap(uint256 w, bool z, uint256 nowTs) public pure {
        assert(FeeRef.keeperFee(w, z, nowTs) <= w.cap());
    }

    function check_keeperFee_geFloorConfigured(uint256 w, bool z, uint256 nowTs) public pure {
        if (!_configured(w)) return;
        uint256 f = FeeRef.keeperFee(w, z, nowTs);
        assert(f >= w.floor());
        assert(f <= ABSOLUTE_MAX_FEE);
    }

    function check_keeperFee_pokeRules(uint256 w, bool z, uint256 nowTs) public pure {
        uint256 f = FeeRef.keeperFee(w, z, nowTs);
        uint256 cap = w.cap();
        uint256 pre = w.base(z);
        uint256 capped = pre > cap ? cap : pre;
        if (nowTs < w.expiry() && w.poke(z) != 0) {
            uint256 fl = w.floor() > cap ? cap : w.floor();
            assert(f >= fl);
            assert(f >= capped / 2);
            uint256 p = w.poke(z) > cap ? cap : w.poke(z);
            assert(f >= p);
        } else {
            assert(f == capped);
        }
    }

    function check_cfStep_leCfCap(uint256 cf, int24 tick, bool z, uint256 nowTs) public pure {
        (uint256 s,) = FeeRef.cfStep(cf, tick, z, nowTs);
        assert(s <= (cf >> FeeRef.CF_CAP_SHIFT) & 0xffffff);
    }

    function check_cfStep_leCfCap_continuation(uint256 cf, int24 tick, bool z, uint256 nowTs) public pure {
        cf &= ~(uint256(1) << FeeRef.CF_MODE_SHIFT);
        (uint256 s,) = FeeRef.cfStep(cf, tick, z, nowTs);
        assert(s <= (cf >> FeeRef.CF_CAP_SHIFT) & 0xffffff);
    }

    function check_cfStep_leCfCap_reverse(uint256 cf, int24 tick, bool z, uint256 nowTs) public pure {
        cf |= uint256(1) << FeeRef.CF_MODE_SHIFT;
        (uint256 s,) = FeeRef.cfStep(cf, tick, z, nowTs);
        assert(s <= (cf >> FeeRef.CF_CAP_SHIFT) & 0xffffff);
    }

    function check_cfStep_preservesParameters(uint256 cf, int24 tick, bool z, uint256 nowTs) public pure {
        (, uint256 cfNew) = FeeRef.cfStep(cf, tick, z, nowTs);
        assert((cfNew ^ cf) >> 72 == 0);
        if (cfNew != cf) assert(cfNew & 0xffffffffff == nowTs & 0xffffffffff);
    }

    function check_cfStep_killedChargesNothing(uint256 cf, int24 tick, bool z, uint256 nowTs) public pure {
        cf = FeeRef.cfWithK(cf, 0);
        (uint256 s,) = FeeRef.cfStep(cf, tick, z, nowTs);
        assert(s == 0);
    }

    function check_decayFactor_leOne(uint256 cf, uint256 dt) public pure {
        if (((cf >> FeeRef.CF_DECAY1_SHIFT) & 0xffffffff) > 0xffffffff) return;
        assert(FeeRef.decayFactor(cf, dt) <= uint256(1) << 32);
    }

    function check_resolve_leCap(uint256 w, bool z, address sender, uint256 entry, uint256 cf, int24 tick, uint256 t)
        public
        pure
    {
        (uint256 fee,) = FeeRef.resolve(w, z, sender, entry, cf, tick, t);
        assert(fee <= w.cap());
        if (w.cap() <= ABSOLUTE_MAX_FEE) assert(fee <= ABSOLUTE_MAX_FEE);
    }

    function check_resolve_geFloorConfigured(
        uint256 w,
        bool z,
        address sender,
        uint256 entry,
        uint256 cf,
        int24 tick,
        uint256 t
    ) public pure {
        if (!_configured(w)) return;
        (uint256 fee,) = FeeRef.resolve(w, z, sender, entry, cf, tick, t);
        assert(fee >= w.floor());
    }

    function check_resolve_discountBand(
        uint256 w,
        bool z,
        address sender,
        uint256 entry,
        uint256 cf,
        int24 tick,
        uint256 t
    ) public pure {
        (uint256 f,) = FeeRef.resolve(w, z, sender, entry, cf, tick, t);
        (uint256 l,) = FeeRef.resolve(w, z, sender, 0, cf, tick, t);
        assert(f <= l);
        assert(2 * f >= l);
    }

    function check_resolve_leCap_pinnedBps(
        uint256 w,
        bool z,
        address sender,
        uint256 entry,
        uint256 cf,
        int24 tick,
        uint256 t
    ) public pure {
        entry = (entry & ~uint256(0xffff)) | 5_000;
        (uint256 fee,) = FeeRef.resolve(w, z, sender, entry, cf, tick, t);
        assert(fee <= w.cap());
    }

    function check_resolve_geFloorConfigured_pinnedBps(
        uint256 w,
        bool z,
        address sender,
        uint256 entry,
        uint256 cf,
        int24 tick,
        uint256 t
    ) public pure {
        if (!_configured(w)) return;
        entry = (entry & ~uint256(0xffff)) | 5_000;
        (uint256 fee,) = FeeRef.resolve(w, z, sender, entry, cf, tick, t);
        assert(fee >= w.floor());
    }

    function check_resolve_discountBand_pinnedBps(
        uint256 w,
        bool z,
        address sender,
        uint256 entry,
        uint256 cf,
        int24 tick,
        uint256 t
    ) public pure {
        entry = (entry & ~uint256(0xffff)) | 5_000;
        (uint256 f,) = FeeRef.resolve(w, z, sender, entry, cf, tick, t);
        (uint256 l,) = FeeRef.resolve(w, z, sender, 0, cf, tick, t);
        assert(f <= l);
        assert(2 * f >= l);
    }

    function check_resolve_cfOffIsInert(
        uint256 w,
        bool z,
        address sender,
        uint256 entry,
        uint256 cf,
        int24 tick,
        uint256 t
    ) public pure {
        w = w.withCfOn(false);
        (uint256 fee, uint256 cfNew) = FeeRef.resolve(w, z, sender, entry, cf, tick, t);
        assert(cfNew == cf);
        assert(fee <= FeeRef.keeperFee(w, z, t));
    }

    function _configured(uint256 w) internal pure returns (bool) {
        uint256 cap = w.cap();
        uint256 fl = w.floor();
        uint256 b0 = w.base0();
        uint256 b1 = w.base1();
        return cap >= 1 && cap <= ABSOLUTE_MAX_FEE && fl <= b0 && fl <= b1 && b0 <= cap && b1 <= cap;
    }
}
