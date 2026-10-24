// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolWordLib} from "../../../src/libraries/PoolWordLib.sol";

/// @notice Pool word codec: bit offsets against hand-built words, round trips, and setter field isolation.
contract PoolWordLibTest is Test {
    using PoolWordLib for uint256;

    function test_fieldGroupsPartitionTheWord() public pure {
        uint256[6] memory masks = [
            PoolWordLib.BASES_MASK,
            PoolWordLib.POKES_MASK,
            PoolWordLib.BOUNDS_MASK,
            PoolWordLib.BLOOM_MASK,
            PoolWordLib.SEED_MASK,
            PoolWordLib.CF_ON_MASK
        ];
        uint256 union;
        for (uint256 i = 0; i < 6; ++i) {
            for (uint256 j = i + 1; j < 6; ++j) {
                assertEq(masks[i] & masks[j], 0, "groups overlap");
            }
            union |= masks[i];
        }
        assertEq(union, type(uint256).max, "groups do not cover the word");
    }

    function test_offsetsMatchTheSpec() public pure {
        uint256 w = uint256(0x000001) | (uint256(0x000002) << 24) | (uint256(0x000003) << 48)
            | (uint256(0x000004) << 72) | (uint256(0x0000000005) << 96) | (uint256(0x000006) << 136)
            | (uint256(0x000007) << 160) | (uint256(0x0000000000000008) << 184) | (uint256(0x09) << 248)
            | (uint256(1) << 255);
        assertEq(w.base0(), 1);
        assertEq(w.base1(), 2);
        assertEq(w.poke0(), 3);
        assertEq(w.poke1(), 4);
        assertEq(w.expiry(), 5);
        assertEq(w.floor(), 6);
        assertEq(w.cap(), 7);
        assertEq(w.bloom(), 8);
        assertEq(w.seed(), 9);
        assertTrue(w.cfOn());
        assertEq(w.base(true), 1, "zeroForOne reads base0");
        assertEq(w.base(false), 2, "oneForZero reads base1");
        assertEq(w.poke(true), 3);
        assertEq(w.poke(false), 4);
    }

    function test_seedIsSevenBitsAndIgnoresCfOn() public pure {
        uint256 w = uint256(0x7f) << 248;
        assertEq(w.seed(), 127);
        assertFalse(w.cfOn());
        w = w.withCfOn(true);
        assertEq(w.seed(), 127, "cfOn does not leak into the seed");
        assertTrue(w.cfOn());
        w = uint256(0).withSeed(0xff);
        assertEq(w.seed(), 127, "the setter keeps only 7 bits");
        assertFalse(w.cfOn(), "the setter never flips cfOn");
    }

    function testFuzz_unpackPackRoundTrip(uint256 w) public pure {
        assertEq(PoolWordLib.pack(w.unpack()), w);
    }

    function testFuzz_packUnpackRoundTrip(PoolWordLib.PoolWord memory p) public pure {
        p.seed &= 0x7f;
        PoolWordLib.PoolWord memory q = PoolWordLib.pack(p).unpack();
        assertEq(q.base0, p.base0);
        assertEq(q.base1, p.base1);
        assertEq(q.poke0, p.poke0);
        assertEq(q.poke1, p.poke1);
        assertEq(q.expiry, p.expiry);
        assertEq(q.floor, p.floor);
        assertEq(q.cap, p.cap);
        assertEq(q.bloom, p.bloom);
        assertEq(q.seed, p.seed);
        assertEq(q.cfOn, p.cfOn);
    }

    function testFuzz_withBasesTouchesOnlyBases(uint256 w, uint24 b0, uint24 b1) public pure {
        uint256 n = w.withBases(b0, b1);
        assertEq(n.base0(), b0);
        assertEq(n.base1(), b1);
        assertEq(n & ~PoolWordLib.BASES_MASK, w & ~PoolWordLib.BASES_MASK, "other fields moved");
    }

    function testFuzz_withPokesTouchesOnlyPokes(uint256 w, uint24 p0, uint24 p1, uint40 e) public pure {
        uint256 n = w.withPokes(p0, p1, e);
        assertEq(n.poke0(), p0);
        assertEq(n.poke1(), p1);
        assertEq(n.expiry(), e);
        assertEq(n & ~PoolWordLib.POKES_MASK, w & ~PoolWordLib.POKES_MASK, "other fields moved");
    }

    function testFuzz_withPokesClearedZeroesOnlyPokes(uint256 w) public pure {
        uint256 n = w.withPokesCleared();
        assertEq(n.poke0(), 0);
        assertEq(n.poke1(), 0);
        assertEq(n.expiry(), 0);
        assertEq(n & ~PoolWordLib.POKES_MASK, w & ~PoolWordLib.POKES_MASK, "other fields moved");
    }

    function testFuzz_withBoundsTouchesOnlyBounds(uint256 w, uint24 f, uint24 c) public pure {
        uint256 n = w.withBounds(f, c);
        assertEq(n.floor(), f);
        assertEq(n.cap(), c);
        assertEq(n & ~PoolWordLib.BOUNDS_MASK, w & ~PoolWordLib.BOUNDS_MASK, "other fields moved");
    }

    function testFuzz_withBloomTouchesOnlyBloom(uint256 w, uint64 b) public pure {
        uint256 n = w.withBloom(b);
        assertEq(n.bloom(), b);
        assertEq(n & ~PoolWordLib.BLOOM_MASK, w & ~PoolWordLib.BLOOM_MASK, "other fields moved");
    }

    function testFuzz_withSeedTouchesOnlySeed(uint256 w, uint8 s) public pure {
        uint256 n = w.withSeed(s);
        assertEq(n.seed(), s & 0x7f);
        assertEq(n & ~PoolWordLib.SEED_MASK, w & ~PoolWordLib.SEED_MASK, "other fields moved");
    }

    function testFuzz_withCfOnTouchesOnlyBit255(uint256 w, bool on) public pure {
        uint256 n = w.withCfOn(on);
        assertEq(n.cfOn(), on);
        assertEq(n & ~PoolWordLib.CF_ON_MASK, w & ~PoolWordLib.CF_ON_MASK, "other fields moved");
    }
}
