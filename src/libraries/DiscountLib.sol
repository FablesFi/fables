// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

/// @title DiscountLib
/// @notice Whitelist-discount primitives: the per-account entry word, the Bloom pre-filter hash and the discount math.
/// @dev Entry word, one per (pool, account):
///        [0,16)   bps     u16  cut of the fee in bps; 0 = no entry
///        [16,40)  minFee  u24  floor of the discounted fee (pips)
///        [40,48)  dirs    u8   bit 0 = zeroForOne, bit 1 = oneForZero
///        [48,88)  expiry  u40  live while block.timestamp < expiry
///      The Bloom filter only pre-filters (the entry decides); a false positive costs one SLOAD.
library DiscountLib {
    struct Entry {
        uint16 bps;
        uint24 minFee;
        uint8 dirs;
        uint40 expiry;
    }

    uint256 internal constant MAX_DISCOUNT_BPS = 5_000;
    uint256 internal constant BPS_DENOMINATOR = 10_000;

    uint256 internal constant DIR_ZERO_FOR_ONE = 1;
    uint256 internal constant DIR_ONE_FOR_ZERO = 2;
    uint256 internal constant DIR_BOTH = 3;

    uint256 internal constant BPS_SHIFT = 0;
    uint256 internal constant MINFEE_SHIFT = 16;
    uint256 internal constant DIRS_SHIFT = 40;
    uint256 internal constant EXPIRY_SHIFT = 48;

    uint256 internal constant MASK8 = 0xff;
    uint256 internal constant MASK16 = 0xffff;
    uint256 internal constant MASK24 = 0xffffff;
    uint256 internal constant MASK40 = 0xffffffffff;

    uint256 internal constant HASH_MULTIPLIER = 0x9E3779B97F4A7C15F39CC0605CEDC8341082276BF3A27251F86C6A11D0C18E95;

    function pack(uint16 bps_, uint24 minFee_, uint8 dirs_, uint40 expiry_) internal pure returns (uint256) {
        return (uint256(bps_) << BPS_SHIFT) | (uint256(minFee_) << MINFEE_SHIFT) | (uint256(dirs_) << DIRS_SHIFT)
            | (uint256(expiry_) << EXPIRY_SHIFT);
    }

    // each getter masks to the field width before the cast
    // forge-lint: disable-start(unsafe-typecast)
    function unpack(uint256 e) internal pure returns (Entry memory x) {
        x.bps = uint16(bps(e));
        x.minFee = uint24(minFee(e));
        x.dirs = uint8(dirs(e));
        x.expiry = uint40(expiry(e));
    }

    function bps(uint256 e) internal pure returns (uint256) {
        return (e >> BPS_SHIFT) & MASK16;
    }

    function minFee(uint256 e) internal pure returns (uint256) {
        return (e >> MINFEE_SHIFT) & MASK24;
    }

    function dirs(uint256 e) internal pure returns (uint256) {
        return (e >> DIRS_SHIFT) & MASK8;
    }

    function expiry(uint256 e) internal pure returns (uint256) {
        return (e >> EXPIRY_SHIFT) & MASK40;
    }

    // forge-lint: disable-end(unsafe-typecast)

    function covers(uint256 e, bool zeroForOne) internal pure returns (bool) {
        return (dirs(e) >> (zeroForOne ? 0 : 1)) & 1 == 1;
    }

    function isLive(uint256 e, bool zeroForOne, uint256 nowTs) internal pure returns (bool) {
        return bps(e) != 0 && nowTs < expiry(e) && covers(e, zeroForOne);
    }

    function hash(address account, uint256 seed) internal pure returns (uint256 h) {
        unchecked {
            h = (uint256(uint160(account)) ^ (seed << 160)) * HASH_MULTIPLIER;
        }
    }

    /// @notice 64-bit Bloom mask, k = 3 (three 6-bit slices from the top of the hash).
    function mask64(address account, uint256 seed) internal pure returns (uint64) {
        uint256 h = hash(account, seed);
        // three bits below 64: fits uint64
        // forge-lint: disable-next-line(unsafe-typecast)
        return
            uint64((uint256(1) << (h >> 250)) | (uint256(1) << ((h >> 244) & 63)) | (uint256(1) << ((h >> 238) & 63)));
    }

    /// @notice 32-bit Bloom mask, k = 3 (three 5-bit slices from the top of the hash).
    function mask32(address account, uint256 seed) internal pure returns (uint32) {
        uint256 h = hash(account, seed);
        // three bits below 32: fits uint32
        // forge-lint: disable-next-line(unsafe-typecast)
        return
            uint32((uint256(1) << (h >> 251)) | (uint256(1) << ((h >> 246) & 31)) | (uint256(1) << ((h >> 241) & 31)));
    }

    function hit64(uint64 bloom, address account, uint256 seed) internal pure returns (bool) {
        uint64 m = mask64(account, seed);
        return bloom & m == m;
    }

    function hit32(uint32 bloom, address account, uint256 seed) internal pure returns (bool) {
        uint32 m = mask32(account, seed);
        return bloom & m == m;
    }

    /// @notice The discounted fee: min(fee, max(ceil(fee * (1 - min(bps, 50%))), floor, minFee)).
    /// @dev Rounds up (LP-favourable), never raises the fee, and clamps bps to 50% instead of reverting.
    function applyDiscount(uint256 fee, uint256 bps_, uint256 minFee_, uint256 floor_) internal pure returns (uint256) {
        if (bps_ > MAX_DISCOUNT_BPS) bps_ = MAX_DISCOUNT_BPS;
        uint256 d = (fee * (BPS_DENOMINATOR - bps_) + BPS_DENOMINATOR - 1) / BPS_DENOMINATOR;
        uint256 lo = floor_ > minFee_ ? floor_ : minFee_;
        if (d < lo) d = lo;
        return d < fee ? d : fee;
    }

    function applyEntry(uint256 fee, uint256 floor_, uint256 e, bool zeroForOne, uint256 nowTs)
        internal
        pure
        returns (uint256)
    {
        if (!isLive(e, zeroForOne, nowTs)) return fee;
        return applyDiscount(fee, bps(e), minFee(e), floor_);
    }
}
