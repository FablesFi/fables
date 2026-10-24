// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {FeeRef} from "../../../src/libraries/FeeRef.sol";
import {PoolWordLib} from "../../../src/libraries/PoolWordLib.sol";
import {DiscountLib} from "../../../src/libraries/DiscountLib.sol";
import {FullTestBase} from "../../utils/FullTestBase.sol";

/// @notice Discount band and continuation fee as properties of the assembly swap entry, with storage-access checks.
contract FullPropertiesTest is FullTestBase {
    using PoolIdLibrary for PoolKey;
    using PoolWordLib for uint256;

    uint256 constant CF_MODE_BIT = uint256(1) << 192;

    function setUp() public {
        _deployFull();
    }

    function _wordSlot(PoolId id) internal view returns (bytes32) {
        return keccak256(abi.encode(id, hook.WORD_SLOT()));
    }

    function _cfSlot(PoolId id) internal view returns (bytes32) {
        return keccak256(abi.encode(id, hook.CF_SLOT()));
    }

    function _contains(bytes32[] memory xs, bytes32 x) internal pure returns (bool) {
        for (uint256 k = 0; k < xs.length; ++k) {
            if (xs[k] == x) return true;
        }
        return false;
    }

    struct DiscountIn {
        uint256 raw;
        uint24 base0;
        uint24 base1;
        uint24 floor_;
        uint24 cap;
        uint16 bps;
        uint24 minFee;
        uint8 dirs;
        uint32 ttl;
        bool live;
        uint8 seed;
        bool zeroForOne;
        address desk;
        address other;
        uint256 salt;
    }

    function testFuzz_discountBand(DiscountIn memory i) public {
        vm.assume(i.desk != address(0) && i.other != i.desk);
        PoolKey memory key = _key(i.salt);
        PoolId id = key.toId();
        i.seed &= 0x7f;
        i.bps = uint16(bound(i.bps, 1, 5_000));
        i.dirs = uint8(bound(i.dirs, 1, 3));
        uint256 w = _configuredWord(i.raw, i.base0, i.base1, i.floor_, i.cap).withCfOn(false).withSeed(i.seed);
        w = w.withBloom(w.bloom() | DiscountLib.mask64(i.desk, i.seed));
        hook.__setWord(id, w);
        {
            uint40 expiry = i.live ? uint40(NOW + bound(i.ttl, 1, 90 days)) : uint40(bound(i.ttl, 0, NOW));
            hook.__setEntry(id, i.desk, DiscountLib.pack(i.bps, i.minFee, i.dirs, expiry));
        }

        uint256 L = hook.currentFee(id, i.zeroForOne);
        assertEq(L, FeeRef.keeperFee(w, i.zeroForOne, NOW), "L is keeperFee");
        assertEq(_swapFee(key, i.other, i.zeroForOne), L, "unlisted pays exactly L");

        uint256 f = _swapFee(key, i.desk, i.zeroForOne);
        assertEq(f, uint256(hook.feeFor(id, i.zeroForOne, i.desk)), "feeFor == charged");
        bool covers = ((i.dirs >> (i.zeroForOne ? 0 : 1)) & 1) == 1;
        if (i.live && covers) _assertDiscountBand(f, L, w.floor(), i.minFee, i.bps);
        else assertEq(f, L, "entry not live for this direction: pays L");
    }

    function _assertDiscountBand(uint256 f, uint256 L, uint256 floor_, uint24 minFee, uint16 bps) internal pure {
        assertLe(f, L, "a discount never raises");
        assertGe(f, (L + 1) / 2, "ceil(L/2) <= f");
        uint256 lo = floor_ > minFee ? floor_ : minFee;
        if (lo > L) lo = L;
        assertGe(f, lo, "f >= min(L, max(floor, minFee))");
        assertEq(f, DiscountLib.applyDiscount(L, bps, minFee, floor_), "exact DiscountLib value");
    }

    function _discountPool(uint24 base, uint24 floor_, uint24 cap, address desk, uint8 seed)
        internal
        returns (PoolKey memory key, PoolId id)
    {
        key = _key(uint160(desk));
        id = key.toId();
        uint256 w = _configuredWord(0, base, base, floor_, cap).withSeed(seed);
        hook.__setWord(id, w.withBloom(DiscountLib.mask64(desk, seed)));
    }

    function test_roundsUpClampsBpsAndHonoursFloorAndMinFee() public {
        address desk = address(0xD35C);
        (PoolKey memory key, PoolId id) = _discountPool(1_001, 300, 50_000, desk, 9);
        hook.__setEntry(id, desk, DiscountLib.pack(5_000, 0, 3, uint40(NOW + 1 days)));
        assertEq(_swapFee(key, desk, true), 501, "rounds up");
        hook.__setEntry(id, desk, DiscountLib.pack(9_000, 0, 3, uint40(NOW + 1 days)));
        assertEq(_swapFee(key, desk, true), 501, "bps clamped");
        hook.__setWord(id, hook.poolWord(id).withBounds(800, 50_000));
        assertEq(_swapFee(key, desk, true), 800, "floor binds");
        hook.__setEntry(id, desk, DiscountLib.pack(5_000, 900, 3, uint40(NOW + 1 days)));
        assertEq(_swapFee(key, desk, true), 900, "minFee binds");
        hook.__setEntry(id, desk, DiscountLib.pack(5_000, 5_000, 3, uint40(NOW + 1 days)));
        assertEq(_swapFee(key, desk, true), 1_001, "never raises");
        hook.__setEntry(id, desk, DiscountLib.pack(5_000, 0, uint8(DiscountLib.DIR_ONE_FOR_ZERO), uint40(NOW + 1 days)));
        assertEq(_swapFee(key, desk, true), 1_001, "zeroForOne not covered");
        assertEq(_swapFee(key, desk, false), 800, "oneForZero covered (floor 800)");
        hook.__setEntry(id, desk, DiscountLib.pack(5_000, 0, 3, uint40(NOW)));
        assertEq(_swapFee(key, desk, true), 1_001, "expired at expiry");
        hook.__setEntry(id, desk, DiscountLib.pack(0, 0, 3, uint40(NOW + 1 days)));
        assertEq(_swapFee(key, desk, true), 1_001, "bps 0");
    }

    function test_bloomMissSkipsTheEntryAndFilterZeroSkipsEverything() public {
        address desk = address(0xD35C);
        (PoolKey memory key, PoolId id) = _discountPool(2_000, 0, 50_000, desk, 9);
        hook.__setEntry(id, desk, DiscountLib.pack(5_000, 0, 3, uint40(NOW + 1 days)));
        assertEq(_swapFee(key, desk, true), 1_000);
        hook.__setWord(id, hook.poolWord(id).withBloom(0));
        vm.record();
        assertEq(_swapFee(key, desk, true), 2_000, "filter 0: no discount");
        (bytes32[] memory reads,) = vm.accesses(hookAddr);
        assertEq(reads.length, 1, "only the pool word is read");
        assertEq(reads[0], _wordSlot(id));
        uint64 m = DiscountLib.mask64(desk, 9);
        hook.__setWord(id, hook.poolWord(id).withBloom(~m));
        assertEq(_swapFee(key, desk, true), 2_000, "Bloom miss");
    }

    function test_discountNeverTouchesTheCF() public {
        address desk = address(0xD35C);
        (PoolKey memory key, PoolId id) = _discountPool(3_000, 0, 50_000, desk, 3);
        hook.__setEntry(id, desk, DiscountLib.pack(5_000, 0, 3, uint40(NOW + 1 days)));
        hook.__setWord(id, hook.poolWord(id).withCfOn(true));
        _setTick(id, 0);
        hook.__setCF(id, _legalCF(CFParams(0, 256, 2_500, 0, 60, 1, uint40(NOW), int32(10 * 256))));
        assertEq(_swapFee(key, desk, true), 1_500 + 1_000, "ceil(3000/2) + CF");
        assertEq(_swapFee(key, address(1), true), 3_000 + 1_000, "unlisted: base + CF");
    }

    struct SurchargeIn {
        uint256 raw;
        uint24 base0;
        uint24 base1;
        uint24 floor_;
        uint24 cap;
        CFParams cf;
        int24 tick;
        int16 anchorOffset16;
        uint16 dt;
        bool zeroForOne;
        uint256 salt;
    }

    function _arrangeSurcharge(SurchargeIn memory i)
        internal
        returns (PoolKey memory key, PoolId id, uint256 wOff, uint256 cf)
    {
        key = _key(i.salt);
        id = key.toId();
        wOff = _configuredWord(i.raw, i.base0, i.base1, i.floor_, i.cap).withPokesCleared().withBloom(0).withCfOn(false);
        int24 tick = int24(bound(i.tick, TickMath.MIN_TICK, TickMath.MAX_TICK));
        _setTick(id, tick);
        i.cf.tLast = uint40(NOW);
        i.cf.anchor = int32(int256(tick) * 256 + int256(i.anchorOffset16) * 16);
        cf = _legalCF(i.cf);
        hook.__setCF(id, cf);
        vm.warp(NOW + bound(i.dt, 0, 1000));
    }

    function testFuzz_surchargeInsideTheCap(SurchargeIn memory i) public {
        (PoolKey memory key, PoolId id, uint256 wOff, uint256 cf) = _arrangeSurcharge(i);
        hook.__setWord(id, wOff);
        uint256 feeOff = _swapFee(key, address(1), i.zeroForOne);
        hook.__setWord(id, wOff.withCfOn(true));
        uint256 feeOn = _swapFee(key, address(1), i.zeroForOne);
        uint256 cfCap = (cf >> 120) & 0xffffff;
        assertGe(feeOn, feeOff, "s >= 0");
        assertLe(feeOn - feeOff, cfCap, "s <= cfCap");
        assertLe(cfCap, 2_500);
        assertLe(feeOn, wOff.cap(), "fee <= cap");
        (uint256 s,) = FeeRef.cfStep(
            cf, _tickOf(uint256(vm.load(address(manager), _slot0Slot(id)))), i.zeroForOne, block.timestamp
        );
        uint256 expected = feeOff + s;
        if (expected > wOff.cap()) expected = wOff.cap();
        assertEq(feeOn, expected, "feeOn == min(feeOff + s, cap)");
    }

    function testFuzz_fixedTickSurchargeNeverRises(SurchargeIn memory i, uint16[4] memory steps) public {
        (PoolKey memory key, PoolId id, uint256 wOff,) = _arrangeSurcharge(i);
        hook.__setWord(id, wOff.withCfOn(true));
        uint256 prev = _swapFee(key, address(1), i.zeroForOne);
        for (uint256 k = 0; k < steps.length; ++k) {
            vm.warp(block.timestamp + bound(steps[k], 0, 600));
            uint256 f = _swapFee(key, address(1), i.zeroForOne);
            assertLe(f, prev, "surcharge rose at a fixed tick");
            prev = f;
        }
    }

    function testFuzz_reverseMirrorsContinuation(SurchargeIn memory i) public {
        (PoolKey memory keyA, PoolId idA, uint256 wOff, uint256 cfA) = _arrangeSurcharge(i);
        wOff = wOff.withBases(wOff.base0(), wOff.base0()).withCfOn(true);
        cfA &= ~CF_MODE_BIT;
        PoolKey memory keyB = _key(~i.salt);
        PoolId idB = keyB.toId();
        _setSlot0(idB, uint256(vm.load(address(manager), _slot0Slot(idA))));
        hook.__setWord(idA, wOff);
        hook.__setWord(idB, wOff);
        hook.__setCF(idA, cfA);
        hook.__setCF(idB, cfA | CF_MODE_BIT);
        uint256 feeA = _swapFee(keyA, address(1), i.zeroForOne);
        uint256 feeB = _swapFee(keyB, address(1), !i.zeroForOne);
        assertEq(feeA, feeB, "reverse(d) != continuation(!d)");
        assertEq(hook.cfWord(idA) | CF_MODE_BIT, hook.cfWord(idB) | CF_MODE_BIT, "state update differs");
    }

    function _cfPool(uint8 mode, int32 anchor, int24 tick, uint8 period)
        internal
        returns (PoolKey memory key, PoolId id, uint256 cf)
    {
        key = _key(uint256(mode) * 1000 + period);
        id = key.toId();
        hook.__setWord(id, _configuredWord(0, 3_000, 3_000, 0, 50_000).withCfOn(true));
        _setTick(id, tick);
        cf = _legalCF(CFParams(mode, 256, 2_500, 0, 60, period, uint40(NOW), anchor));
        hook.__setCF(id, cf);
    }

    function test_cfOff_readsOnlyThePoolWord() public {
        (PoolKey memory key, PoolId id, uint256 cf) = _cfPool(0, int32(100 * 256), 0, 1);
        hook.__setWord(id, hook.poolWord(id).withCfOn(false));
        vm.warp(NOW + 10);
        vm.record();
        assertEq(_swapFee(key, address(1), true), 3_000, "no CF while off");
        (bytes32[] memory reads, bytes32[] memory writes) = vm.accesses(hookAddr);
        assertEq(writes.length, 0, "no write");
        assertEq(reads.length, 1, "exactly one SLOAD");
        assertEq(reads[0], _wordSlot(id), "the pool word");
        assertFalse(_contains(reads, _cfSlot(id)), "CF word not read");
        (bytes32[] memory pmReads, bytes32[] memory pmWrites) = vm.accesses(address(manager));
        assertEq(pmReads.length, 0, "PoolManager not read");
        assertEq(pmWrites.length, 0);
        assertEq(hook.cfWord(id), cf, "CF word untouched");
    }

    function test_cfOn_beforePeriod_readsButNeverWrites() public {
        (PoolKey memory key, PoolId id, uint256 cf) = _cfPool(0, int32(100 * 256), 0, 60);
        vm.warp(NOW + 59);
        vm.record();
        assertEq(_swapFee(key, address(1), true), 3_000 + 2_500, "surcharge charged (cap 2_500)");
        (bytes32[] memory reads, bytes32[] memory writes) = vm.accesses(hookAddr);
        assertEq(writes.length, 0, "no write before the period");
        assertTrue(_contains(reads, _wordSlot(id)));
        assertTrue(_contains(reads, _cfSlot(id)));
        (bytes32[] memory pmReads,) = vm.accesses(address(manager));
        assertEq(pmReads.length, 1, "one PoolManager read");
        assertEq(pmReads[0], _slot0Slot(id), "slot0");
        assertEq(hook.cfWord(id), cf, "CF word untouched");
    }

    function test_cfOn_atPeriod_writesTheCfWordOnce() public {
        (PoolKey memory key, PoolId id, uint256 cf) = _cfPool(0, int32(100 * 256), 0, 60);
        vm.warp(NOW + 60);
        (uint256 s, uint256 cfNew) = FeeRef.cfStep(cf, 0, true, block.timestamp);
        vm.record();
        assertEq(_swapFee(key, address(1), true), 3_000 + s, "fee from the UPDATED anchor");
        (, bytes32[] memory writes) = vm.accesses(hookAddr);
        assertEq(writes.length, 1, "one SSTORE");
        assertEq(writes[0], _cfSlot(id));
        assertEq(hook.cfWord(id), cfNew, "cfNew");
        assertEq(hook.cfWord(id) & 0xffffffffff, block.timestamp, "tLast = now");
        assertTrue(cfNew != cf);
        int32 anchor = int32(uint32((cfNew >> 40) & 0xffffffff));
        assertLt(anchor, int32(100 * 256));
        assertGt(anchor, 0);
        assertApproxEqAbs(int256(anchor), 9_418, 2);
        vm.record();
        _swapFee(key, address(1), true);
        (, writes) = vm.accesses(hookAddr);
        assertEq(writes.length, 0, "no write within the period");
    }

    function test_noWriteWhenTheUpdateChangesNothing() public {
        PoolKey memory key = _key(77);
        PoolId id = key.toId();
        hook.__setWord(id, _configuredWord(0, 3_000, 3_000, 0, 50_000).withCfOn(true));
        _setTick(id, 500);
        uint256 cf = FeeRef.packCF(
            FeeRef.CFWord({
                tLast: uint40(NOW),
                anchor: int32(500 * 256),
                decay1: FeeRef.decay1Q32(60),
                kQ8: 256,
                cfCap: 2_500,
                band16: 0,
                maxAge: 255,
                period: 0,
                tau: 60,
                mode: 0
            })
        );
        hook.__setCF(id, cf);
        vm.record();
        assertEq(_swapFee(key, address(1), true), 3_000);
        (, bytes32[] memory writes) = vm.accesses(hookAddr);
        assertEq(writes.length, 0, "unchanged word not written");
    }

    function test_surchargeIsActuallyCharged() public {
        (PoolKey memory key, PoolId id,) = _cfPool(0, int32(10 * 256), 0, 1);
        assertEq(_swapFee(key, address(1), true), 3_000 + 1_000, "continuation: 10 ticks x 100 pips");
        assertEq(_swapFee(key, address(1), false), 3_000, "the other side pays the base");
        assertEq(uint256(hook.currentFee(id, true)), 4_000, "quote agrees");
        (key, id,) = _cfPool(1, int32(10 * 256), 0, 1);
        assertEq(_swapFee(key, address(1), false), 3_000 + 1_000, "reverse: oneForZero returns toward the anchor");
        assertEq(_swapFee(key, address(1), true), 3_000, "continuing side pays the base in reverse mode");
        hook.__setCF(id, _legalCF(CFParams(0, 256, 2_500, 160, 60, 1, uint40(NOW), int32(10 * 256))));
        assertEq(_swapFee(key, address(1), true), 3_000, "m == band pays 0");
        hook.__setCF(id, _legalCF(CFParams(0, 256, 2_500, 159, 60, 1, uint40(NOW), int32(10 * 256))));
        assertEq(_swapFee(key, address(1), true), 3_000 + 6, "one 1/16 tick over the band: 100/16 rounded down");
    }

    function test_anchorSnapsAfterMaxAge() public {
        (PoolKey memory key, PoolId id,) = _cfPool(0, int32(100 * 256), 0, 1);
        vm.warp(NOW + 255);
        assertEq(_swapFee(key, address(1), true), 3_000, "snapped: no surcharge");
        assertEq(int32(uint32((hook.cfWord(id) >> 40) & 0xffffffff)), 0, "anchor == tick");
    }

    function test_poolCapBindsTheSum() public {
        (PoolKey memory key, PoolId id,) = _cfPool(0, int32(100 * 256), 0, 1);
        hook.__setWord(id, hook.poolWord(id).withBounds(0, 4_000));
        assertEq(_swapFee(key, address(1), true), 4_000, "min(3000 + 2500, cap 4000)");
    }
}
