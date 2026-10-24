// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {FeeRef} from "../../../src/libraries/FeeRef.sol";
import {PoolWordLib} from "../../../src/libraries/PoolWordLib.sol";
import {DiscountLib} from "../../../src/libraries/DiscountLib.sol";

/// @notice FeeRef (the Solidity fee twin): poke fee band and 50% rule, discount step, continuation fee in both modes,
///         and the decay factor.
contract FeeRefTest is Test {
    using PoolWordLib for uint256;

    uint256 constant ABSOLUTE_MAX_FEE = 100_000;
    uint256 constant NOW = 1_800_000_000;

    struct WordIn {
        uint256 raw;
        uint24 floor_;
        uint24 cap;
        uint24 base0;
        uint24 base1;
    }

    struct CFIn {
        uint16 k;
        uint24 cfCap;
        uint16 band16;
        uint16 tau;
        uint8 period;
        uint40 tLast;
        int32 anchor;
    }

    function _word(uint24 base0, uint24 base1, uint24 poke0, uint24 poke1, uint40 expiry, uint24 floor_, uint24 cap)
        internal
        pure
        returns (uint256)
    {
        return uint256(0).withBases(base0, base1).withPokes(poke0, poke1, expiry).withBounds(floor_, cap);
    }

    function _configuredWord(WordIn memory i) internal pure returns (uint256) {
        uint24 cap = uint24(bound(i.cap, 1, ABSOLUTE_MAX_FEE));
        uint24 floor_ = uint24(bound(i.floor_, 0, cap));
        uint24 base0 = uint24(bound(i.base0, floor_, cap));
        uint24 base1 = uint24(bound(i.base1, floor_, cap));
        return i.raw.withBases(base0, base1).withBounds(floor_, cap);
    }

    function _cf(
        uint8 mode,
        uint16 k,
        uint24 cfCap,
        uint16 band16,
        uint16 tau,
        uint8 period,
        uint40 tLast,
        int32 anchor
    ) internal pure returns (uint256) {
        uint256 maxAge = 5 * uint256(tau);
        if (maxAge > 255) maxAge = 255;
        return FeeRef.packCF(
            FeeRef.CFWord({
                tLast: tLast,
                anchor: anchor,
                decay1: FeeRef.decay1Q32(tau),
                kQ8: k,
                cfCap: cfCap,
                band16: band16,
                maxAge: uint8(maxAge),
                period: period,
                tau: tau,
                mode: mode
            })
        );
    }

    function _boundedCF(uint8 mode, CFIn memory p) internal pure returns (uint256) {
        return _cf(
            mode & 1,
            uint16(bound(p.k, 1, 256)),
            uint24(bound(p.cfCap, 0, 2_500)),
            uint16(bound(p.band16, 0, 800)),
            uint16(bound(p.tau, 5, 300)),
            uint8(bound(p.period, 1, 60)),
            p.tLast,
            p.anchor
        );
    }

    function test_keeperFee_baseWhenUnpoked() public pure {
        uint256 w = _word(700, 900, 0, 0, 0, 300, 8000);
        assertEq(FeeRef.keeperFee(w, true, NOW), 700);
        assertEq(FeeRef.keeperFee(w, false, NOW), 900);
    }

    function test_keeperFee_livePokeReplacesTheBase() public pure {
        uint256 w = _word(700, 900, 2000, 3000, uint40(NOW + 1), 300, 8000);
        assertEq(FeeRef.keeperFee(w, true, NOW), 2000);
        assertEq(FeeRef.keeperFee(w, false, NOW), 3000);
    }

    function test_keeperFee_fiftyPercentCutRule() public pure {
        uint256 w = _word(4000, 4000, 300, 300, uint40(NOW + 1), 300, 8000);
        assertEq(FeeRef.keeperFee(w, true, NOW), 2000);
        w = _word(20_000, 20_000, 300, 300, uint40(NOW + 1), 300, 8000);
        assertEq(FeeRef.keeperFee(w, true, NOW), 4000);
        w = _word(4000, 4000, 1, 1, uint40(NOW + 1), 2500, 8000);
        assertEq(FeeRef.keeperFee(w, true, NOW), 2500);
    }

    function test_keeperFee_sentinelSideKeepsItsBase() public pure {
        uint256 w = _word(700, 900, 0, 3000, uint40(NOW + 1), 300, 8000);
        assertEq(FeeRef.keeperFee(w, true, NOW), 700, "zero side = not poked");
        assertEq(FeeRef.keeperFee(w, false, NOW), 3000);
    }

    function test_keeperFee_expiryIsExclusive() public pure {
        uint256 w = _word(700, 900, 2000, 3000, uint40(NOW), 300, 8000);
        assertEq(FeeRef.keeperFee(w, true, NOW), 700, "now == expiry: the poke is over");
        assertEq(FeeRef.keeperFee(w, true, NOW - 1), 2000);
    }

    function test_keeperFee_capClampsEverything() public pure {
        uint256 w = _word(5000, 5000, 7000, 7000, uint40(NOW + 1), 300, 4000);
        assertEq(FeeRef.keeperFee(w, true, NOW), 4000);
        w = _word(5000, 5000, 0, 0, 0, 300, 4000);
        assertEq(FeeRef.keeperFee(w, true, NOW), 4000);
    }

    function testFuzz_keeperFee_staysInsideTheBand(WordIn memory i, bool zeroForOne, uint256 nowTs) public pure {
        uint256 w = _configuredWord(i);
        uint256 fee = FeeRef.keeperFee(w, zeroForOne, nowTs);
        assertGe(fee, w.floor());
        assertLe(fee, w.cap());
        assertLe(fee, ABSOLUTE_MAX_FEE);
    }

    function testFuzz_keeperFee_livePokeHonoursTheFiftyPercentFloor(
        WordIn memory i,
        uint24 poke,
        bool zeroForOne,
        uint40 expiry
    ) public pure {
        poke = uint24(bound(poke, 1, type(uint24).max));
        expiry = uint40(bound(expiry, 1, type(uint40).max));
        uint256 w = _configuredWord(i).withPokes(poke, poke, expiry);
        uint256 nowTs = expiry - 1;
        uint256 fee = FeeRef.keeperFee(w, zeroForOne, nowTs);
        uint256 base = w.base(zeroForOne);
        uint256 half = (base > w.cap() ? w.cap() : base) / 2;
        uint256 lo = half > w.floor() ? half : w.floor();
        assertGe(fee, lo, "poke undercut the 50% floor");
        assertLe(fee, w.cap());
        if (poke >= lo && poke <= w.cap()) assertEq(fee, poke);
    }

    function testFuzz_keeperFee_neverReverts(uint256 w, bool zeroForOne, uint256 nowTs) public pure {
        FeeRef.keeperFee(w, zeroForOne, nowTs);
    }

    function test_resolve_discountNeedsBloomHitAndLiveEntry() public pure {
        address desk = address(0xDE5C);
        uint8 seed = 11;
        uint256 w = _word(1000, 1000, 0, 0, 0, 100, 8000).withSeed(seed);
        uint256 entry = DiscountLib.pack(2000, 0, 3, uint40(NOW + 1));
        (uint256 fee,) = FeeRef.resolve(w, true, desk, entry, 0, 0, NOW);
        assertEq(fee, 1000);
        w = w.withBloom(DiscountLib.mask64(desk, seed));
        (fee,) = FeeRef.resolve(w, true, desk, entry, 0, 0, NOW);
        assertEq(fee, 800);
        (fee,) = FeeRef.resolve(w, false, desk, DiscountLib.pack(2000, 0, 1, uint40(NOW + 1)), 0, 0, NOW);
        assertEq(fee, 1000);
        (fee,) = FeeRef.resolve(w, true, desk, entry, 0, 0, NOW + 1);
        assertEq(fee, 1000);
        (fee,) = FeeRef.resolve(w, true, desk, DiscountLib.pack(5000, 900, 3, uint40(NOW + 1)), 0, 0, NOW);
        assertEq(fee, 900);
        w = w.withBounds(950, 8000);
        (fee,) = FeeRef.resolve(w, true, desk, DiscountLib.pack(5000, 0, 3, uint40(NOW + 1)), 0, 0, NOW);
        assertEq(fee, 950);
    }

    function test_resolve_senderZeroWithEmptyEntryIsNeverDiscounted() public pure {
        uint256 w = _word(1000, 1000, 0, 0, 0, 0, 8000).withBloom(DiscountLib.mask64(address(0), 0));
        (uint256 fee,) = FeeRef.resolve(w, true, address(0), 0, 0, 0, NOW);
        assertEq(fee, 1000);
    }

    function testFuzz_resolve_listedSenderInsideTheDiscountBand(
        WordIn memory i,
        address desk,
        uint16 bps,
        uint24 minFee,
        uint8 dirs,
        bool zeroForOne
    ) public pure {
        uint256 w = _configuredWord(i).withCfOn(false);
        w = w.withBloom(w.bloom() | DiscountLib.mask64(desk, w.seed()));
        uint256 L = FeeRef.keeperFee(w, zeroForOne, NOW);
        uint256 entry = DiscountLib.pack(bps, minFee, dirs, uint40(NOW + 1));
        (uint256 f,) = FeeRef.resolve(w, zeroForOne, desk, entry, 0, 0, NOW);
        assertLe(f, L, "discount raised the fee");
        assertGe(f, (L + 1) / 2, "more than 50% off");
        uint256 lo = w.floor() > minFee ? w.floor() : minFee;
        assertGe(f, lo < L ? lo : L);
        assertGe(f, w.floor(), "under discount");
    }

    function test_cfStep_oneTickOfContinuationIsOneBasisPoint() public pure {
        uint256 cf = _cf(0, 256, 2500, 0, 60, 15, uint40(NOW), 256);
        (uint256 s,) = FeeRef.cfStep(cf, 0, true, NOW);
        assertEq(s, 100);
        (s,) = FeeRef.cfStep(cf, 0, false, NOW);
        assertEq(s, 0);
        cf = _cf(0, 128, 2500, 0, 60, 15, uint40(NOW), 512);
        (s,) = FeeRef.cfStep(cf, 0, true, NOW);
        assertEq(s, 100);
    }

    function test_cfStep_bandIsADeadZone() public pure {
        uint256 cf = _cf(0, 256, 2500, 80, 60, 15, uint40(NOW), 5 * 256);
        (uint256 s,) = FeeRef.cfStep(cf, 0, true, NOW);
        assertEq(s, 0, "m == band pays nothing");
        cf = _cf(0, 256, 2500, 80, 60, 15, uint40(NOW), 6 * 256);
        (s,) = FeeRef.cfStep(cf, 0, true, NOW);
        assertEq(s, 100, "one tick past the band pays 1 bp");
    }

    function test_cfStep_capBindsTheSurcharge() public pure {
        uint256 cf = _cf(0, 256, 250, 0, 60, 15, uint40(NOW), 100 * 256);
        (uint256 s,) = FeeRef.cfStep(cf, 0, true, NOW);
        assertEq(s, 250);
    }

    function test_cfStep_reverseModeTaxesTheOtherSide() public pure {
        uint256 cont = _cf(0, 256, 2500, 0, 60, 15, uint40(NOW), 256);
        uint256 rev = _cf(1, 256, 2500, 0, 60, 15, uint40(NOW), 256);
        (uint256 s0,) = FeeRef.cfStep(cont, 0, true, NOW);
        (uint256 s1,) = FeeRef.cfStep(rev, 0, false, NOW);
        assertEq(s0, 100);
        assertEq(s1, 100);
        (s1,) = FeeRef.cfStep(rev, 0, true, NOW);
        assertEq(s1, 0);
    }

    function testFuzz_cfStep_reverseMirrorsContinuation(CFIn memory p, int24 tick, bool zeroForOne, uint40 nowTs)
        public
        pure
    {
        tick = int24(bound(tick, -887_272, 887_272));
        uint256 cont = _boundedCF(0, p);
        uint256 rev = _boundedCF(1, p);
        (uint256 sC, uint256 nC) = FeeRef.cfStep(cont, tick, zeroForOne, nowTs);
        (uint256 sR, uint256 nR) = FeeRef.cfStep(rev, tick, !zeroForOne, nowTs);
        assertEq(sC, sR, "reverse(dir) != continuation(!dir)");
        assertEq(nC | (uint256(1) << FeeRef.CF_MODE_SHIFT), nR, "state update differs between modes");
    }

    function testFuzz_cfStep_surchargeNeverExceedsTheCap(uint256 cf, int24 tick, bool zeroForOne, uint256 nowTs)
        public
        pure
    {
        (uint256 s, uint256 cfNew) = FeeRef.cfStep(cf, tick, zeroForOne, nowTs);
        assertLe(s, (cf >> FeeRef.CF_CAP_SHIFT) & 0xffffff);
        assertLe(s, 0xffffff);
        assertEq(cfNew >> FeeRef.CF_DECAY1_SHIFT, cf >> FeeRef.CF_DECAY1_SHIFT, "a step rewrote parameters");
    }

    function test_cfStep_noWriteBeforeThePeriodElapses() public pure {
        uint256 cf = _cf(0, 256, 2500, 0, 60, 15, uint40(NOW), 256);
        (uint256 s, uint256 cfNew) = FeeRef.cfStep(cf, 0, true, NOW + 14);
        assertEq(cfNew, cf, "wrote inside the period");
        assertEq(s, 100, "the anchor is still where it was");
        (, cfNew) = FeeRef.cfStep(cf, 0, true, NOW + 15);
        assertTrue(cfNew != cf, "no write at the period boundary");
        assertEq(FeeRef.unpackCF(cfNew).tLast, NOW + 15);
    }

    function test_cfStep_anchorSnapsToTheTickAfterMaxAge() public pure {
        uint256 cf = _cf(0, 256, 2500, 0, 20, 1, uint40(NOW), 100_000);
        (uint256 s, uint256 cfNew) = FeeRef.cfStep(cf, 7, true, NOW + 100);
        assertEq(FeeRef.unpackCF(cfNew).anchor, 7 * 256, "anchor != tick after maxAge");
        assertEq(s, 0);
        (, cfNew) = FeeRef.cfStep(cf, 7, true, NOW + 99);
        assertTrue(FeeRef.unpackCF(cfNew).anchor != 7 * 256, "decayed, not snapped, one second before maxAge");
    }

    function test_cfStep_decayArithmeticOnSignedDistances() public pure {
        FeeRef.CFWord memory c = FeeRef.CFWord({
            tLast: uint40(NOW),
            anchor: 1000,
            decay1: uint32(1) << 31,
            kQ8: 256,
            cfCap: 2500,
            band16: 0,
            maxAge: 255,
            period: 1,
            tau: 1,
            mode: 0
        });
        (, uint256 n) = FeeRef.cfStep(FeeRef.packCF(c), 0, true, NOW + 1);
        assertEq(FeeRef.unpackCF(n).anchor, 500);
        c.anchor = -1000;
        (, n) = FeeRef.cfStep(FeeRef.packCF(c), 0, true, NOW + 1);
        assertEq(FeeRef.unpackCF(n).anchor, -500);
        c.anchor = -1001;
        (, n) = FeeRef.cfStep(FeeRef.packCF(c), 0, true, NOW + 1);
        assertEq(FeeRef.unpackCF(n).anchor, -500, "the step truncates toward the tick");
        c.anchor = 1000;
        (, n) = FeeRef.cfStep(FeeRef.packCF(c), 0, true, NOW + 2);
        assertEq(FeeRef.unpackCF(n).anchor, 250);
        (, n) = FeeRef.cfStep(FeeRef.packCF(c), 3, true, NOW + 1);
        assertEq(FeeRef.unpackCF(n).anchor, 768 + (1000 - 768) / 2);
    }

    function testFuzz_cfStep_decayIsMonotoneAtAFixedTick(
        uint8 mode,
        CFIn memory p,
        int24 tick,
        bool zeroForOne,
        uint16 gap1,
        uint16 gap2
    ) public pure {
        tick = int24(bound(tick, -887_272, 887_272));
        uint256 cf = _boundedCF(mode, p);
        (uint256 s1, uint256 cf1) = FeeRef.cfStep(cf, tick, zeroForOne, uint256(p.tLast) + gap1);
        (uint256 s2, uint256 cf2) = FeeRef.cfStep(cf1, tick, zeroForOne, uint256(p.tLast) + gap1 + gap2);
        assertLe(s2, s1, "surcharge rose at a fixed tick");
        int256 t = int256(tick) * 256;
        assertLe(
            _abs(FeeRef.unpackCF(cf1).anchor - t),
            _abs(FeeRef.unpackCF(cf).anchor - t),
            "anchor moved away from the tick (step 1)"
        );
        assertLe(
            _abs(FeeRef.unpackCF(cf2).anchor - t),
            _abs(FeeRef.unpackCF(cf1).anchor - t),
            "anchor moved away from the tick (step 2)"
        );
    }

    function testFuzz_cfStep_neverReverts(uint256 cf, int24 tick, bool zeroForOne, uint256 nowTs) public pure {
        FeeRef.cfStep(cf, tick, zeroForOne, nowTs);
    }

    function test_resolve_cfAddsOnTopAndCapsAtThePoolCap() public pure {
        uint256 w = _word(1000, 1000, 0, 0, 0, 100, 1050).withCfOn(true);
        uint256 cf = _cf(0, 256, 2500, 0, 60, 15, uint40(NOW), 256);
        (uint256 fee, uint256 cfNew) = FeeRef.resolve(w, true, address(1), 0, cf, 0, NOW);
        assertEq(fee, 1050, "pool cap binds the CF");
        assertEq(cfNew, cf, "inside the period: no write");
        (fee,) = FeeRef.resolve(w, false, address(1), 0, cf, 0, NOW);
        assertEq(fee, 1000, "the other side pays no CF");
        w = w.withCfOn(false);
        (fee, cfNew) = FeeRef.resolve(w, true, address(1), 0, cf, 0, NOW + 1000);
        assertEq(fee, 1000, "cfOn 0: no CF");
        assertEq(cfNew, cf, "cfOn 0: no CF write even when a step would be due");
    }

    function test_resolve_discountNeverTouchesTheCF() public pure {
        address desk = address(0xDE5C);
        uint256 w = _word(1000, 1000, 0, 0, 0, 0, 8000).withSeed(3).withCfOn(true);
        w = w.withBloom(DiscountLib.mask64(desk, 3));
        uint256 entry = DiscountLib.pack(5000, 0, 3, uint40(NOW + 1));
        uint256 cf = _cf(0, 256, 2500, 0, 60, 15, uint40(NOW), 2 * 256);
        (uint256 fee,) = FeeRef.resolve(w, true, desk, entry, cf, 0, NOW);
        assertEq(fee, 500 + 200);
        (fee,) = FeeRef.resolve(w, true, address(0xBEEF), 0, cf, 0, NOW);
        assertEq(fee, 1000 + 200);
    }

    function testFuzz_resolve_neverReverts(
        uint256 w,
        bool zeroForOne,
        address sender,
        uint256 entry,
        uint256 cf,
        int24 tick,
        uint256 nowTs
    ) public pure {
        FeeRef.resolve(w, zeroForOne, sender, entry, cf, tick, nowTs);
    }

    function testFuzz_resolve_staysInsideTheBand(
        WordIn memory i,
        bool zeroForOne,
        address sender,
        uint256 entry,
        uint256 cf,
        int24 tick,
        uint256 nowTs
    ) public pure {
        uint256 w = _configuredWord(i);
        (uint256 fee, uint256 cfNew) = FeeRef.resolve(w, zeroForOne, sender, entry, cf, tick, nowTs);
        assertGe(fee, w.floor());
        assertLe(fee, w.cap());
        if (!w.cfOn()) assertEq(cfNew, cf, "CF word touched while cfOn is 0");
    }

    bytes constant DECAY_TABLE =
        hex"d19856b0d8b306bdddebb5c5e1eb5127e5143080e7a36ccee9c0f7f2eb8807dfed0bc906ee5a215def7d62c1f07d5fdef1602265f22a6656f2dfef69f383c585f418605df49fc776f51ba9f7f58d70b4f5f64bf3f6573e12f6b123e1f704bb38f752a834f79b796ff7dfab6af81fab54f85bd954f8948a6df8ca0a0ff8fc9b65f92c7a71f959dcf9f984f354f9ade90ff9d4e588f9fa0c67fa1d7e0efa3f57f4fa5fb4fcfa7eadb6fa9c58a2fab8ca67fad415fcfaee4cddfb077f26fb1fbbbcfb371064fb4d89e4fb633412fb7819f1fb8c45bffb9fc106fbb294adfbc4c902fbd665ccfbe77251fbf7f560fc07f55ffc17784ffc2683d3fc351d3bfc434985fc510d67fc5e6d52fc6b6d79fc7811d1fc845e1afc9055dffc9bfc7dfca75521fcb262d1fcbd2869fcc7a8a2fcd1e613fcdbe330fce5a24ffcef25acfcf86f65fd018180fd0a5debfd13067cfd1b7cf7fd23c308fd2bda4bfd33c448fd3b8277fd431641fd4a80fcfd51c3f5fd58e067fd5fd781fd66aa67fd6d5a30fd73e7e9fd7a5493fd80a126fd86ce8ffd8cddb5fd92cf73fd98a49efd9e5e01fda3fc61fda9807cfdaeeb08fdb43cb5fdb9762dfdbe9814fdc3a308fdc897a1fdcd7673fdd2400cfdd6f4f6fddb95b5fde022cbfde49cb3fde903e5fded58d7fdf19bf8fdf5cdb6fdf9ee7afdfdfeabfe01feabfe05eedafe09cf96fe0da139fe11641afe15188ffe18bee9fe1c5778fe1fe28bfe23606cfe26d165fe2a35bcfe2d8db7fe30d999fe3419a2fe374e13fe3a7729fe3d9521fe40a833fe43b099fe46ae8afe49a23dfe4c8be4fe4f6bb4fe5241ddfe550e90fe57d1fcfe5a8c4ffe5d3db5fe5fe65afe628668fe651e09fe67ad65fe6a34a4fe6cb3ebfe6f2b61fe719b28fe740367fe76643efe78bdd0fe7b103efe7d5ba9fe7fa030fe81ddf2fe84150cfe86459dfe886fc2fe8a9396fe8cb134fe8ec8b9fe90da3dfe92e5dbfe94ebacfe96ebc8fe98e647fe9adb41fe9ccacdfe9eb501fea099f4fea279bafea45469fea62a15fea7fad3fea9c6b7feab8dd3fead503cfeaf0e02feb0c739feb27bf3feb42c40feb5d833feb77fdbfeb92349febac28dfebc5db8febdf4d8febf87fcfec11735fec2a28ffec42a1afec5ade4fec72df9fec8aa69feca233ffecb988afecd0a56fece78aefecfe3a1fed14b39fed2af82fed41089fed56e58fed6c8fbfed8207dfed974e8fedac648fedc14a6fedd600dfedea886fedfee1dfee130dafee270c7fee3adedfee4e856fee6200afee75513fee8877afee9b746feeae480feec0f31feed3761feee5d18feef805dfef0a139fef1bfb3fef2dbd3fef3f5a0fef50d21fef6225dfef7355cfef84624fef954bdfefa612cfefb6b79fefc73aafefd79c6fefe7dd2feff7fd5ff007fd5ff017dd8ff0279e4ff0373feff046c2dff056276ff0656dfff07496dff083a25ff09290dff0a162aff0b0182ff0beb18ff0cd2f3ff0db917ff0e9d89ff0f804dff106169ff1140e2ff121ebbff12faf9ff13d5a1ff14aeb6ff15863fff165c3dff1730b7ff1803afff18d52bff19a52dff1a73bbff1b40d7ff1c0c86ff1cd6cbff1d9fabff1e6729ff1f2d48ff1ff20dff20b57aff217794ff22385dff22f7d9ff23b60cff2472f9ff252ea2ff25e90c";

    function test_decay1_matchesExactFloorForEveryLegalTau() public pure {
        bytes memory table = DECAY_TABLE;
        assertEq(table.length, 296 * 4);
        for (uint256 tau = 5; tau <= 300; ++tau) {
            uint256 i = tau - 5;
            uint32 expected;
            assembly ("memory-safe") {
                expected := shr(224, mload(add(add(table, 32), mul(i, 4))))
            }
            assertEq(FeeRef.decay1Q32(tau), expected, "decay1 off for some tau");
        }
    }

    function test_decay1_knownValues() public pure {
        assertEq(FeeRef.decay1Q32(60), 4_223_977_730);
        assertEq(FeeRef.decay1Q32(1), 1_580_030_168);
        assertLt(FeeRef.decay1Q32(5), FeeRef.decay1Q32(300), "monotone in tau");
    }

    function test_cfOffsetsMatchTheLayout() public pure {
        uint256 cf = uint256(1) | (uint256(uint32(int32(-2))) << 40) | (uint256(3) << 72) | (uint256(4) << 104)
            | (uint256(5) << 120) | (uint256(6) << 144) | (uint256(7) << 160) | (uint256(8) << 168)
            | (uint256(9) << 176) | (uint256(1) << 192);
        FeeRef.CFWord memory c = FeeRef.unpackCF(cf);
        assertEq(c.tLast, 1);
        assertEq(c.anchor, -2);
        assertEq(c.decay1, 3);
        assertEq(c.kQ8, 4);
        assertEq(c.cfCap, 5);
        assertEq(c.band16, 6);
        assertEq(c.maxAge, 7);
        assertEq(c.period, 8);
        assertEq(c.tau, 9);
        assertEq(c.mode, 1);
        assertEq(FeeRef.packCF(c), cf);
        assertEq(FeeRef.cfK(cf), 4);
    }

    function testFuzz_cfPackUnpackRoundTrip(FeeRef.CFWord memory c) public pure {
        c.mode &= 1;
        uint256 cf = FeeRef.packCF(c);
        assertLt(cf, uint256(1) << 193, "spare bits must stay zero");
        FeeRef.CFWord memory d = FeeRef.unpackCF(cf);
        assertEq(d.tLast, c.tLast);
        assertEq(d.anchor, c.anchor);
        assertEq(d.decay1, c.decay1);
        assertEq(d.kQ8, c.kQ8);
        assertEq(d.cfCap, c.cfCap);
        assertEq(d.band16, c.band16);
        assertEq(d.maxAge, c.maxAge);
        assertEq(d.period, c.period);
        assertEq(d.tau, c.tau);
        assertEq(d.mode, c.mode);
    }

    function testFuzz_cfRearmAndWithKTouchOnlyTheirFields(uint256 cf, uint40 nowTs, int24 tick, uint16 k) public pure {
        tick = int24(bound(tick, -887_272, 887_272));
        uint256 r = FeeRef.cfRearm(cf, nowTs, tick);
        FeeRef.CFWord memory c = FeeRef.unpackCF(r);
        assertEq(c.tLast, nowTs);
        assertEq(c.anchor, int256(tick) * 256);
        assertEq(r >> 72, cf >> 72, "re-arm touched parameters");
        uint256 kw = FeeRef.cfWithK(cf, k);
        assertEq(FeeRef.cfK(kw), k);
        assertEq(kw & ~FeeRef.CF_K_MASK, cf & ~FeeRef.CF_K_MASK, "withK touched other fields");
    }

    function _abs(int256 x) internal pure returns (int256) {
        return x < 0 ? -x : x;
    }
}
