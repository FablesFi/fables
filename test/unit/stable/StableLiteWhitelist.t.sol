// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import "../../utils/StableTestBase.sol";
import {DiscountLib} from "../../../src/libraries/DiscountLib.sol";

/// @notice Whitelist discounts on a Stable Lite build through real swaps: exact quotes, never above the base fee, at
///         most 50% off.
abstract contract StableLiteWhitelistBase is StableTestBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    address lite;
    SeqSwapper[4] sws;

    struct W {
        uint256 seed;
        PoolKey k;
        PoolId id;
        uint256 swaps;
        uint256 discounted;
        uint256 zeroFee;
        bool[3] hidden;
    }

    function setUp() public {
        setUpChain();
        lite = _deployLite("wl-lite");
        for (uint256 i; i < 4; i++) {
            sws[i] = new SeqSwapper(pm);
            MockERC20(Currency.unwrap(c0)).mint(address(sws[i]), BIG);
            MockERC20(Currency.unwrap(c1)).mint(address(sws[i]), BIG);
        }
    }

    function _r(uint256 s, uint256 i) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(s, i, "wl")));
    }

    function _ids(PoolId id) internal pure returns (PoolId[] memory a) {
        a = new PoolId[](1);
        a[0] = id;
    }

    function testFuzz_whitelist(uint256 seed) public {
        W memory w;
        w.seed = seed;
        uint256 x = _r(seed, 0);
        uint160 ref = TickMath.getSqrtPriceAtTick(0);
        StableFeeConfig memory c = StableFeeConfig({
            k: K07,
            optimalFeeE6: x % 2 == 0 ? 50 : uint24((x >> 8) % 10_001),
            targetMultiplier: 100,
            referenceSqrtPriceX96: ref
        });
        uint160 p0 = (x >> 40) % 2 == 0 ? ref : uint160(uint256(ref) * 1000290 / 1000000);
        w.k = PoolKey(c0, c1, DYN, 1, IHooks(lite));
        w.id = w.k.toId();
        _createPool(lite, w.k, p0, c);
        int24[3] memory lo = [int24(-887272), int24(-20), int24(-3)];
        int24[3] memory hi = [int24(887272), int24(25), int24(4)];
        for (uint256 i; i < 3; i++) {
            _addLiq(lite, w.k, lo[i], hi[i], uint128(10 ** (21 + i)));
        }
        for (uint256 i; i < 3; i++) {
            _grant(w, i, _r(seed, 100 + i));
        }
        for (uint256 s = 1; s <= 40; s++) {
            _step(w, c, _r(seed, s));
        }
    }

    function _step(W memory w, StableFeeConfig memory c, uint256 y) internal {
        uint256 a = y % 100;
        if (a < 58) _swap(w, y);
        else if (a < 76) vm.roll(block.number + (y >> 8) % 6);
        else if (a < 83) vm.warp(block.timestamp + (y >> 8) % 3 days);
        else if (a < 89) _grant(w, (y >> 8) % 3, y >> 16);
        else if (a < 91) _delete(w, (y >> 8) % 3);
        else if (a < 93) _revoke(w, (y >> 8) % 3);
        else if (a < 97) _reseed(w, y);
        else _cfgUpdate(w, c, y);
    }

    function _grant(W memory w, uint256 i, uint256 y) internal {
        uint16 bps = uint16(1 + y % 5000);
        uint24 minFee = (y >> 16) % 3 == 0 ? uint24((y >> 20) % 80) : 0;
        uint8 dirs = uint8(1 + (y >> 40) % 3);
        uint40 expiry = uint40(block.timestamp + 1 hours + (y >> 48) % 20 days);
        FablesStableHookLite(lite).setDiscount(_ids(w.id), address(sws[i]), bps, minFee, dirs, expiry);
        (uint16 b, uint24 m, uint8 d, uint40 e) = FablesStableHookLite(lite).discountOf(w.id, address(sws[i]));
        require(b == bps && m == minFee && d == dirs && e == expiry, "entry stored");
        w.hidden[i] = false;
    }

    function _delete(W memory w, uint256 i) internal {
        FablesStableHookLite(lite).setDiscount(_ids(w.id), address(sws[i]), 0, 0, 1, 0);
        (uint16 b,,,) = FablesStableHookLite(lite).discountOf(w.id, address(sws[i]));
        require(b == 0, "entry deleted");
    }

    function _revoke(W memory w, uint256 i) internal {
        address[] memory acc = new address[](1);
        acc[0] = address(sws[i]);
        FablesStableHookLite(lite).revokeDiscount(_ids(w.id), acc);
        (uint16 b,,,) = FablesStableHookLite(lite).discountOf(w.id, address(sws[i]));
        require(b == 0, "entry revoked");
    }

    function _reseed(W memory w, uint256 y) internal {
        uint8 seedB = uint8(y >> 8);
        uint256 sel = (y >> 16) % 3;
        address[] memory acc;
        if (sel == 0) {
            acc = new address[](3);
            for (uint256 i; i < 3; i++) {
                acc[i] = address(sws[i]);
                w.hidden[i] = false;
            }
        } else if (sel == 1) {
            uint256 out = (y >> 24) % 3;
            acc = new address[](2);
            uint256 n;
            for (uint256 i; i < 3; i++) {
                if (i == out) {
                    w.hidden[i] = true;
                } else {
                    acc[n++] = address(sws[i]);
                    w.hidden[i] = false;
                }
            }
        } else {
            acc = new address[](2);
            acc[0] = address(sws[3]);
            acc[1] = address(uint160(y));
            for (uint256 i; i < 3; i++) {
                w.hidden[i] = true;
            }
        }
        FablesStableHookLite(lite).setDiscountFilter(w.id, seedB, acc);
        (uint8 s, uint32 bloom) = FablesStableHookLite(lite).discountFilter(w.id);
        require(s == seedB, "seed stored");
        uint32 expect;
        for (uint256 i; i < acc.length; i++) {
            (uint16 b,,,) = FablesStableHookLite(lite).discountOf(w.id, acc[i]);
            if (b != 0) expect |= DiscountLib.mask32(acc[i], seedB);
        }
        require(bloom == expect, "filter != OR of listed entries' masks");
    }

    function _cfgUpdate(W memory w, StableFeeConfig memory c, uint256 y) internal {
        (uint8 s0, uint32 b0) = FablesStableHookLite(lite).discountFilter(w.id);
        StableFeeConfig memory c2 = c;
        c2.optimalFeeE6 = uint24((y >> 8) % 10_001);
        c2.targetMultiplier = uint8(1 + (y >> 24) % 100);
        _updateConfig(lite, w.k, c2);
        (uint8 s1, uint32 b1) = FablesStableHookLite(lite).discountFilter(w.id);
        require(b0 == b1 && s0 == s1, "config update touched the Bloom");
        (uint24 k, uint24 o, uint8 tm, uint160 ref) = FablesStableHookLite(lite).feeConfig(w.id);
        require(
            k == c2.k && o == c2.optimalFeeE6 && tm == c2.targetMultiplier && ref == c2.referenceSqrtPriceX96, "cfg"
        );
        (uint40 dec, uint160 cached,) = FablesStableHookLite(lite).feeState(w.id);
        require(dec == uint40(UNDEF) && cached == 0, "state reset");
    }

    function _fee(PoolId id, SeqSwapper s, PoolKey memory k, bool zfo, int256 amt) internal returns (bool, uint24) {
        vm.recordLogs();
        (bool ok,) = s.swap(k, zfo, amt, zfo ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1);
        if (!ok) return (false, 0);
        (bool found, uint24 f) = _swapEventFee(vm.getRecordedLogs(), id);
        require(found, "no Swap event");
        return (true, f);
    }

    struct S {
        uint256 who;
        bool zfo;
        int256 amt;
        uint24 g;
        uint24 q;
        bool okU;
        uint24 fU;
        bool ok;
        uint24 f;
        uint256 entry;
        bool hidden;
    }

    function _swap(W memory w, uint256 y) internal {
        S memory t;
        t.who = (y >> 8) % 4;
        t.zfo = (y >> 16) & 1 == 0;
        t.amt = -int256(1e15 + (y >> 24) % 1e20);
        (uint24 g0, uint24 g1) = _getFee(lite, w.k);
        t.g = t.zfo ? g0 : g1;
        t.q = FablesStableHookLite(lite).feeFor(w.k, t.zfo, address(sws[t.who]));
        (uint16 b, uint24 m, uint8 d, uint40 e) = FablesStableHookLite(lite).discountOf(w.id, address(sws[t.who]));
        t.entry = DiscountLib.pack(b, m, d, e);
        t.hidden = t.who < 3 && w.hidden[t.who];
        uint256 snap = vm.snapshotState();
        (t.okU, t.fU) = _fee(w.id, sws[3], w.k, t.zfo, t.amt);
        vm.revertToState(snap);
        (t.ok, t.f) = _fee(w.id, sws[t.who], w.k, t.zfo, t.amt);
        _check(w, t);
    }

    function _check(W memory w, S memory t) internal view {
        require(t.ok == t.okU, "outcome differs");
        if (!t.ok) return;
        require(t.fU == t.g, "unlisted fee != getFee");
        require(t.f == t.q, "swap fee != feeFor quote");
        require(t.f <= t.g, "discount raised the fee");
        if (t.g == 0) require(t.f == 0, "0 fee not kept");
        require(uint256(t.f) * 2 >= t.g, "discount > 50%");
        if (t.who == 3) require(t.f == t.g, "unlisted executor discounted");
        uint256 expect = t.g;
        if ((!t.hidden || _bloomPasses(w.id, t.who)) && DiscountLib.isLive(t.entry, t.zfo, block.timestamp)) {
            expect = DiscountLib.applyEntry(t.g, 0, t.entry, t.zfo, block.timestamp);
        }
        require(t.f == expect, "fee != entry-derived expectation");
        w.swaps++;
        if (t.f < t.g) w.discounted++;
        if (t.g == 0) w.zeroFee++;
    }

    function _bloomPasses(PoolId id, uint256 who) internal view returns (bool) {
        (uint8 seedB, uint32 bloom) = FablesStableHookLite(lite).discountFilter(id);
        uint32 m = DiscountLib.mask32(address(sws[who]), seedB);
        return bloom & m == m;
    }

    function test_discountNeverRaises_zeroStaysZero_fiftyPercentFloor() public {
        PoolKey memory k = PoolKey(c0, c1, DYN, 1, IHooks(lite));
        (StableFeeConfig memory c, uint160 p0) = _cfgOut();
        _createPool(lite, k, p0, c);
        _addLiq(lite, k, -887272, 887272, 1e24);
        PoolId id = k.toId();
        FablesStableHookLite(lite).setDiscount(_ids(id), address(sws[0]), 5000, 0, 3, uint40(block.timestamp + 1 days));
        (uint24 g0, uint24 g1) = _getFee(lite, k);
        assertGt(g0, 0);
        assertEq(g1, 0);
        uint24 q0 = FablesStableHookLite(lite).feeFor(k, true, address(sws[0]));
        uint24 q1 = FablesStableHookLite(lite).feeFor(k, false, address(sws[0]));
        assertEq(q0, (uint256(g0) + 1) / 2, "50% off rounds UP");
        assertEq(q1, 0, "0 stays 0");
        FablesStableHookLite(lite)
            .setDiscount(_ids(id), address(sws[1]), 5000, g0 - 1, 3, uint40(block.timestamp + 1 days));
        assertEq(FablesStableHookLite(lite).feeFor(k, true, address(sws[1])), g0 - 1, "minFee binds");
        FablesStableHookLite(lite)
            .setDiscount(_ids(id), address(sws[2]), 5000, g0 + 100, 3, uint40(block.timestamp + 1 days));
        assertEq(FablesStableHookLite(lite).feeFor(k, true, address(sws[2])), g0, "minFee above the fee never raises");
        FablesStableHookLite(lite).setDiscount(_ids(id), address(sws[0]), 3000, 0, 1, uint40(block.timestamp + 1 days));
        assertLt(FablesStableHookLite(lite).feeFor(k, true, address(sws[0])), g0);
        vm.warp(block.timestamp + 1 days);
        assertEq(FablesStableHookLite(lite).feeFor(k, true, address(sws[0])), g0, "expired at expiry");
    }
}

/// @notice On FablesStableHookLite.
contract StableLiteWhitelistTest is StableLiteWhitelistBase {}

/// @notice On FablesStableHookLiteExclusive.
contract StableLiteWhitelistExclusiveTest is StableLiteWhitelistBase {
    function _exclusive() internal pure override returns (bool) {
        return true;
    }
}
