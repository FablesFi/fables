// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import "../utils/StableTestBase.sol";
import {StableFeeCalculation} from "../../src/libraries/StableFeeCalculation.sol";

/// @notice Any-state differential: identical stored words give identical fees, reverts and state updates on StablePair,
///         the build under test and the typed twin. The state word's top 16 bits, unused by StablePair, are the Fables
///         minimum fee: the Fables builds charge max(StablePair's fee, it) on every swap. Beyond 10% from the reference
///         Fables floors the decay target at its value at 10%: where that floor binds, the two Fables builds still match
///         each other exactly and charge at least StablePair's capped fee, and the run stops comparing with StablePair.
abstract contract StableLiteDiffWordsBase is StableTestBase {
    using PoolIdLibrary for PoolKey;

    address spBN;
    address spArb;
    address[2] lites;
    address[2] typeds;

    uint256 constant M40 = 0xffffffffff;
    uint256 constant M160 = (uint256(1) << 160) - 1;
    uint256 constant MIN_FEE_PRICE_RATIO_X96 = 71305346262837903834189555302;

    /// Set once a swap wrote a floored decaying fee: StablePair's state no longer matches the Fables builds'.
    bool internal _diverged;

    /// True when the next fee on StablePair's words reads a target below its value at the 10% window edge (a new
    /// block, outside the band, price ratio < 0.9). External so that words StablePair's math reverts on read as false.
    function floorBinds(uint256 cfgW, uint256 stW, uint256 s0W, uint256 clock) external pure returns (bool) {
        uint256 ref = (cfgW >> 56) & M160;
        uint256 cached = (stW >> 40) & M160;
        if (!(clock > ((stW >> 200) & M40) || cached == 0)) return false;
        uint256 p = s0W & M160;
        if (ref == 0 || p == 0) return false;
        uint256 opt = (cfgW >> 24) & 0xffffff;
        uint256 tm = (cfgW >> 48) & 0xff;
        uint256 ratio = StableFeeCalculation.calculatePriceRatioX96(p, ref);
        if (ratio >= MIN_FEE_PRICE_RATIO_X96) return false;
        int256 close = StableFeeCalculation.calculateCloseBoundaryFee(ratio, opt);
        if (close <= 0) return false;
        uint256 target = StableFeeCalculation.calculateFarBoundaryFee(ratio, opt) - uint256(close) * tm / 100;
        uint256 edge = StableFeeCalculation.calculateFarBoundaryFee(MIN_FEE_PRICE_RATIO_X96, opt)
            - uint256(StableFeeCalculation.calculateCloseBoundaryFee(MIN_FEE_PRICE_RATIO_X96, opt)) * tm / 100;
        return target < edge;
    }

    function _floorBinds(address sp) internal view returns (bool) {
        (,, bytes32 pmSlot) = _slots(sp);
        uint256 clock = sp == spArb ? _arbClock() : block.number;
        try this.floorBinds(_cfgWord(sp), _stateWord(sp), uint256(vm.load(PM_ADDR, pmSlot)), clock) returns (bool b) {
            return b;
        } catch {
            return false;
        }
    }

    function _arbClock() internal view returns (uint256) {
        (bool ok, bytes memory ret) = address(0x64).staticcall(abi.encodeWithSelector(0xa3b1b31d));
        require(ok && ret.length == 32, "arbsys");
        return abi.decode(ret, (uint256));
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
        (bytes32 a, bytes32 b, bytes32 c) = _slots(h);
        vm.store(h, a, bytes32(cfgW));
        vm.store(h, b, bytes32(stW));
        vm.store(PM_ADDR, c, bytes32(s0W));
    }

    function _setPrice(address h, uint256 s0W) internal {
        (,, bytes32 c) = _slots(h);
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

    /// StablePair's fee, capped, then the Fables minimum fee from the state word's top 16 bits.
    function _fables(address sp, uint24 spFee) internal view returns (uint24) {
        uint24 f = _capped(spFee);
        uint256 m = _stateWord(sp) >> 240;
        return m > f ? uint24(m) : f;
    }

    function _cmpGetFee(address[3] memory P, string memory tag) internal view {
        if (_diverged || _floorBinds(P[0])) return _cmpGetFeeFloored(P, tag);
        (bool ok0, bytes memory r0) = _getFeeRaw(P[0], _keyOf(P[0]));
        if (ok0 && r0.length == 64) {
            (uint24 a, uint24 b) = abi.decode(r0, (uint24, uint24));
            r0 = abi.encode(_fables(P[0], a), _fables(P[0], b));
        }
        for (uint256 i = 1; i < 3; i++) {
            (bool ok, bytes memory ret) = _getFeeRaw(P[i], _keyOf(P[i]));
            if (ok != ok0 || keccak256(ret) != keccak256(r0)) _mismatch("getFee", tag, P[i], r0, ret);
        }
    }

    /// The floor binds (or StablePair's state no longer matches): the Fables builds match each other and, while
    /// StablePair's words still match, charge at least its capped fee (then the minimum).
    function _cmpGetFeeFloored(address[3] memory P, string memory tag) internal view {
        (bool ok1, bytes memory r1) = _getFeeRaw(P[1], _keyOf(P[1]));
        (bool ok2, bytes memory r2) = _getFeeRaw(P[2], _keyOf(P[2]));
        if (ok1 != ok2 || keccak256(r1) != keccak256(r2)) _mismatch("getFee (floored)", tag, P[2], r1, r2);
        if (_diverged) return;
        (bool ok0, bytes memory r0) = _getFeeRaw(P[0], _keyOf(P[0]));
        if (ok0 != ok1) _mismatch("getFee (floored) flag", tag, P[1], r0, r1);
        if (ok0 && r0.length == 64) _assertFeesGe(P[0], r0, r1, tag);
    }

    function _assertFeesGe(address sp, bytes memory r0, bytes memory r1, string memory tag) internal view {
        (uint24 a, uint24 b) = abi.decode(r0, (uint24, uint24));
        (uint24 x, uint24 y) = abi.decode(r1, (uint24, uint24));
        uint24 fa = _fables(sp, a);
        uint24 fb = _fables(sp, b);
        if (x < fa) revert(string.concat("floored getFee below StablePair 0for1 ", tag));
        if (y < fb) revert(string.concat("floored getFee below StablePair 1for0 ", tag));
    }

    function _cmpSwap(address[3] memory P, bool zfo, string memory tag) internal {
        if (_diverged || _floorBinds(P[0])) return _cmpSwapFloored(P, zfo, tag);
        uint256 cfgB = _cfgWord(P[0]);
        // the expected minimum is read before StablePair's swap writes its state (the top bits stay)
        uint256 m = _stateWord(P[0]) >> 240;
        (bool ok0, bytes memory r0) = _swapCall(P[0], zfo);
        if (ok0 && r0.length == 96) {
            (bytes4 sel, int256 delta, uint24 w) = abi.decode(r0, (bytes4, int256, uint24));
            uint24 f = _capped(w & 0x3fffff);
            if (m > f) f = uint24(m);
            r0 = abi.encode(sel, delta, (w & 0x400000) | f);
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

    /// Floored swap: the Fables builds match each other (return, state, config untouched); while StablePair's words
    /// still match, the fee is at least its capped fee (then the minimum); then the run leaves StablePair behind.
    function _cmpSwapFloored(address[3] memory P, bool zfo, string memory tag) internal {
        uint256 cfg1 = _cfgWord(P[1]);
        uint256 cfg2 = _cfgWord(P[2]);
        (bool ok1, bytes memory r1) = _swapCall(P[1], zfo);
        (bool ok2, bytes memory r2) = _swapCall(P[2], zfo);
        if (ok1 != ok2 || keccak256(r1) != keccak256(r2)) _mismatch("beforeSwap (floored)", tag, P[2], r1, r2);
        if (_stateWord(P[1]) != _stateWord(P[2])) revert(string.concat("state word mismatch (floored) ", tag));
        if (_cfgWord(P[1]) != cfg1 || _cfgWord(P[2]) != cfg2) {
            revert(string.concat("swap wrote the config word ", tag));
        }
        if (!_diverged) {
            uint256 m = _stateWord(P[0]) >> 240;
            (bool ok0, bytes memory r0) = _swapCall(P[0], zfo);
            if (ok0 != ok1) _mismatch("beforeSwap (floored) flag", tag, P[1], r0, r1);
            if (ok0 && r0.length == 96) _assertSwapFeeGe(r0, r1, m, tag);
            _diverged = true;
        }
    }

    function _assertSwapFeeGe(bytes memory r0, bytes memory r1, uint256 m, string memory tag) internal pure {
        (,, uint24 w0) = abi.decode(r0, (bytes4, int256, uint24));
        (,, uint24 w1) = abi.decode(r1, (bytes4, int256, uint24));
        uint24 f = _capped(w0 & 0x3fffff);
        if (m > f) f = uint24(m);
        if ((w1 & 0x3fffff) < f) revert(string.concat("floored fee below StablePair ", tag));
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
