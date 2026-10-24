// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {FablesHookCore} from "../../../src/base/FablesHookCore.sol";
import {FablesFeeFull} from "../../../src/base/FablesFeeFull.sol";
import {FeeRef} from "../../../src/libraries/FeeRef.sol";
import {PoolWordLib} from "../../../src/libraries/PoolWordLib.sol";
import {DiscountLib} from "../../../src/libraries/DiscountLib.sol";
import {FullTestBase} from "../../utils/FullTestBase.sol";

/// @notice Each branch of the assembly swap entry, both ways, against hand-computed fees and `FeeRef.resolve`.
contract FullEntryBranchesTest is FullTestBase {
    using PoolIdLibrary for PoolKey;
    using PoolWordLib for uint256;

    uint256 internal constant CF_SLOT = 3;

    PoolId internal id;

    function setUp() public {
        _deployFull();
        key = _key(14);
        id = key.toId();
    }

    function _fee(uint256 w, uint256 entry, uint256 cf, int24 tick, address sender, bool zeroForOne)
        internal
        returns (uint256 fee)
    {
        hook.__setWord(id, w);
        hook.__setCF(id, cf);
        hook.__setEntry(id, sender, entry);
        _setTick(id, tick);
        (uint256 expFee, uint256 expCf) = FeeRef.resolve(w, zeroForOne, sender, entry, cf, tick, block.timestamp);
        fee = _swapFee(key, sender, zeroForOne);
        assertEq(fee, expFee, "entry != FeeRef.resolve");
        assertEq(hook.cfWord(id), expCf, "CF word != FeeRef cfNew");
    }

    function _plain(uint256 w, bool zeroForOne) internal returns (uint256) {
        return _fee(w, 0, 0, 0, address(0xA11CE), zeroForOne);
    }

    function _w(uint24 b0, uint24 b1, uint24 floor_, uint24 cap) internal pure returns (uint256) {
        return uint256(0).withBases(b0, b1).withBounds(floor_, cap);
    }

    function _cfSlot() internal view returns (bytes32) {
        return keccak256(abi.encode(id, CF_SLOT));
    }

    function _cf(uint8 mode, uint16 k, uint24 cfCap, uint16 band16, uint16 tau, uint8 period, uint40 tLast, int32 a)
        internal
        pure
        returns (uint256)
    {
        uint256 maxAge = 5 * uint256(tau);
        if (maxAge > 255) maxAge = 255;
        return FeeRef.packCF(
            FeeRef.CFWord({
                tLast: tLast,
                anchor: a,
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

    function _anchorOf(uint256 cf) internal pure returns (int32) {
        return int32(uint32((cf >> 40) & 0xffffffff));
    }

    function _listed(uint256 w, address sender, uint8 seed) internal pure returns (uint256) {
        return w.withSeed(seed).withBloom(DiscountLib.mask64(sender, seed));
    }

    function _outsider(uint64 bloom, uint8 seed) internal pure returns (address a) {
        for (uint160 i = 1;; ++i) {
            a = address(i);
            uint64 m = DiscountLib.mask64(a, seed);
            if (bloom & m != m) return a;
        }
    }

    function test_gate_poolManagerBeforeSwapIsServed() public {
        hook.__setWord(id, _w(3_000, 3_000, 0, 50_000));
        (bool ok, bytes memory ret) = _callAsPoolManager(_beforeSwapCalldata(key, address(1), true, -1, ""));
        assertTrue(ok);
        assertEq(_feeWord(ret), 3_000 | OVERRIDE);
    }

    function test_gate_otherCallerOrSelectorReverts() public {
        hook.__setWord(id, _w(3_000, 3_000, 0, 50_000));
        bytes memory cd = _beforeSwapCalldata(key, address(1), true, -1, "");
        vm.prank(address(0xBAD));
        (bool ok, bytes memory ret) = hookAddr.call(cd);
        assertFalse(ok);
        assertEq(ret, abi.encodeWithSelector(FablesHookCore.NotPoolManager.selector));
        cd[0] = 0x00;
        (ok, ret) = _callAsPoolManager(cd);
        assertFalse(ok);
        assertEq(ret, abi.encodeWithSelector(FablesHookCore.NotPoolManager.selector));
    }

    function test_poke_livePokeApplies() public {
        uint256 w = _w(3_000, 4_000, 100, 50_000).withPokes(5_000, 0, uint40(NOW + 100));
        assertEq(_plain(w, true), 5_000);
    }

    function test_poke_expiredPokeIgnored() public {
        uint256 w = _w(3_000, 4_000, 100, 50_000).withPokes(5_000, 6_000, uint40(NOW));
        assertEq(_plain(w, true), 3_000);
        assertEq(_plain(w, false), 4_000);
    }

    function test_poke_unpokedSideKeepsBase() public {
        uint256 w = _w(3_000, 4_000, 100, 50_000).withPokes(5_000, 0, uint40(NOW + 100));
        assertEq(_plain(w, false), 4_000);
    }

    function test_poke_cutBelowHalfIsLiftedToHalf() public {
        uint256 w = _w(3_000, 3_000, 0, 50_000).withPokes(1_000, 1_000, uint40(NOW + 100));
        assertEq(_plain(w, true), 1_500);
    }

    function test_poke_cutAboveHalfIsKept() public {
        uint256 w = _w(3_000, 3_000, 0, 50_000).withPokes(2_000, 2_000, uint40(NOW + 100));
        assertEq(_plain(w, true), 2_000);
    }

    function test_poke_halfIsTakenOfTheCapWhenBaseExceedsIt() public {
        uint256 w = _w(60_000, 60_000, 0, 50_000).withPokes(1_000, 1_000, uint40(NOW + 100));
        assertEq(_plain(w, true), 25_000);
    }

    function test_poke_floorBindsAbovePokeAndHalf() public {
        uint256 w = _w(3_000, 3_000, 1_800, 50_000).withPokes(1_000, 1_000, uint40(NOW + 100));
        assertEq(_plain(w, true), 1_800);
    }

    function test_cap_clampsPokeAndBase() public {
        uint256 w = _w(3_000, 3_000, 0, 30_000).withPokes(40_000, 0, uint40(NOW + 100));
        assertEq(_plain(w, true), 30_000);
        assertEq(_plain(_w(60_000, 60_000, 0, 50_000), false), 50_000, "raw base above cap");
    }

    function test_discount_noFilterSkipsEntry() public {
        address s = address(0xD15C);
        hook.__setWord(id, _w(3_000, 3_000, 0, 50_000));
        hook.__setEntry(id, s, DiscountLib.pack(2_000, 0, 3, uint40(NOW + 1_000)));
        vm.record();
        assertEq(_swapFee(key, s, true), 3_000);
        (bytes32[] memory reads,) = vm.accesses(hookAddr);
        assertEq(reads.length, 1, "only the pool word");
        assertEq(reads[0], keccak256(abi.encode(id, uint256(2))));
    }

    function test_discount_bloomMissSkipsLiveEntry() public {
        uint256 w = _listed(_w(3_000, 3_000, 0, 50_000), address(0xD15C), 9);
        address s = _outsider(w.bloom(), 9);
        uint256 e = DiscountLib.pack(2_000, 0, 3, uint40(NOW + 1_000));
        assertEq(_fee(w, e, 0, 0, s, true), 3_000);
    }

    function test_discount_liveEntryCuts() public {
        address s = address(0xD15C);
        uint256 w = _listed(_w(3_000, 3_000, 0, 50_000), s, 9);
        assertEq(_fee(w, DiscountLib.pack(2_000, 0, 3, uint40(NOW + 1_000)), 0, 0, s, true), 2_400);
        assertEq(_fee(w, DiscountLib.pack(2_001, 0, 2, uint40(NOW + 1_000)), 0, 0, s, false), 2_400, "ceil");
    }

    function test_discount_deadEntriesLeaveFee() public {
        address s = address(0xD15C);
        uint256 w = _listed(_w(3_000, 3_000, 0, 50_000), s, 9);
        assertEq(_fee(w, DiscountLib.pack(2_000, 0, 3, uint40(NOW)), 0, 0, s, true), 3_000, "expired");
        assertEq(_fee(w, DiscountLib.pack(0, 0, 3, uint40(NOW + 1_000)), 0, 0, s, true), 3_000, "bps 0");
        assertEq(_fee(w, DiscountLib.pack(2_000, 0, 2, uint40(NOW + 1_000)), 0, 0, s, true), 3_000, "oneForZero only");
        assertEq(_fee(w, DiscountLib.pack(2_000, 0, 1, uint40(NOW + 1_000)), 0, 0, s, false), 3_000, "zeroForOne only");
    }

    function test_discount_bpsClampedToHalf() public {
        address s = address(0xD15C);
        uint256 w = _listed(_w(3_000, 3_000, 0, 50_000), s, 9);
        assertEq(_fee(w, DiscountLib.pack(8_000, 0, 3, uint40(NOW + 1_000)), 0, 0, s, true), 1_500);
    }

    function test_discount_poolFloorBinds() public {
        address s = address(0xD15C);
        uint256 w = _listed(_w(3_000, 3_000, 2_000, 50_000), s, 9);
        assertEq(_fee(w, DiscountLib.pack(5_000, 0, 3, uint40(NOW + 1_000)), 0, 0, s, true), 2_000);
    }

    function test_discount_minFeeBinds() public {
        address s = address(0xD15C);
        uint256 w = _listed(_w(3_000, 3_000, 100, 50_000), s, 9);
        assertEq(_fee(w, DiscountLib.pack(5_000, 2_500, 3, uint40(NOW + 1_000)), 0, 0, s, true), 2_500);
    }

    function test_discount_neverRaises() public {
        address s = address(0xD15C);
        uint256 w = _listed(_w(3_000, 3_000, 0, 50_000), s, 9);
        assertEq(_fee(w, DiscountLib.pack(5_000, 4_000, 3, uint40(NOW + 1_000)), 0, 0, s, true), 3_000);
    }

    function test_cf_offIgnoresWord() public {
        uint256 cf = _cf(0, 256, 2_500, 0, 60, 1, uint40(NOW - 30), int32(10 * 256));
        hook.__setWord(id, _w(3_000, 3_000, 0, 50_000));
        hook.__setCF(id, cf);
        vm.record();
        assertEq(_swapFee(key, address(1), true), 3_000);
        (bytes32[] memory reads, bytes32[] memory writes) = vm.accesses(hookAddr);
        assertEq(writes.length, 0, "no write");
        assertEq(reads.length, 1, "only the pool word");
        assertEq(hook.cfWord(id), cf);
    }

    function test_cf_continuationSurcharge() public {
        uint256 w = _w(3_000, 3_000, 0, 50_000).withCfOn(true);
        uint256 cf = _cf(0, 256, 2_500, 0, 60, 10, uint40(NOW), 0);
        assertEq(_fee(w, 0, cf, -10, address(1), true), 4_000);
    }

    function test_cf_otherSidePaysBase() public {
        uint256 w = _w(3_000, 3_000, 0, 50_000).withCfOn(true);
        uint256 cf = _cf(0, 256, 2_500, 0, 60, 10, uint40(NOW), 0);
        assertEq(_fee(w, 0, cf, -10, address(1), false), 3_000);
    }

    function test_cf_reverseMode() public {
        uint256 w = _w(3_000, 3_000, 0, 50_000).withCfOn(true);
        uint256 cf = _cf(1, 256, 2_500, 0, 60, 10, uint40(NOW), 0);
        assertEq(_fee(w, 0, cf, -10, address(1), false), 4_000);
        assertEq(_fee(w, 0, cf, -10, address(1), true), 3_000);
    }

    function test_cf_bandIsSubtracted() public {
        uint256 w = _w(3_000, 3_000, 0, 50_000).withCfOn(true);
        uint256 cf = _cf(0, 256, 2_500, 100, 60, 10, uint40(NOW), 0);
        assertEq(_fee(w, 0, cf, -10, address(1), true), 3_375);
    }

    function test_cf_surchargeClampedToCfCap() public {
        uint256 w = _w(3_000, 3_000, 0, 50_000).withCfOn(true);
        uint256 cf = _cf(0, 256, 500, 0, 60, 10, uint40(NOW), 0);
        assertEq(_fee(w, 0, cf, -10, address(1), true), 3_500);
    }

    function test_cf_sumClampedToPoolCap() public {
        uint256 w = _w(3_000, 3_000, 0, 3_500).withCfOn(true);
        uint256 cf = _cf(0, 256, 2_500, 0, 60, 10, uint40(NOW), 0);
        assertEq(_fee(w, 0, cf, -10, address(1), true), 3_500);
    }

    function test_cf_extsloadRevertAddsNothing() public {
        uint256 w = _w(3_000, 3_000, 0, 50_000).withCfOn(true);
        uint256 cf = _cf(0, 256, 2_500, 0, 60, 1, uint40(NOW - 30), int32(100 * 256));
        hook.__setWord(id, w);
        hook.__setCF(id, cf);
        vm.mockCallRevert(address(manager), abi.encodeWithSelector(bytes4(0x1e2eaeaf)), "no");
        assertEq(_swapFee(key, address(1), true), 3_000);
        assertEq(hook.cfWord(id), cf, "CF word untouched");
    }

    function test_cf_emptyExtsloadReplyAddsNothing() public {
        uint256 w = _w(3_000, 3_000, 0, 50_000).withCfOn(true);
        uint256 cf = _cf(0, 256, 2_500, 0, 60, 1, uint40(NOW - 30), int32(100 * 256));
        hook.__setWord(id, w);
        hook.__setCF(id, cf);
        vm.etch(address(manager), "");
        assertEq(_swapFee(key, address(1), true), 3_000);
        assertEq(hook.cfWord(id), cf, "CF word untouched");
    }

    function test_cf_futureTLastReadsZeroDt() public {
        uint256 w = _w(3_000, 3_000, 0, 50_000).withCfOn(true);
        uint256 cf = _cf(0, 256, 2_500, 0, 60, 1, uint40(NOW + 1_000), int32(10 * 256));
        assertEq(_fee(w, 0, cf, 0, address(1), true), 4_000);
        assertEq(hook.cfWord(id), cf, "not rewritten");
    }

    function test_cf_insidePeriodNoUpdate() public {
        uint256 cf = _cf(0, 256, 2_500, 0, 60, 30, uint40(NOW - 29), int32(10 * 256));
        hook.__setWord(id, _w(3_000, 3_000, 0, 50_000).withCfOn(true));
        hook.__setCF(id, cf);
        _setTick(id, 0);
        vm.record();
        assertEq(_swapFee(key, address(1), true), 4_000);
        (, bytes32[] memory writes) = vm.accesses(hookAddr);
        assertEq(writes.length, 0, "no SSTORE inside the period");
        assertEq(hook.cfWord(id), cf);
    }

    function test_cf_decayOneSecond() public {
        uint256 w = _w(3_000, 3_000, 0, 50_000).withCfOn(true);
        uint256 cf = _cf(0, 256, 2_500, 0, 60, 1, uint40(NOW - 1), int32(100 * 256));
        _fee(w, 0, cf, 0, address(1), true);
        uint256 d1 = FeeRef.decay1Q32(60);
        assertEq(int256(_anchorOf(hook.cfWord(id))), (int256(100 * 256) * int256(d1)) / int256(1 << 32));
        assertEq(hook.cfWord(id) & 0xffffffffff, NOW, "tLast = now");
    }

    function test_cf_decayTwoSeconds() public {
        uint256 w = _w(3_000, 3_000, 0, 50_000).withCfOn(true);
        uint256 cf = _cf(0, 256, 2_500, 0, 60, 1, uint40(NOW - 2), int32(100 * 256));
        _fee(w, 0, cf, 0, address(1), true);
        uint256 d1 = FeeRef.decay1Q32(60);
        uint256 f = (d1 * d1) >> 32;
        assertEq(int256(_anchorOf(hook.cfWord(id))), (int256(100 * 256) * int256(f)) / int256(1 << 32));
    }

    function test_cf_decayFiveSeconds() public {
        uint256 w = _w(3_000, 3_000, 0, 50_000).withCfOn(true);
        uint256 cf = _cf(0, 256, 2_500, 0, 60, 1, uint40(NOW - 5), int32(-100 * 256));
        _fee(w, 0, cf, 0, address(1), false);
        (, uint256 cfNew) = FeeRef.cfStep(cf, 0, false, NOW);
        assertEq(hook.cfWord(id), cfNew);
        uint256 d1 = FeeRef.decay1Q32(60);
        uint256 b2 = (d1 * d1) >> 32;
        uint256 f = (d1 * ((b2 * b2) >> 32)) >> 32;
        assertEq(int256(_anchorOf(hook.cfWord(id))), (int256(-100 * 256) * int256(f)) / int256(1 << 32));
    }

    function test_cf_maxAgeSnapsAnchor() public {
        uint256 w = _w(3_000, 3_000, 0, 50_000).withCfOn(true);
        uint256 cf = _cf(0, 256, 2_500, 0, 300, 1, uint40(NOW - 255), int32(100 * 256));
        assertEq(_fee(w, 0, cf, 7, address(1), true), 3_000, "snapped: no surcharge");
        assertEq(int256(_anchorOf(hook.cfWord(id))), 7 * 256);
        cf = _cf(0, 256, 2_500, 0, 300, 1, uint40(NOW - 254), int32(100 * 256));
        _fee(w, 0, cf, 7, address(1), true);
        assertGt(int256(_anchorOf(hook.cfWord(id))), 7 * 256 + 2_000, "decayed, not snapped");
    }

    function test_cf_unchangedUpdateNotWritten() public {
        uint256 w = _w(3_000, 3_000, 0, 50_000).withCfOn(true);
        uint256 cf = _cf(0, 256, 2_500, 0, 60, 0, uint40(NOW), int32(500 * 256));
        hook.__setWord(id, w);
        hook.__setCF(id, cf);
        _setTick(id, 500);
        vm.record();
        assertEq(_swapFee(key, address(1), true), 3_000);
        (, bytes32[] memory writes) = vm.accesses(hookAddr);
        assertEq(writes.length, 0, "no SSTORE");
    }

    function test_cf_changedUpdateWrittenOnce() public {
        uint256 w = _w(3_000, 3_000, 0, 50_000).withCfOn(true);
        uint256 cf = _cf(0, 256, 2_500, 0, 60, 1, uint40(NOW - 10), int32(500 * 256));
        hook.__setWord(id, w);
        hook.__setCF(id, cf);
        _setTick(id, 400);
        (, uint256 cfNew) = FeeRef.cfStep(cf, 400, true, NOW);
        vm.record();
        _swapFee(key, address(1), true);
        (, bytes32[] memory writes) = vm.accesses(hookAddr);
        assertEq(writes.length, 1, "one SSTORE");
        assertEq(writes[0], _cfSlot());
        assertEq(hook.cfWord(id), cfNew);
        assertTrue(cfNew != cf);
    }

    function test_discountThenCf() public {
        address s = address(0xD15C);
        uint256 w = _listed(_w(3_000, 3_000, 0, 50_000), s, 9).withCfOn(true);
        uint256 cf = _cf(0, 256, 2_500, 0, 60, 10, uint40(NOW), 0);
        assertEq(_fee(w, DiscountLib.pack(2_000, 0, 3, uint40(NOW + 1_000)), cf, -10, s, true), 3_400);
        assertEq(uint256(FablesFeeFull(hookAddr).currentFee(id, true)), 4_000, "sender-free quote");
        assertEq(uint256(FablesFeeFull(hookAddr).feeFor(id, true, s)), 3_400, "sender quote");
    }
}
