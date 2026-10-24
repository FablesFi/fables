// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {PoolWordLib} from "./PoolWordLib.sol";
import {DiscountLib} from "./DiscountLib.sol";

/// @title FeeRef
/// @notice Reference fee resolution in plain Solidity; the assembly swap entry must match `resolve` bit for bit.
/// @dev Pure; fee resolution never reverts and resolves any input words to a fee <= cap. side = zeroForOne ? 0 : 1:
///        fee = base[side]
///        if now < expiry and poke[side] != 0: fee = max(poke[side], floor, min(base[side], cap) / 2)
///        fee = min(fee, cap)
///        if Bloom hit: fee = DiscountLib.applyEntry(fee, ...)
///        if cfOn: fee = min(fee + cfStep(...).s, cap)
///      CF word (one per pool):
///        [0,40)     tLast   u40    last anchor update (unix s)
///        [40,72)    anchor  int32  anchor tick, 1/256 tick
///        [72,104)   decay1  u32    floor(exp(-1/tau) * 2^32), per second
///        [104,120)  k       u16    Q8 slope (256 = 1.0): surcharge pips = k * excess ticks * 100
///        [120,144)  cfCap   u24    max surcharge (pips)
///        [144,160)  band    u16    dead band, 1/16 tick
///        [160,168)  maxAge  u8     dt >= maxAge snaps the anchor to the tick (s)
///        [168,176)  period  u8     min seconds between anchor updates
///        [176,192)  tau     u16    e-folding time (s), informational
///        [192]      mode    u1     0 = continuation (charge moves away from the anchor), 1 = reverse (moves back)
library FeeRef {
    using PoolWordLib for uint256;

    struct CFWord {
        uint40 tLast;
        int32 anchor;
        uint32 decay1;
        uint16 kQ8;
        uint24 cfCap;
        uint16 band16;
        uint8 maxAge;
        uint8 period;
        uint16 tau;
        uint8 mode;
    }

    uint256 internal constant CF_TLAST_SHIFT = 0;
    uint256 internal constant CF_ANCHOR_SHIFT = 40;
    uint256 internal constant CF_DECAY1_SHIFT = 72;
    uint256 internal constant CF_K_SHIFT = 104;
    uint256 internal constant CF_CAP_SHIFT = 120;
    uint256 internal constant CF_BAND_SHIFT = 144;
    uint256 internal constant CF_MAXAGE_SHIFT = 160;
    uint256 internal constant CF_PERIOD_SHIFT = 168;
    uint256 internal constant CF_TAU_SHIFT = 176;
    uint256 internal constant CF_MODE_SHIFT = 192;

    uint8 internal constant CF_MODE_CONTINUATION = 0;
    uint8 internal constant CF_MODE_REVERSE = 1;

    uint256 internal constant MASK8 = 0xff;
    uint256 internal constant MASK16 = 0xffff;
    uint256 internal constant MASK24 = 0xffffff;
    uint256 internal constant MASK32 = 0xffffffff;
    uint256 internal constant MASK40 = 0xffffffffff;
    /// @dev tLast + anchor: the bits an anchor update rewrites.
    uint256 internal constant CF_STATE_MASK = (uint256(1) << CF_DECAY1_SHIFT) - 1;
    uint256 internal constant CF_K_MASK = MASK16 << CF_K_SHIFT;

    uint256 internal constant Q32 = uint256(1) << 32;
    /// @dev 1 tick ~ 1 bp = 100 pips.
    uint256 internal constant PIPS_PER_TICK = 100;

    function keeperFee(uint256 w, bool zeroForOne, uint256 nowTs) internal pure returns (uint256 fee) {
        uint256 pre = w.base(zeroForOne);
        uint256 cap = w.cap();
        fee = pre;
        if (nowTs < w.expiry()) {
            uint256 poked = w.poke(zeroForOne);
            if (poked != 0) {
                uint256 lo = (pre > cap ? cap : pre) >> 1;
                uint256 floor_ = w.floor();
                if (lo < floor_) lo = floor_;
                fee = poked > lo ? poked : lo;
            }
        }
        if (fee > cap) fee = cap;
    }

    function bloomHit(address sender, uint256 seed, uint64 bloom) internal pure returns (bool) {
        return DiscountLib.hit64(bloom, sender, seed);
    }

    function discounted(uint256 fee, uint256 w, uint256 entry, bool zeroForOne, uint256 nowTs)
        internal
        pure
        returns (uint256)
    {
        return DiscountLib.applyEntry(fee, w.floor(), entry, zeroForOne, nowTs);
    }

    /// @notice One CF step: the surcharge (pips, <= cfCap) and the CF word after any due anchor update.
    /// @dev If dt = now - tLast >= period: A = T + (A - T) * decay1^dt / 2^32 with T = tick * 256, tLast = now
    ///      (truncating toward zero, so A reaches T from either side). m = zeroForOne ? A - T : T - A, negated in
    ///      mode 1; x = m - band * 16; s = min((k * x * 100) >> 16, cfCap) when x > 0. Unchecked bounds:
    ///      |A - T| < 2^32, f <= 2^32, |x| < 2^33, k * x * 100 < 2^56; dt is 0 if tLast > now.
    // casts reinterpret masked fields (anchor sign extension intended) or follow a sign check
    // forge-lint: disable-start(unsafe-typecast)
    function cfStep(uint256 cf, int24 tick, bool zeroForOne, uint256 nowTs)
        internal
        pure
        returns (uint256 s, uint256 cfNew)
    {
        unchecked {
            cfNew = cf;
            int256 a = int256(int32(uint32(cf >> CF_ANCHOR_SHIFT)));
            int256 t = int256(tick) * 256;
            {
                uint256 dt = nowTs > (cf & MASK40) ? nowTs - (cf & MASK40) : 0;
                if (dt >= ((cf >> CF_PERIOD_SHIFT) & MASK8)) {
                    a = t + ((a - t) * int256(decayFactor(cf, dt))) / int256(Q32);
                    cfNew = (cf & ~CF_STATE_MASK) | (nowTs & MASK40) | ((uint256(a) & MASK32) << CF_ANCHOR_SHIFT);
                }
            }
            int256 x = zeroForOne ? a - t : t - a;
            if ((cf >> CF_MODE_SHIFT) & 1 != 0) x = -x;
            x -= int256(((cf >> CF_BAND_SHIFT) & MASK16) << 4);
            if (x > 0) {
                s = (((cf >> CF_K_SHIFT) & MASK16) * uint256(x) * PIPS_PER_TICK) >> 16;
                uint256 cfCap = (cf >> CF_CAP_SHIFT) & MASK24;
                if (s > cfCap) s = cfCap;
            }
        }
    }

    /// @notice decay1^dt in Q32 (square-and-multiply), or 0 when dt >= maxAge (full reset). f <= 2^32.
    function decayFactor(uint256 cf, uint256 dt) internal pure returns (uint256 f) {
        unchecked {
            if (dt >= ((cf >> CF_MAXAGE_SHIFT) & MASK8)) return 0;
            f = Q32;
            uint256 b = (cf >> CF_DECAY1_SHIFT) & MASK32;
            while (dt != 0) {
                if (dt & 1 != 0) f = (f * b) >> 32;
                dt >>= 1;
                b = (b * b) >> 32;
            }
        }
    }

    // forge-lint: disable-end(unsafe-typecast)

    /// @notice Full resolution for one swap: the fee and the CF word to store (== `cf` when no update is due).
    function resolve(uint256 w, bool zeroForOne, address sender, uint256 entry, uint256 cf, int24 tick, uint256 nowTs)
        internal
        pure
        returns (uint256 fee, uint256 cfNew)
    {
        fee = keeperFee(w, zeroForOne, nowTs);
        uint64 bloom = w.bloom();
        if (bloom != 0 && bloomHit(sender, w.seed(), bloom)) {
            fee = discounted(fee, w, entry, zeroForOne, nowTs);
        }
        cfNew = cf;
        if (w.cfOn()) {
            uint256 s;
            (s, cfNew) = cfStep(cf, tick, zeroForOne, nowTs);
            fee += s;
            uint256 cap = w.cap();
            if (fee > cap) fee = cap;
        }
    }

    /// @notice floor(exp(-1/tau) * 2^32): the anchor's per-second decay factor (admin path only).
    /// @dev Alternating Taylor series in Q96, 20 terms; exact for every legal tau.
    function decay1Q32(uint256 tau) internal pure returns (uint32) {
        uint256 x = (uint256(1) << 96) / tau;
        uint256 term = uint256(1) << 96;
        uint256 sum = term;
        for (uint256 n = 1; n <= 20; ++n) {
            term = ((term * x) >> 96) / n;
            if (term == 0) break;
            if (n & 1 == 1) sum -= term;
            else sum += term;
        }
        uint256 d = sum >> 64;
        // forge-lint: disable-next-line(unsafe-typecast)
        return d > MASK32 ? uint32(MASK32) : uint32(d);
    }

    // codec casts mask each field first; anchor casts are two's-complement reinterpretations
    // forge-lint: disable-start(unsafe-typecast)

    function packCF(CFWord memory c) internal pure returns (uint256 cf) {
        cf = (uint256(c.tLast) << CF_TLAST_SHIFT) | (uint256(uint32(c.anchor)) << CF_ANCHOR_SHIFT)
            | (uint256(c.decay1) << CF_DECAY1_SHIFT) | (uint256(c.kQ8) << CF_K_SHIFT)
            | (uint256(c.cfCap) << CF_CAP_SHIFT) | (uint256(c.band16) << CF_BAND_SHIFT)
            | (uint256(c.maxAge) << CF_MAXAGE_SHIFT) | (uint256(c.period) << CF_PERIOD_SHIFT)
            | (uint256(c.tau) << CF_TAU_SHIFT) | (uint256(c.mode & 1) << CF_MODE_SHIFT);
    }

    function unpackCF(uint256 cf) internal pure returns (CFWord memory c) {
        c.tLast = uint40((cf >> CF_TLAST_SHIFT) & MASK40);
        c.anchor = int32(uint32((cf >> CF_ANCHOR_SHIFT) & MASK32));
        c.decay1 = uint32((cf >> CF_DECAY1_SHIFT) & MASK32);
        c.kQ8 = uint16((cf >> CF_K_SHIFT) & MASK16);
        c.cfCap = uint24((cf >> CF_CAP_SHIFT) & MASK24);
        c.band16 = uint16((cf >> CF_BAND_SHIFT) & MASK16);
        c.maxAge = uint8((cf >> CF_MAXAGE_SHIFT) & MASK8);
        c.period = uint8((cf >> CF_PERIOD_SHIFT) & MASK8);
        c.tau = uint16((cf >> CF_TAU_SHIFT) & MASK16);
        c.mode = uint8((cf >> CF_MODE_SHIFT) & 1);
    }

    function cfK(uint256 cf) internal pure returns (uint256) {
        return (cf >> CF_K_SHIFT) & MASK16;
    }

    function cfWithK(uint256 cf, uint16 kQ8) internal pure returns (uint256) {
        return (cf & ~CF_K_MASK) | (uint256(kQ8) << CF_K_SHIFT);
    }

    function cfRearm(uint256 cf, uint256 nowTs, int24 tick) internal pure returns (uint256) {
        uint256 anchor = uint256(int256(tick) * 256) & MASK32;
        return (cf & ~CF_STATE_MASK) | (nowTs & MASK40) | (anchor << CF_ANCHOR_SHIFT);
    }
    // forge-lint: disable-end(unsafe-typecast)
}
