// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {DiscountLib} from "../../../src/libraries/DiscountLib.sol";

/// @notice DiscountLib: entry codec, discount arithmetic (rounds up, bounded) and the Bloom pre-filter.
contract DiscountLibTest is Test {
    function test_entryOffsetsMatchTheSpec() public pure {
        uint256 e = uint256(0x0001) | (uint256(0x000002) << 16) | (uint256(0x03) << 40) | (uint256(0x0000000004) << 48);
        assertEq(DiscountLib.bps(e), 1);
        assertEq(DiscountLib.minFee(e), 2);
        assertEq(DiscountLib.dirs(e), 3);
        assertEq(DiscountLib.expiry(e), 4);
        assertEq(DiscountLib.pack(1, 2, 3, 4), e);
    }

    function testFuzz_entryPackUnpackRoundTrip(uint16 bps, uint24 minFee, uint8 dirs, uint40 expiry) public pure {
        uint256 e = DiscountLib.pack(bps, minFee, dirs, expiry);
        assertLt(e, uint256(1) << 88, "spare bits must stay zero");
        DiscountLib.Entry memory x = DiscountLib.unpack(e);
        assertEq(x.bps, bps);
        assertEq(x.minFee, minFee);
        assertEq(x.dirs, dirs);
        assertEq(x.expiry, expiry);
    }

    function test_coversReadsTheDirectionBits() public pure {
        assertTrue(DiscountLib.covers(DiscountLib.pack(1, 0, 1, 0), true));
        assertFalse(DiscountLib.covers(DiscountLib.pack(1, 0, 1, 0), false));
        assertFalse(DiscountLib.covers(DiscountLib.pack(1, 0, 2, 0), true));
        assertTrue(DiscountLib.covers(DiscountLib.pack(1, 0, 2, 0), false));
        assertTrue(DiscountLib.covers(DiscountLib.pack(1, 0, 3, 0), true));
        assertTrue(DiscountLib.covers(DiscountLib.pack(1, 0, 3, 0), false));
    }

    function test_isLiveNeedsBpsExpiryAndDirection() public pure {
        uint256 e = DiscountLib.pack(1000, 0, 1, 100);
        assertTrue(DiscountLib.isLive(e, true, 99));
        assertFalse(DiscountLib.isLive(e, true, 100), "expiry is exclusive");
        assertFalse(DiscountLib.isLive(e, false, 99), "direction not covered");
        assertFalse(DiscountLib.isLive(DiscountLib.pack(0, 0, 3, 100), true, 99), "bps 0 = no entry");
        assertFalse(DiscountLib.isLive(0, true, 0), "empty word");
    }

    function test_applyRoundsUp() public pure {
        assertEq(DiscountLib.applyDiscount(1001, 5000, 0, 0), 501, "ceil(500.5)");
        assertEq(DiscountLib.applyDiscount(1, 5000, 0, 0), 1, "ceil(0.5)");
        assertEq(DiscountLib.applyDiscount(3, 3333, 0, 0), 3, "ceil(2.0001)");
        assertEq(DiscountLib.applyDiscount(100, 1, 0, 0), 100, "ceil(99.99)");
        assertEq(DiscountLib.applyDiscount(10_000, 1, 0, 0), 9_999);
        assertEq(DiscountLib.applyDiscount(1000, 2500, 0, 0), 750, "exact quarter off");
        assertEq(DiscountLib.applyDiscount(0, 5000, 0, 0), 0, "0 stays 0");
    }

    function test_applyClampsBpsAtFiftyPercent() public pure {
        assertEq(DiscountLib.applyDiscount(1000, 10_000, 0, 0), 500);
        assertEq(DiscountLib.applyDiscount(1000, 65_535, 0, 0), 500);
        assertEq(DiscountLib.applyDiscount(1000, 5_000, 0, 0), 500);
    }

    function test_applyRespectsFloorAndMinFee() public pure {
        assertEq(DiscountLib.applyDiscount(1000, 5000, 700, 0), 700, "minFee binds");
        assertEq(DiscountLib.applyDiscount(1000, 5000, 0, 800), 800, "floor binds");
        assertEq(DiscountLib.applyDiscount(1000, 5000, 700, 800), 800, "the higher of the two binds");
        assertEq(DiscountLib.applyDiscount(1000, 5000, 2000, 0), 1000, "minFee above the fee: no discount, no raise");
        assertEq(DiscountLib.applyDiscount(1000, 5000, 0, 2000), 1000, "floor above the fee: never raises");
    }

    function testFuzz_applyStaysInsideTheDiscountBand(uint24 fee, uint16 bps, uint24 minFee, uint24 floor_)
        public
        pure
    {
        uint256 f = DiscountLib.applyDiscount(fee, bps, minFee, floor_);
        assertLe(f, fee, "never raises");
        assertGe(f, (uint256(fee) + 1) / 2, "never more than 50% off");
        uint256 lo = floor_ > minFee ? floor_ : minFee;
        assertGe(f, lo < fee ? lo : fee, "respects max(floor, minFee)");
        if (bps == 0) assertEq(f, fee, "bps 0 is the identity");
    }

    function test_applyEntryIsIdentityUnlessLive() public pure {
        uint256 e = DiscountLib.pack(5000, 0, 1, 100);
        assertEq(DiscountLib.applyEntry(1000, 0, e, true, 50), 500);
        assertEq(DiscountLib.applyEntry(1000, 0, e, false, 50), 1000, "direction not covered");
        assertEq(DiscountLib.applyEntry(1000, 0, e, true, 100), 1000, "expired");
        assertEq(DiscountLib.applyEntry(1000, 600, e, true, 50), 600, "floor passes through");
        assertEq(DiscountLib.applyEntry(1000, 0, 0, true, 50), 1000, "no entry");
    }

    function testFuzz_mask64MatchesTheSpecFormula(address a, uint8 seed) public pure {
        seed &= 0x7f;
        uint256 h;
        unchecked {
            h = (uint256(uint160(a)) ^ (uint256(seed) << 160))
                * 0x9E3779B97F4A7C15F39CC0605CEDC8341082276BF3A27251F86C6A11D0C18E95;
        }
        uint64 expected =
            uint64((uint256(1) << (h >> 250)) | (uint256(1) << ((h >> 244) & 63)) | (uint256(1) << ((h >> 238) & 63)));
        assertEq(DiscountLib.mask64(a, seed), expected);
        assertEq(DiscountLib.hash(a, seed), h);
    }

    function testFuzz_masksHaveOneToThreeBits(address a, uint8 seed) public pure {
        uint256 c64 = _popcount(DiscountLib.mask64(a, seed));
        assertGe(c64, 1);
        assertLe(c64, 3);
        uint256 c32 = _popcount(DiscountLib.mask32(a, seed));
        assertGe(c32, 1);
        assertLe(c32, 3);
    }

    function testFuzz_hitIsCompleteForMembers(address[8] memory members, uint8 seed) public pure {
        uint64 b64;
        uint32 b32;
        for (uint256 i = 0; i < 8; ++i) {
            b64 |= DiscountLib.mask64(members[i], seed);
            b32 |= DiscountLib.mask32(members[i], seed);
        }
        for (uint256 i = 0; i < 8; ++i) {
            assertTrue(DiscountLib.hit64(b64, members[i], seed), "member missed (64)");
            assertTrue(DiscountLib.hit32(b32, members[i], seed), "member missed (32)");
        }
    }

    function test_bloom64FalsePositiveSanity() public pure {
        uint64 b;
        for (uint256 i = 0; i < 8; ++i) {
            b |= DiscountLib.mask64(_addr("member", i), 17);
        }
        uint256 fp;
        uint256 probes = 4096;
        for (uint256 i = 0; i < probes; ++i) {
            if (DiscountLib.hit64(b, _addr("probe", i), 17)) ++fp;
        }
        assertLt(fp * 1000, probes * 80, "64-bit false-positive rate above 8%");
        assertGt(fp, 0, "a 2.9% rate over 4096 probes never showing is a hash that does not mix");
    }

    function test_bloom32FalsePositiveSanity() public pure {
        uint32 b4;
        uint32 b8;
        for (uint256 i = 0; i < 8; ++i) {
            if (i < 4) b4 |= DiscountLib.mask32(_addr("member", i), 5);
            b8 |= DiscountLib.mask32(_addr("member", i), 5);
        }
        uint256 fp4;
        uint256 fp8;
        uint256 probes = 4096;
        for (uint256 i = 0; i < probes; ++i) {
            address p = _addr("probe", i);
            if (DiscountLib.hit32(b4, p, 5)) ++fp4;
            if (DiscountLib.hit32(b8, p, 5)) ++fp8;
        }
        assertLt(fp4 * 1000, probes * 100, "32-bit / 4 members false-positive rate above 10%");
        assertLt(fp8 * 1000, probes * 300, "32-bit / 8 members false-positive rate above 30%");
    }

    function test_aSeedSeparatesACollidingProbe() public pure {
        address[8] memory members;
        for (uint256 i = 0; i < 8; ++i) {
            members[i] = _addr("desk", i);
        }
        address probe;
        uint64 b0 = _filter64(members, 0);
        for (uint256 i = 0;; ++i) {
            probe = _addr("router", i);
            if (DiscountLib.hit64(b0, probe, 0)) break;
        }
        bool separated;
        for (uint256 s = 0; s < 128; ++s) {
            if (!DiscountLib.hit64(_filter64(members, s), probe, s)) {
                separated = true;
                break;
            }
        }
        assertTrue(separated, "no seed separates the colliding probe");
    }

    function testFuzz_seedChangesTheMask(address a) public pure {
        uint64 first = DiscountLib.mask64(a, 0);
        bool differs;
        for (uint256 s = 1; s < 128 && !differs; ++s) {
            differs = DiscountLib.mask64(a, s) != first;
        }
        assertTrue(differs, "the seed has no effect on the mask");
    }

    function _filter64(address[8] memory members, uint256 seed) internal pure returns (uint64 b) {
        for (uint256 i = 0; i < 8; ++i) {
            b |= DiscountLib.mask64(members[i], seed);
        }
    }

    function _addr(string memory tag, uint256 i) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(tag, i)))));
    }

    function _popcount(uint256 x) internal pure returns (uint256 c) {
        while (x != 0) {
            x &= x - 1;
            ++c;
        }
    }
}
