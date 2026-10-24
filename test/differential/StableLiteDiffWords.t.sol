// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import "../utils/StableTestBase.sol";
import {StableFeeCalculation} from "../../src/libraries/StableFeeCalculation.sol";

/// @notice Any-state differential: identical stored words give identical fees, reverts and state updates on StablePair,
///         the build under test and the typed twin.
abstract contract StableLiteDiffWordsBase is StableTestBase {
    using PoolIdLibrary for PoolKey;

    address spBN;
    address spArb;
    address[2] lites;
    address[2] typeds;

    uint256 constant M40 = 0xffffffffff;
    uint256 constant M160 = (uint256(1) << 160) - 1;
    uint256 constant Q96 = 1 << 96;
    uint256 constant MIN_FEE_PRICE_RATIO_X96 = 71305346262837903834189555302;
    uint256 constant SQRT_MIN_FEE_PRICE_RATIO_X96 = 75162434512514379355924140470;

    function _win(uint256 p, uint256 ref) internal pure returns (uint256) {
        if (ref == 0) return 0;
        if (StableFeeCalculation.calculatePriceRatioX96(p, ref) >= MIN_FEE_PRICE_RATIO_X96) return p;
        return p < ref ? ref * SQRT_MIN_FEE_PRICE_RATIO_X96 / Q96 : ref * Q96 / SQRT_MIN_FEE_PRICE_RATIO_X96;
    }

    function _refOf(uint256 cfgW) internal pure returns (uint256) {
        return (cfgW >> 56) & M160;
    }

    function _winSlot0(uint256 s0W, uint256 cfgW) internal pure returns (uint256) {
        return (s0W & ~M160) | _win(s0W & M160, _refOf(cfgW));
    }

    function _winState(uint256 stW, uint256 cfgW) internal pure returns (uint256) {
        uint256 cached = (stW >> 40) & M160;
        if (cached == 0) return stW;
        return (stW & ~(M160 << 40)) | (_win(cached, _refOf(cfgW)) << 40);
    }

    function setUp() public {
        setUpChain();
        spBN = _deploySP("w-spbn");
        lites[0] = _deployLite("w-lite0");
        typeds[0] = _deployTyped("w-typed0");
        _etchArbSysSlot(0);
        spArb = _deploySP("w-sparb");
        lites[1] = _deployLite("w-lite1");
        typeds[1] = _deployTyped("w-typed1");
        assertFalse(FablesStableHookLite(lites[0]).USE_ARB_SYS());
        assertTrue(FablesStableHookLite(lites[1]).USE_ARB_SYS());
    }

    function _keyOf(address h) internal view returns (PoolKey memory) {
        return PoolKey(c0, c1, DYN, 1, IHooks(h));
    }

    function _isSP(address h) internal view returns (bool) {
        return h == spBN || h == spArb;
    }

    function _slots(address h) internal view returns (bytes32 cfgSlot, bytes32 stSlot, bytes32 pmSlot) {
        bytes32 id = PoolId.unwrap(_keyOf(h).toId());
        if (_isSP(h)) {
            cfgSlot = keccak256(abi.encode(id, SP_LOC));
            stSlot = keccak256(abi.encode(id, uint256(SP_LOC) + 1));
        } else {
            cfgSlot = _cfgSlot(PoolId.wrap(id));
            stSlot = _stateSlot(PoolId.wrap(id));
        }
        pmSlot = keccak256(abi.encode(id, uint256(6)));
    }

    function _put(address h, uint256 cfgW, uint256 stW, uint256 s0W) internal {
        stW = _winState(stW, cfgW);
        if (_isSP(h)) s0W = _winSlot0(s0W, cfgW);
        (bytes32 a, bytes32 b, bytes32 c) = _slots(h);
        vm.store(h, a, bytes32(cfgW));
        vm.store(h, b, bytes32(stW));
        vm.store(PM_ADDR, c, bytes32(s0W));
    }

    function _setPrice(address h, uint256 s0W) internal {
        (bytes32 a,, bytes32 c) = _slots(h);
        if (_isSP(h)) s0W = _winSlot0(s0W, uint256(vm.load(h, a)));
        vm.store(PM_ADDR, c, bytes32(s0W));
    }

    function _stateWord(address h) internal view returns (uint256) {
        (, bytes32 b,) = _slots(h);
        return uint256(vm.load(h, b));
    }

    function _cfgWord(address h) internal view returns (uint256) {
        (bytes32 a,,) = _slots(h);
        return uint256(vm.load(h, a));
    }

    function _swapCall(address h, bool zfo) internal returns (bool ok, bytes memory ret) {
        (ok, ret) = _beforeSwapCall(h, _keyOf(h), zfo, UR_ADDR);
    }

    function _clockSet(uint256 mode, uint256 c) internal {
        if (mode == 0) vm.roll(c);
        else _arbSet(c);
    }

    function testFuzz_anyWords(
        uint256 cfgW,
        uint256 stW,
        uint256 s0W,
        uint256 clockSeed,
        uint256 r,
        bool arbClock,
        bool zfo
    ) public {
        uint256 mode = arbClock ? 1 : 0;

        uint256 clock;
        if (r & 1 == 0) {
            (cfgW, stW, s0W, clock) = _realistic(cfgW, stW, s0W, clockSeed, r);
        } else if (r & 2 == 0) {
            uint256 blk = (stW >> 200) & M40;
            uint256 d = (r >> 8) % 12;
            clock = (r >> 16) & 1 == 0 ? blk + d : (blk > d ? blk - d : 0);
        } else {
            clock = clockSeed;
        }
        _clockSet(mode, clock);

        address[3] memory P = [mode == 0 ? spBN : spArb, lites[mode], typeds[mode]];
        for (uint256 i; i < 3; i++) {
            _put(P[i], cfgW, stW, s0W);
        }

        _cmpGetFee(P, "getFee#1");
        _cmpSwap(P, zfo, "swap#1");
        _cmpSwap(P, !zfo, "swap#2");
        _later(P, mode, clock, s0W, r, zfo);
    }

    function _later(address[3] memory P, uint256 mode, uint256 clock, uint256 s0W, uint256 r, bool zfo) internal {
        uint256 c2;
        unchecked {
            c2 = clock + (r >> 24) % 8;
        }
        _clockSet(mode, c2);
        uint256 s0W2 = (r >> 32) & 1 == 0 ? s0W : uint256(keccak256(abi.encode(s0W, r)));
        if ((r >> 33) & 1 == 0) {
            uint256 p = s0W & M160;
            uint256 bump = p / 1e5 * ((r >> 40) % 400);
            uint256 np = (r >> 34) & 1 == 0 ? p + bump : (p > bump ? p - bump : p);
            if (np >= TickMath.MAX_SQRT_PRICE) np = TickMath.MAX_SQRT_PRICE - 1;
            s0W2 = (s0W & ~M160) | np;
        }
        for (uint256 i; i < 3; i++) {
            _setPrice(P[i], s0W2);
        }
        _cmpGetFee(P, "getFee#2");
        _cmpSwap(P, zfo, "swap#3");
        _cmpSwap(P, (r >> 35) & 1 == 0, "swap#4");
    }

    function _mismatch(string memory what, string memory tag, address h, bytes memory r0, bytes memory ret)
        internal
        pure
    {
        console.log(what, tag, h);
        console.logBytes(r0);
        console.logBytes(ret);
        revert(string.concat(what, " mismatch ", tag));
    }

    function _cmpGetFee(address[3] memory P, string memory tag) internal view {
        (bool ok0, bytes memory r0) = _getFeeRaw(P[0], _keyOf(P[0]));
        if (ok0 && r0.length == 64) {
            (uint24 a, uint24 b) = abi.decode(r0, (uint24, uint24));
            r0 = abi.encode(_capped(a), _capped(b));
        }
        for (uint256 i = 1; i < 3; i++) {
            (bool ok, bytes memory ret) = _getFeeRaw(P[i], _keyOf(P[i]));
            if (ok != ok0 || keccak256(ret) != keccak256(r0)) _mismatch("getFee", tag, P[i], r0, ret);
        }
    }

    function _cmpSwap(address[3] memory P, bool zfo, string memory tag) internal {
        uint256 cfgB = _cfgWord(P[0]);
        (bool ok0, bytes memory r0) = _swapCall(P[0], zfo);
        if (ok0 && r0.length == 96) {
            (bytes4 sel, int256 delta, uint24 w) = abi.decode(r0, (bytes4, int256, uint24));
            r0 = abi.encode(sel, delta, (w & 0x400000) | _capped(w & 0x3fffff));
        }
        uint256 s0 = _stateWord(P[0]);
        if (_cfgWord(P[0]) != cfgB) revert(string.concat("swap wrote the config word ", tag));
        for (uint256 i = 1; i < 3; i++) {
            cfgB = _cfgWord(P[i]);
            (bool ok, bytes memory ret) = _swapCall(P[i], zfo);
            if (ok != ok0 || keccak256(ret) != keccak256(r0)) _mismatch("beforeSwap", tag, P[i], r0, ret);
            if (_stateWord(P[i]) != s0) revert(string.concat("state word mismatch ", tag));
            if (_cfgWord(P[i]) != cfgB) revert(string.concat("swap wrote the config word ", tag));
        }
        if (ok0 && r0.length != 96) revert("beforeSwap return is not 96 bytes");
    }

    function _realistic(uint256 cfgW, uint256 stW, uint256 s0W, uint256 clockSeed, uint256 r)
        internal
        pure
        returns (uint256 cfg, uint256 st, uint256 s0, uint256 clock)
    {
        uint256 ref;
        (cfg, ref) = _realCfg(cfgW, r);
        uint256 p;
        (s0, p) = _realPrice(ref, s0W);
        (st, clock) = _realState(p, stW, clockSeed);
    }

    function _realCfg(uint256 cfgW, uint256 r) internal pure returns (uint256 cfg, uint256 ref) {
        uint256 k = 1 + cfgW % ((1 << 24) - 1);
        if ((r >> 4) % 3 == 0) k = K07;
        uint256 opt = (cfgW >> 24) % 10_001;
        if ((r >> 6) % 4 == 0) opt = (r >> 6) % 8 == 0 ? 7 : 50;
        uint256 tm = (cfgW >> 48) % 101;
        if ((r >> 9) % 2 == 0) tm = 100;
        int24 t = int24(int256((cfgW >> 64) % 200_001) - 100_000);
        ref = TickMath.getSqrtPriceAtTick(t);
        ref = ref + (cfgW >> 100) % (ref / 1000 + 1);
        cfg = k | (opt << 24) | (tm << 48) | (ref << 56) | ((cfgW >> 216) << 216);
    }

    function _realPrice(uint256 ref, uint256 s0W) internal pure returns (uint256 s0, uint256 p) {
        uint256 e = (s0W >> 160) % 7;
        uint256 dev = (ref / (10 ** (7 - e))) * ((s0W >> 170) % 1000) / 1000;
        if ((s0W >> 180) % 8 == 0) dev = 0;
        p = (s0W >> 190) & 1 == 0 ? ref + dev : ref - dev;
        if (p >= TickMath.MAX_SQRT_PRICE) p = TickMath.MAX_SQRT_PRICE - 1;
        if (p < TickMath.MIN_SQRT_PRICE) p = TickMath.MIN_SQRT_PRICE;
        s0 = (s0W & ~M160) | p;
    }

    function _realState(uint256 p, uint256 stW, uint256 clockSeed) internal pure returns (uint256 st, uint256 clock) {
        uint256 dec = (stW % 4 == 0) ? UNDEF : (stW >> 2) % (1e12 + 1);
        uint256 sel = (stW >> 50) % 5;
        uint256 cached =
            sel == 0 ? 0 : (sel == 1 ? p : (p + (p / 1e5) * ((stW >> 60) % 300)) - (p / 1e5) * ((stW >> 80) % 300));
        if (cached >= TickMath.MAX_SQRT_PRICE) cached = TickMath.MAX_SQRT_PRICE - 1;
        uint256 blk = (clockSeed % 2_000_000_000) + 1000;
        uint256 g = (stW >> 100) % 8;
        uint256 gap = g < 5 ? g : (g == 5 ? 5 + (stW >> 110) % 100 : (g == 6 ? (stW >> 120) % 10_000_000 : 0));
        clock = g == 7 ? blk - (stW >> 130) % 1000 : blk + gap;
        st = (dec & M40) | (cached << 40) | ((blk & M40) << 200) | ((stW >> 240) << 240);
    }
}

/// @notice On FablesStableHookLite.
contract StableLiteDiffWordsTest is StableLiteDiffWordsBase {}

/// @notice On FablesStableHookLiteExclusive.
contract StableLiteDiffWordsExclusiveTest is StableLiteDiffWordsBase {
    function _exclusive() internal pure override returns (bool) {
        return true;
    }
}
