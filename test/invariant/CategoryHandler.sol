// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {FablesFeeEngine} from "../../src/base/FablesFeeEngine.sol";
import {FablesFeeFull} from "../../src/base/FablesFeeFull.sol";
import {FablesLedgerV2} from "../../src/base/FablesLedgerV2.sol";
import {PoolWordLib} from "../../src/libraries/PoolWordLib.sol";
import {DiscountLib} from "../../src/libraries/DiscountLib.sol";
import {FeeRef} from "../../src/libraries/FeeRef.sol";
import {CategoryTable} from "../utils/CategoryTable.sol";

/// @notice Random walk over a FablesHook build with five category pools: configure, pokes, discounts, CF, swaps,
///         deposits, withdrawals and claims, with predicted outcomes.
contract CategoryHandler is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using PoolWordLib for uint256;
    using CurrencyLibrary for Currency;

    bytes32 internal constant SWAP_TOPIC =
        keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");
    bytes4 internal constant PRICE_LIMIT_EXCEEDED = bytes4(keccak256("PriceLimitAlreadyExceeded(uint160,uint160)"));
    uint256 internal constant NPOOLS = 5;
    uint256 internal constant NRANGES = 2;
    uint256 internal constant NACTORS = 3;
    uint256 internal constant NROUTERS = 3;
    uint256 internal constant Q128 = 1 << 128;

    IPoolManager public immutable manager;
    address public immutable hook;
    bool public immutable eth;

    PoolSwapTest[NROUTERS] public routers;
    PoolKey[NPOOLS] internal keys;
    PoolId[NPOOLS] public ids;
    address[NACTORS] public actors;
    int24[NRANGES] public lowers = [int24(-600), int24(-3000)];
    int24[NRANGES] public uppers = [int24(600), int24(3000)];

    uint256[NPOOLS] public gLastRaiseAt;

    uint256 public violations;
    string public firstViolation;

    mapping(bytes32 => uint256) public landed;
    mapping(bytes32 => uint256) public refused;
    uint256 public swapsWithDiscount;
    uint256 public swapsWithCF;
    uint256 public swapsWithLivePoke;
    uint256 public raisesLanded;
    uint256 public maxChargedFee;

    constructor(
        IPoolManager manager_,
        address hook_,
        bool eth_,
        PoolKey[NPOOLS] memory keys_,
        address[NACTORS] memory actors_
    ) {
        manager = manager_;
        hook = hook_;
        eth = eth_;
        for (uint256 i = 0; i < NPOOLS; ++i) {
            keys[i] = keys_[i];
            ids[i] = keys_[i].toId();
        }
        actors = actors_;
        for (uint256 i = 0; i < NROUTERS; ++i) {
            routers[i] = new PoolSwapTest(manager_);
        }
    }

    receive() external payable {}

    function wire() external {
        for (uint256 j = 0; j < 2; ++j) {
            Currency c = j == 0 ? keys[0].currency0 : keys[0].currency1;
            if (c.isAddressZero()) continue;
            IERC20 t = IERC20(Currency.unwrap(c));
            for (uint256 i = 0; i < NROUTERS; ++i) {
                t.approve(address(routers[i]), type(uint256).max);
            }
            for (uint256 a = 0; a < NACTORS; ++a) {
                vm.prank(actors[a]);
                t.approve(hook, type(uint256).max);
            }
        }
    }

    function fuzzSelectors() external pure returns (bytes4[] memory s) {
        s = new bytes4[](17);
        uint256 n;
        s[n++] = this.configure.selector;
        s[n++] = this.poke.selector;
        s[n++] = this.pokeRaise.selector;
        s[n++] = this.clearPoke.selector;
        s[n++] = this.swap.selector;
        s[n++] = this.swapSmall.selector;
        s[n++] = this.swapLarge.selector;
        s[n++] = this.deposit.selector;
        s[n++] = this.withdraw.selector;
        s[n++] = this.claim.selector;
        s[n++] = this.warp.selector;
        s[n++] = this.warpShort.selector;
        s[n++] = this.discountGrant.selector;
        s[n++] = this.discountRevoke.selector;
        s[n++] = this.discountFilter.selector;
        s[n++] = this.cfConfigure.selector;
        s[n++] = this.cfSwitch.selector;
    }

    uint256 public budget = type(uint256).max;
    uint256 public stepsDone;
    bool public noop;

    modifier budgeted() {
        if (stepsDone >= budget) {
            noop = true;
            return;
        }
        noop = false;
        ++stepsDone;
        _;
    }

    function setBudget(uint256 b) external {
        budget = b;
        stepsDone = 0;
        noop = false;
    }

    function _engine() internal view returns (FablesFeeEngine) {
        return FablesFeeEngine(hook);
    }

    function _ledger() internal view returns (FablesLedgerV2) {
        return FablesLedgerV2(payable(hook));
    }

    function _cat(uint256 p) internal pure returns (CategoryTable.Cat memory) {
        return CategoryTable.get(uint8(p + 1));
    }

    function _violate(string memory why) internal {
        if (violations == 0) firstViolation = why;
        violations++;
        emit log_named_string("VIOLATION", why);
    }

    function _sel(bytes memory err) internal pure returns (bytes4 s) {
        if (err.length >= 4) {
            assembly ("memory-safe") {
                s := mload(add(err, 0x20))
            }
        }
    }

    function _outcome(bytes32 name, bool predicted, bool ok, bytes memory err, bytes4 expected) internal {
        if (ok) landed[name]++;
        else refused[name]++;
        if (ok && !predicted) _violate(string.concat(_s(name), ": landed but the design refuses it"));
        if (!ok && predicted) {
            _violate(string.concat(_s(name), ": refused but the design accepts it: ", vm.toString(err)));
        }
        if (!ok && !predicted && expected != bytes4(0) && _sel(err) != expected) {
            _violate(string.concat(_s(name), ": refused with an unexpected error: ", vm.toString(err)));
        }
    }

    function _s(bytes32 b) internal pure returns (string memory) {
        uint256 n;
        while (n < 32 && b[n] != 0) n++;
        bytes memory out = new bytes(n);
        for (uint256 i = 0; i < n; ++i) {
            out[i] = b[i];
        }
        return string(out);
    }

    function _now() internal view returns (uint256) {
        return block.timestamp;
    }

    struct Cfg {
        uint24 b0;
        uint24 b1;
        uint24 fl;
        uint24 cap;
    }

    function configure(uint256 p, uint24 b0, uint24 b1, uint24 fl, uint24 cap, uint8 mode) external budgeted {
        p %= NPOOLS;
        _configure(p, _shapeCfg(p, Cfg(b0, b1, fl, cap), mode));
    }

    function _shapeCfg(uint256 p, Cfg memory g, uint8 mode) internal pure returns (Cfg memory) {
        CategoryTable.Cat memory c = _cat(p);
        if (mode % 4 != 0) {
            uint24 capLo = c.floorMin > 1 ? c.floorMin : 1;
            g.cap = uint24(bound(g.cap, capLo, c.capMax));
            g.fl = uint24(bound(g.fl, c.floorMin, g.cap));
            g.b0 = uint24(bound(g.b0, g.fl, g.cap));
            g.b1 = uint24(bound(g.b1, g.fl, g.cap));
        } else {
            g.b0 = uint24(bound(g.b0, 0, 120_000));
            g.b1 = uint24(bound(g.b1, 0, 120_000));
            g.fl = uint24(bound(g.fl, 0, 120_000));
            g.cap = uint24(bound(g.cap, 0, 120_000));
        }
        return g;
    }

    function _cfgOk(uint256 p, Cfg memory g) internal pure returns (bool) {
        CategoryTable.Cat memory c = _cat(p);
        uint24 lo = g.b0 < g.b1 ? g.b0 : g.b1;
        uint24 hi = g.b0 < g.b1 ? g.b1 : g.b0;
        return g.cap != 0 && g.cap <= c.capMax && hi <= g.cap && g.fl >= c.floorMin && g.fl <= lo;
    }

    function _configure(uint256 p, Cfg memory g) internal {
        bytes4 expected = FablesFeeEngine.InvalidConfig.selector;
        uint256 wBefore = _engine().poolWord(ids[p]);
        bytes memory cd =
            abi.encodeCall(FablesFeeEngine.configurePool, (keys[p], uint8(p + 1), g.b0, g.b1, g.fl, g.cap));
        (bool landed_, bytes memory err) = _callHook(cd);
        _outcome("configure", _cfgOk(p, g), landed_, err, expected);
        if (!landed_) return;
        uint256 w = _engine().poolWord(ids[p]);
        if (w.base0() != g.b0 || w.base1() != g.b1 || w.floor() != g.fl || w.cap() != g.cap) {
            _violate("configure: word fields != the configured values");
        }
        if ((w ^ wBefore) & ~(PoolWordLib.BASES_MASK | PoolWordLib.BOUNDS_MASK) != 0) {
            _violate("configure: touched a field outside bases / bounds");
        }
        if (_engine().maxFee(ids[p]) != g.cap) _violate("configure: maxFee != cap");
    }

    struct PokeIn {
        uint24 f0;
        uint24 f1;
        uint40 ttl;
    }

    function poke(uint256 p, uint24 f0, uint24 f1, uint40 ttl, uint8 mode) external budgeted {
        p %= NPOOLS;
        mode %= 3;
        PokeIn memory q = mode == 0
            ? PokeIn(uint24(bound(f0, 0, 120_000)), uint24(bound(f1, 0, 120_000)), uint40(bound(ttl, 0, 80 hours)))
            : _inBoundsPoke(p, f0, f1, ttl, mode == 2);
        _poke(p, q);
    }

    /// A poke inside [floor, ceiling]; `oneSide` zeroes one side (picked by `f0`'s parity).
    function _inBoundsPoke(uint256 p, uint24 f0, uint24 f1, uint40 ttl, bool oneSide)
        internal
        view
        returns (PokeIn memory q)
    {
        uint256 w = _engine().poolWord(ids[p]);
        uint256 lo = w.floor() > 0 ? w.floor() : 1;
        uint256 ceiling = _ceiling(p, w);
        uint256 hi = ceiling < 1 ? 1 : ceiling;
        q.f0 = uint24(bound(f0, lo, hi));
        q.f1 = uint24(bound(f1, lo, hi));
        if (oneSide) {
            if (f0 % 2 == 0) q.f0 = 0;
            else q.f1 = 0;
        }
        q.ttl = uint40(bound(ttl, 1, 72 hours));
    }

    function pokeRaise(uint256 p, uint24 d0, uint24 d1, uint40 ttl) external budgeted {
        p %= NPOOLS;
        uint256 w = _engine().poolWord(ids[p]);
        uint256 step = _cat(p).raiseStep;
        uint256 ceiling = _ceiling(p, w);
        PokeIn memory q;
        uint256 k0 = FeeRef.keeperFee(w, true, _now()) + bound(d0, 0, step + step / 4);
        uint256 k1 = FeeRef.keeperFee(w, false, _now()) + bound(d1, 0, step + step / 4);
        q.f0 = uint24(k0 > ceiling ? ceiling : k0);
        q.f1 = uint24(k1 > ceiling ? ceiling : k1);
        if (q.f0 == 0) q.f0 = 1;
        if (q.f1 == 0) q.f1 = 1;
        q.ttl = uint40(bound(ttl, 1, 72 hours));
        _poke(p, q);
    }

    function _ceiling(uint256 p, uint256 w) internal pure returns (uint256) {
        uint256 cm = _cat(p).capMax;
        return w.cap() < cm ? w.cap() : cm;
    }

    function _poke(uint256 p, PokeIn memory q) internal {
        uint256 w = _engine().poolWord(ids[p]);
        (bool ok, bytes4 expected, bool raises) = _predictPoke(p, w, q);
        bytes memory cd = abi.encodeCall(FablesFeeEngine.pokeFee, (ids[p], q.f0, q.f1, q.ttl));
        (bool landed_, bytes memory err) = _callHook(cd);
        _outcome("poke", ok, landed_, err, expected);
        if (!landed_) return;
        uint256 wNew = _engine().poolWord(ids[p]);
        if (wNew.poke0() != q.f0 || wNew.poke1() != q.f1 || wNew.expiry() != _now() + q.ttl) {
            _violate("poke: stored poke != the poke sent");
        }
        if ((wNew ^ w) & ~PoolWordLib.POKES_MASK != 0) _violate("poke: touched a field outside the pokes");
        bool raised = _checkRaise(p, w, wNew);
        if (raised != raises) _violate("poke: raise classification differs from the prediction");
    }

    function _checkRaise(uint256 p, uint256 w, uint256 wNew) internal returns (bool raised) {
        uint256 step = _cat(p).raiseStep;
        for (uint256 s = 0; s < 2; ++s) {
            uint256 before = FeeRef.keeperFee(w, s == 0, _now());
            uint256 after_ = FeeRef.keeperFee(wNew, s == 0, _now());
            if (after_ > before) {
                raised = true;
                if (after_ - before > step) _violate("poke: a side was raised by more than the category step");
            }
        }
        if (raised) {
            if (_now() < gLastRaiseAt[p] + 60) _violate("poke: two raises inside a minute");
            gLastRaiseAt[p] = _now();
            raisesLanded++;
        }
    }

    function _predictPoke(uint256 p, uint256 w, PokeIn memory q)
        internal
        view
        returns (bool ok, bytes4 expected, bool raises)
    {
        uint256 ceiling = _ceiling(p, w);
        if (q.f0 == 0 && q.f1 == 0) return (false, FablesFeeEngine.EmptyPoke.selector, false);
        if (q.ttl == 0 || q.ttl > 72 hours) return (false, FablesFeeEngine.InvalidTtl.selector, false);
        if (q.f0 != 0 && q.f0 > ceiling) return (false, FablesFeeEngine.FeeAboveCap.selector, false);
        if (q.f0 != 0 && q.f0 < w.floor()) return (false, FablesFeeEngine.FeeBelowFloor.selector, false);
        if (q.f1 != 0 && q.f1 > ceiling) return (false, FablesFeeEngine.FeeAboveCap.selector, false);
        if (q.f1 != 0 && q.f1 < w.floor()) return (false, FablesFeeEngine.FeeBelowFloor.selector, false);
        uint256 wNew = w.withPokes(q.f0, q.f1, uint40(_now() + q.ttl));
        uint256 step = _cat(p).raiseStep;
        for (uint256 s = 0; s < 2; ++s) {
            uint256 before = FeeRef.keeperFee(w, s == 0, _now());
            uint256 after_ = FeeRef.keeperFee(wNew, s == 0, _now());
            if (after_ > before) {
                if (after_ - before > step) return (false, FablesFeeEngine.RaiseTooLarge.selector, true);
                raises = true;
            }
        }
        if (raises && _now() < gLastRaiseAt[p] + 60) {
            return (false, FablesFeeEngine.RaiseTooSoon.selector, true);
        }
        return (true, bytes4(0), raises);
    }

    function clearPoke(uint256 p) external budgeted {
        p %= NPOOLS;
        uint256 w = _engine().poolWord(ids[p]);
        (bool landed_, bytes memory err) = _callHook(abi.encodeCall(FablesFeeEngine.clearPoke, (ids[p])));
        _outcome("clearPoke", true, landed_, err, bytes4(0));
        if (!landed_) return;
        uint256 wNew = _engine().poolWord(ids[p]);
        if (wNew != w.withPokesCleared()) _violate("clearPoke: word != the word with the pokes cleared");
    }

    struct DiscIn {
        uint16 bps;
        uint24 minFee;
        uint8 dirs;
        uint40 term;
        uint8 mode;
    }

    function discountGrant(uint256 p, uint256 r, DiscIn memory d) external budgeted {
        p %= NPOOLS;
        address desk = address(routers[r % NROUTERS]);
        uint40 expiry = _shapeDisc(d);
        bool ok = d.bps <= 5_000
            && (d.bps == 0 || (d.dirs >= 1 && d.dirs <= 3 && expiry > _now() && expiry <= _now() + 90 days));
        PoolId[] memory one = new PoolId[](1);
        one[0] = ids[p];
        bytes memory cd = abi.encodeCall(FablesFeeEngine.setDiscount, (one, desk, d.bps, d.minFee, d.dirs, expiry));
        (bool landed_, bytes memory err) = _callHook(cd);
        _outcome("discountGrant", ok, landed_, err, FablesFeeEngine.InvalidDiscount.selector);
        if (landed_ && d.bps != 0) _checkInFilter(p, desk);
    }

    function _shapeDisc(DiscIn memory d) internal view returns (uint40 expiry) {
        if (d.mode % 4 != 0) {
            d.bps = uint16(bound(d.bps, 1, 5_000));
            d.dirs = uint8(bound(d.dirs, 1, 3));
            d.minFee = uint24(bound(d.minFee, 0, 20_000));
            expiry = uint40(_now() + bound(d.term, 1, 90 days));
        } else {
            d.bps = uint16(bound(d.bps, 0, 6_000));
            d.dirs = uint8(bound(d.dirs, 0, 4));
            expiry = uint40(bound(d.term, 0, _now() + 100 days));
        }
    }

    function _checkInFilter(uint256 p, address desk) internal {
        uint256 w = _engine().poolWord(ids[p]);
        if (!DiscountLib.hit64(w.bloom(), desk, w.seed())) {
            _violate("discountGrant: the granted desk misses the Bloom");
        }
    }

    function discountRevoke(uint256 p, uint256 r, bool viaDelete) external budgeted {
        p %= NPOOLS;
        address desk = address(routers[r % NROUTERS]);
        PoolId[] memory one = new PoolId[](1);
        one[0] = ids[p];
        bytes memory cd;
        if (viaDelete) {
            cd = abi.encodeCall(FablesFeeEngine.setDiscount, (one, desk, uint16(0), uint24(0), uint8(0), uint40(0)));
        } else {
            address[] memory who = new address[](1);
            who[0] = desk;
            cd = abi.encodeCall(FablesFeeEngine.revokeDiscount, (one, who));
        }
        (bool landed_, bytes memory err) = _callHook(cd);
        _outcome("discountRevoke", true, landed_, err, bytes4(0));
        if (landed_ && _engine().discountOf(ids[p], desk).bps != 0) _violate("discountRevoke: entry survived");
    }

    function discountFilter(uint256 p, uint8 seed, uint8 subset) external budgeted {
        p %= NPOOLS;
        if (subset % 5 != 0) seed &= 0x7f;
        address[] memory list = new address[](NROUTERS);
        uint256 n;
        for (uint256 i = 0; i < NROUTERS; ++i) {
            if ((subset >> i) & 1 == 1) list[n++] = address(routers[i]);
        }
        assembly ("memory-safe") {
            mstore(list, n)
        }
        (bool landed_, bytes memory err) =
            _callHook(abi.encodeCall(FablesFeeEngine.setDiscountFilter, (ids[p], seed, list)));
        _outcome("discountFilter", seed <= 0x7f, landed_, err, FablesFeeEngine.InvalidSeed.selector);
        if (!landed_) return;
        uint256 w = _engine().poolWord(ids[p]);
        if (w.seed() != seed) _violate("discountFilter: seed not stored");
        for (uint256 i = 0; i < n; ++i) {
            if (_engine().discountOf(ids[p], list[i]).bps != 0 && !DiscountLib.hit64(w.bloom(), list[i], seed)) {
                _violate("discountFilter: a listed holder misses the rebuilt filter");
            }
        }
    }

    struct CFIn {
        uint8 mode;
        uint16 k;
        uint24 cfCap;
        uint16 band;
        uint16 tau;
        uint8 period;
    }

    function cfConfigure(uint256 p, CFIn memory c, uint8 shape) external budgeted {
        p %= NPOOLS;
        if (shape % 4 != 0) {
            c.mode = uint8(bound(c.mode, 0, 1));
            c.k = uint16(bound(c.k, 1, 256));
            c.cfCap = uint24(bound(c.cfCap, 1, 2_500));
            c.band = uint16(bound(c.band, 0, 800));
            c.tau = uint16(bound(c.tau, 5, 300));
            c.period = uint8(bound(c.period, 1, 60));
        }
        bool on = _engine().poolWord(ids[p]).cfOn();
        bool ok = !on && c.mode <= 1 && c.k != 0 && c.k <= 256 && c.cfCap != 0 && c.cfCap <= 2_500 && c.band <= 800
            && c.tau >= 5 && c.tau <= 300 && c.period != 0 && c.period <= 60 && uint256(c.period) < _maxAge(c.tau);
        (bool landed_, bytes memory err) = _callHook(
            abi.encodeCall(FablesFeeEngine.configureCF, (ids[p], c.mode, c.k, c.cfCap, c.band, c.tau, c.period))
        );
        _outcome(
            "cfConfigure", ok, landed_, err, on ? FablesFeeEngine.CFActive.selector : FablesFeeEngine.InvalidCF.selector
        );
    }

    function _maxAge(uint16 tau) internal pure returns (uint256) {
        uint256 m = 5 * uint256(tau);
        return m > 255 ? 255 : m;
    }

    function cfSwitch(uint256 p, uint8 what) external budgeted {
        p %= NPOOLS;
        what %= 3;
        if (what == 2) {
            (bool l2, bytes memory e2) = _callHook(abi.encodeCall(FablesFeeEngine.killCF, (ids[p])));
            _outcome("cfKill", true, l2, e2, bytes4(0));
            if (l2 && (_engine().poolWord(ids[p]).cfOn() || FeeRef.cfK(FablesFeeFull(hook).cfWord(ids[p])) != 0)) {
                _violate("cfKill: CF still on or slope not zeroed");
            }
            return;
        }
        bool on = what == 1;
        bool ok = !on || FeeRef.cfK(FablesFeeFull(hook).cfWord(ids[p])) != 0;
        (bool landed_, bytes memory err) = _callHook(abi.encodeCall(FablesFeeEngine.setCFActive, (ids[p], on)));
        _outcome("cfSwitch", ok, landed_, err, FablesFeeEngine.CFNotConfigured.selector);
        if (landed_ && _engine().poolWord(ids[p]).cfOn() != on) _violate("cfSwitch: cfOn not stored");
    }

    function swap(uint256 p, uint256 r, bool z, uint256 amt, bool exactOut) external budgeted {
        _swap(p, r, z, bound(amt, 1e12, 1e21), exactOut);
    }

    function swapSmall(uint256 p, uint256 r, bool z, uint256 amt, bool exactOut) external budgeted {
        _swap(p, r, z, bound(amt, 1, 1e9), exactOut);
    }

    function swapLarge(uint256 p, uint256 r, bool z, uint256 amt, bool exactOut) external budgeted {
        _swap(p, r, z, bound(amt, 1e21, 5e23), exactOut);
    }

    struct SwapCtx {
        uint256 p;
        address desk;
        bool z;
        uint256 w;
        uint256 expected;
        uint256 senderFree;
        bool discounted;
    }

    function _swap(uint256 p, uint256 r, bool z, uint256 amt, bool exactOut) internal {
        SwapCtx memory x;
        x.p = p % NPOOLS;
        x.desk = address(routers[r % NROUTERS]);
        x.z = z;
        x.w = _engine().poolWord(ids[x.p]);
        _expectFee(x);
        bytes memory cd = _swapCalldata(keys[x.p], z, exactOut ? int256(amt) : -int256(amt));
        vm.recordLogs();
        (bool ok, bytes memory err) = address(routers[r % NROUTERS]).call{value: (eth && z) ? 1e40 : 0}(cd);
        if (!ok) {
            refused["swap"]++;
            if (_sel(err) != PRICE_LIMIT_EXCEEDED) {
                _violate(string.concat("swap: unexpected revert ", vm.toString(err)));
            }
            return;
        }
        landed["swap"]++;
        (bool seen, uint256 fee) = _lastSwapFee();
        if (!seen) return;
        _checkCharged(x, fee);
    }

    function _swapCalldata(PoolKey memory key, bool z, int256 spec) internal pure returns (bytes memory) {
        return abi.encodeCall(
            PoolSwapTest.swap,
            (
                key,
                IPoolManager.SwapParams({
                    zeroForOne: z,
                    amountSpecified: spec,
                    sqrtPriceLimitX96: z ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
                }),
                PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
                bytes("")
            )
        );
    }

    function _expectFee(SwapCtx memory x) internal view {
        PoolId id = ids[x.p];
        (, int24 tick,,) = manager.getSlot0(id);
        DiscountLib.Entry memory e = _engine().discountOf(id, x.desk);
        uint256 entry = DiscountLib.pack(e.bps, e.minFee, e.dirs, e.expiry);
        uint256 cf = FablesFeeFull(hook).cfWord(id);
        (x.expected,) = FeeRef.resolve(x.w, x.z, x.desk, entry, cf, tick, block.timestamp);
        (x.senderFree,) = FeeRef.resolve(x.w, x.z, x.desk, 0, cf, tick, block.timestamp);
        x.discounted = x.expected < x.senderFree;
    }

    function _checkCharged(SwapCtx memory x, uint256 fee) internal {
        CategoryTable.Cat memory c = _cat(x.p);
        if (fee > maxChargedFee) maxChargedFee = fee;
        if (fee > x.w.cap()) _violate("swap: charged fee above the pool cap");
        if (x.w.cap() > c.capMax) _violate("swap: pool cap above the category cap");
        if (c.capMax > CategoryTable.ABSOLUTE_MAX_FEE) _violate("swap: category cap above 100_000");
        if (fee < x.w.floor()) _violate("swap: charged fee under the floor");
        if (fee != x.expected) {
            _violate(string.concat("swap: charged != FeeRef twin: ", vm.toString(fee), " vs ", vm.toString(x.expected)));
        }
        bool live = _now() < x.w.expiry() && x.w.poke(x.z) != 0;
        if (live) swapsWithLivePoke++;
        if (x.w.cfOn()) swapsWithCF++;
        if (x.discounted) swapsWithDiscount++;
        if (fee > x.senderFree) _violate("swap: discounted fee above the sender-free fee");
        if (2 * fee < x.senderFree) _violate("swap: discount cut more than 50%");
    }

    function _lastSwapFee() internal view returns (bool seen, uint256 fee) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(manager) && logs[i].topics[0] == SWAP_TOPIC) {
                (,,,,, uint24 f) = abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
                fee = f;
                seen = true;
            }
        }
    }

    function deposit(uint256 p, uint256 a, uint256 rg, uint256 liq) external budgeted {
        p %= NPOOLS;
        address who = actors[a % NACTORS];
        uint256 value = eth ? 1e24 : 0;
        if (eth) vm.deal(who, who.balance + value);
        bytes memory cd = _depositCalldata(p, rg % NRANGES, uint128(bound(liq, 1e6, 1e21)), value);
        vm.prank(who);
        (bool ok, bytes memory err) = hook.call{value: value}(cd);
        _outcome("deposit", true, ok, err, bytes4(0));
        if (eth && hook.balance != 0) _violate("deposit: ETH left on the hook");
    }

    function _depositCalldata(uint256 p, uint256 k, uint128 l, uint256 value) internal view returns (bytes memory) {
        uint128 max0 = value == 0 ? type(uint128).max : uint128(value);
        return
            abi.encodeCall(FablesLedgerV2.deposit, (keys[p], lowers[k], uppers[k], l, max0, type(uint128).max, _now()));
    }

    function withdraw(uint256 p, uint256 a, uint256 rg, uint256 frac) external budgeted {
        p %= NPOOLS;
        address who = actors[a % NACTORS];
        uint256 k = rg % NRANGES;
        uint256 bal = _ledger().balanceOf(who, rangeIdAt(p, k));
        if (bal == 0) return;
        bytes memory cd = abi.encodeCall(
            FablesLedgerV2.withdraw, (keys[p], lowers[k], uppers[k], uint128(bound(frac, 1, bal)), who, 0, 0, _now())
        );
        vm.prank(who);
        (bool ok, bytes memory err) = hook.call(cd);
        _outcome("withdraw", true, ok, err, bytes4(0));
    }

    function claim(uint256 p, uint256 a, uint256 rg) external budgeted {
        p %= NPOOLS;
        address who = actors[a % NACTORS];
        uint256 k = rg % NRANGES;
        vm.prank(who);
        (bool ok, bytes memory err) =
            hook.call(abi.encodeCall(FablesLedgerV2.claimFees, (keys[p], lowers[k], uppers[k], who, uint16(0))));
        if (!ok && _sel(err) == FablesLedgerV2.NothingToClaim.selector) {
            refused["claim"]++;
            return;
        }
        _outcome("claim", true, ok, err, bytes4(0));
    }

    function warp(uint256 secs, uint256 blocks) external budgeted {
        vm.warp(block.timestamp + bound(secs, 1, 3 days));
        vm.roll(block.number + bound(blocks, 1, 1_000));
    }

    function warpShort(uint256 secs) external budgeted {
        vm.warp(block.timestamp + bound(secs, 1, 120));
        vm.roll(block.number + 1);
    }

    function _callHook(bytes memory cd) internal returns (bool ok, bytes memory ret) {
        (ok, ret) = hook.call(cd);
    }

    function keyAt(uint256 p) external view returns (PoolKey memory) {
        return keys[p];
    }

    function rangeIdAt(uint256 p, uint256 k) public view returns (uint256) {
        return _ledger().rangeId(ids[p], lowers[k], uppers[k]);
    }

    function routerAt(uint256 r) external view returns (address) {
        return address(routers[r]);
    }

    function actorAt(uint256 a) external view returns (address) {
        return actors[a];
    }

    function counts(bytes32 name) external view returns (uint256, uint256) {
        return (landed[name], refused[name]);
    }
}
