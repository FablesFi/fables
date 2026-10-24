// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

/// @title PoolWordLib
/// @notice Codec for the pool word: one 256-bit word per pool, read on every swap. Fees in pips.
/// @dev Layout:
///        [0,24)     base0   u24   resting fee, zeroForOne
///        [24,48)    base1   u24   resting fee, oneForZero
///        [48,72)    poke0   u24   poked fee, zeroForOne; 0 = not poked
///        [72,96)    poke1   u24   poked fee, oneForZero; 0 = not poked
///        [96,136)   expiry  u40   pokes apply while block.timestamp < expiry
///        [136,160)  floor   u24   lowest fee
///        [160,184)  cap     u24   highest fee, <= ABSOLUTE_MAX_FEE; 0 = not configured
///        [184,248)  bloom   u64   whitelist pre-filter, k = 3
///        [248,255)  seed    u7    Bloom hash seed
///        [255]      cfOn    u1    continuation fee on
///      Each setter rewrites only its own field group.
library PoolWordLib {
    struct PoolWord {
        uint24 base0;
        uint24 base1;
        uint24 poke0;
        uint24 poke1;
        uint40 expiry;
        uint24 floor;
        uint24 cap;
        uint64 bloom;
        uint8 seed;
        bool cfOn;
    }

    uint256 internal constant BASE0_SHIFT = 0;
    uint256 internal constant BASE1_SHIFT = 24;
    uint256 internal constant POKE0_SHIFT = 48;
    uint256 internal constant POKE1_SHIFT = 72;
    uint256 internal constant EXPIRY_SHIFT = 96;
    uint256 internal constant FLOOR_SHIFT = 136;
    uint256 internal constant CAP_SHIFT = 160;
    uint256 internal constant BLOOM_SHIFT = 184;
    uint256 internal constant SEED_SHIFT = 248;
    uint256 internal constant CF_ON_SHIFT = 255;

    uint256 internal constant MASK7 = 0x7f;
    uint256 internal constant MASK24 = 0xffffff;
    uint256 internal constant MASK40 = 0xffffffffff;
    uint256 internal constant MASK64 = 0xffffffffffffffff;

    uint256 internal constant BASES_MASK = (MASK24 << BASE0_SHIFT) | (MASK24 << BASE1_SHIFT);
    uint256 internal constant POKES_MASK = (MASK24 << POKE0_SHIFT) | (MASK24 << POKE1_SHIFT) | (MASK40 << EXPIRY_SHIFT);
    uint256 internal constant BOUNDS_MASK = (MASK24 << FLOOR_SHIFT) | (MASK24 << CAP_SHIFT);
    uint256 internal constant BLOOM_MASK = MASK64 << BLOOM_SHIFT;
    uint256 internal constant SEED_MASK = MASK7 << SEED_SHIFT;
    uint256 internal constant CF_ON_MASK = uint256(1) << CF_ON_SHIFT;

    // each cast narrows a value already masked to the target width
    // forge-lint: disable-start(unsafe-typecast)

    function base0(uint256 w) internal pure returns (uint24) {
        return uint24((w >> BASE0_SHIFT) & MASK24);
    }

    function base1(uint256 w) internal pure returns (uint24) {
        return uint24((w >> BASE1_SHIFT) & MASK24);
    }

    function base(uint256 w, bool zeroForOne) internal pure returns (uint24) {
        return zeroForOne ? base0(w) : base1(w);
    }

    function poke0(uint256 w) internal pure returns (uint24) {
        return uint24((w >> POKE0_SHIFT) & MASK24);
    }

    function poke1(uint256 w) internal pure returns (uint24) {
        return uint24((w >> POKE1_SHIFT) & MASK24);
    }

    function poke(uint256 w, bool zeroForOne) internal pure returns (uint24) {
        return zeroForOne ? poke0(w) : poke1(w);
    }

    function expiry(uint256 w) internal pure returns (uint40) {
        return uint40((w >> EXPIRY_SHIFT) & MASK40);
    }

    function floor(uint256 w) internal pure returns (uint24) {
        return uint24((w >> FLOOR_SHIFT) & MASK24);
    }

    function cap(uint256 w) internal pure returns (uint24) {
        return uint24((w >> CAP_SHIFT) & MASK24);
    }

    function bloom(uint256 w) internal pure returns (uint64) {
        return uint64((w >> BLOOM_SHIFT) & MASK64);
    }

    function seed(uint256 w) internal pure returns (uint8) {
        return uint8((w >> SEED_SHIFT) & MASK7);
    }

    function cfOn(uint256 w) internal pure returns (bool) {
        return (w >> CF_ON_SHIFT) != 0;
    }

    // forge-lint: disable-end(unsafe-typecast)

    function withBases(uint256 w, uint24 base0_, uint24 base1_) internal pure returns (uint256) {
        return (w & ~BASES_MASK) | (uint256(base0_) << BASE0_SHIFT) | (uint256(base1_) << BASE1_SHIFT);
    }

    function withPokes(uint256 w, uint24 poke0_, uint24 poke1_, uint40 expiry_) internal pure returns (uint256) {
        return (w & ~POKES_MASK) | (uint256(poke0_) << POKE0_SHIFT) | (uint256(poke1_) << POKE1_SHIFT)
            | (uint256(expiry_) << EXPIRY_SHIFT);
    }

    function withPokesCleared(uint256 w) internal pure returns (uint256) {
        return w & ~POKES_MASK;
    }

    function withBounds(uint256 w, uint24 floor_, uint24 cap_) internal pure returns (uint256) {
        return (w & ~BOUNDS_MASK) | (uint256(floor_) << FLOOR_SHIFT) | (uint256(cap_) << CAP_SHIFT);
    }

    function withBloom(uint256 w, uint64 bloom_) internal pure returns (uint256) {
        return (w & ~BLOOM_MASK) | (uint256(bloom_) << BLOOM_SHIFT);
    }

    /// @dev Only the low 7 bits of `seed_` are stored; callers validate `seed_ <= 127` at write.
    function withSeed(uint256 w, uint8 seed_) internal pure returns (uint256) {
        return (w & ~SEED_MASK) | ((uint256(seed_) & MASK7) << SEED_SHIFT);
    }

    function withCfOn(uint256 w, bool on) internal pure returns (uint256) {
        return on ? (w | CF_ON_MASK) : (w & ~CF_ON_MASK);
    }

    function unpack(uint256 w) internal pure returns (PoolWord memory p) {
        p.base0 = base0(w);
        p.base1 = base1(w);
        p.poke0 = poke0(w);
        p.poke1 = poke1(w);
        p.expiry = expiry(w);
        p.floor = floor(w);
        p.cap = cap(w);
        p.bloom = bloom(w);
        p.seed = seed(w);
        p.cfOn = cfOn(w);
    }

    function pack(PoolWord memory p) internal pure returns (uint256 w) {
        w = (uint256(p.base0) << BASE0_SHIFT) | (uint256(p.base1) << BASE1_SHIFT) | (uint256(p.poke0) << POKE0_SHIFT)
            | (uint256(p.poke1) << POKE1_SHIFT) | (uint256(p.expiry) << EXPIRY_SHIFT)
            | (uint256(p.floor) << FLOOR_SHIFT) | (uint256(p.cap) << CAP_SHIFT) | (uint256(p.bloom) << BLOOM_SHIFT)
            | ((uint256(p.seed) & MASK7) << SEED_SHIFT);
        if (p.cfOn) w |= CF_ON_MASK;
    }
}
