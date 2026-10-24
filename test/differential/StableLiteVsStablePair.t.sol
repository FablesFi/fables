// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import "../utils/StableTestBase.sol";
import {StableFeeCalculation} from "../../src/libraries/StableFeeCalculation.sol";

/// @notice Real-swap differential: a Stable Lite build and its typed twin against the deployed StablePair bytecode. On
///         the open build, part of the liquidity is added directly (around the ledger) in all three pools.
abstract contract StableLiteVsStablePairBase is StableTestBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint256 constant STEPS = 40;
    uint256 constant N = 3;

    address spBN;
    address spArb;
    address[2] lites;
    address[2] typeds;
    SeqSwapper sw;
    bool stats;

    struct Run {
        uint256 seed;
        uint256 mode;
        int24 ts;
        address[3] h;
        PoolKey[3] k;
        PoolId[3] id;
        uint256 clock;
        int24[8] lo;
        int24[8] hi;
        uint128[8] L;
        bool[8] direct;
        uint256 nPos;
        uint256 directPos;
        uint256 swaps;
        uint256 swapReverts;
        uint256 charged;
        uint256 zeroFee;
        uint256 inBand;
        uint256 outAdverse0;
        uint256 outCorrective;
        uint256 sameBlockCached;
        uint256 newN0;
        uint256 fastPath;
        uint256 slowPath;
        uint256 startLeftBand;
        uint256 crossRef;
        uint256 movedAway;
        uint256 towardCap;
        uint256 towardKeep;
        uint256 clampTarget;
        uint256 configs;
        uint256 liqChanges;
        uint256 exactOut;
        uint256 cappedStops;
        uint256 windowStops;
        bool stop;
    }

    function setUp() public {
        setUpChain();
        spBN = _deploySP("d-spbn");
        lites[0] = _deployLite("d-lite0");
        typeds[0] = _deployTyped("d-typed0");
        _etchArbSysSlot(50_000_000);
        spArb = _deploySP("d-sparb");
        lites[1] = _deployLite("d-lite1");
        typeds[1] = _deployTyped("d-typed1");
        assertFalse(FablesStableHookLite(lites[0]).USE_ARB_SYS(), "lite0 clock");
        assertTrue(FablesStableHookLite(lites[1]).USE_ARB_SYS(), "lite1 clock");
        assertFalse(FablesStableHookLite(typeds[0]).USE_ARB_SYS(), "typed0 clock");
        assertTrue(FablesStableHookLite(typeds[1]).USE_ARB_SYS(), "typed1 clock");
        sw = new SeqSwapper(pm);
        MockERC20(Currency.unwrap(c0)).mint(address(sw), BIG);
        MockERC20(Currency.unwrap(c1)).mint(address(sw), BIG);
        stats = vm.envOr("STABLE_DIFF_STATS", false);
    }

    function _rand(uint256 seed, uint256 i, string memory tag) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(seed, i, tag)));
    }

    /// forge-config: default.fuzz.runs = 128
    /// forge-config: deep.fuzz.runs = 4000
    function testFuzz_sequence(uint256 seed) public {
        Run memory R = _runSequence(seed);
        _writeStats(R);
    }

    function test_sequenceBranchCoverage_part1() public {
        _coverage(1);
    }

    function test_sequenceBranchCoverage_part2() public {
        _coverage(2);
    }

    function test_sequenceBranchCoverage_part3() public {
        _coverage(3);
    }

    function test_sequenceBranchCoverage_part4() public {
        _coverage(4);
    }

    function _coverage(uint256 part) internal {
        Run memory T;
        for (uint256 i = 1; i <= 20; i++) {
            uint256 snap = vm.snapshotState();
            Run memory R = this.runSequenceExt(uint256(keccak256(abi.encode("coverage", part, i))));
            vm.revertToState(snap);
            T.swaps += R.swaps;
            T.swapReverts += R.swapReverts;
            T.charged += R.charged;
            T.zeroFee += R.zeroFee;
            T.inBand += R.inBand;
            T.outAdverse0 += R.outAdverse0;
            T.outCorrective += R.outCorrective;
            T.sameBlockCached += R.sameBlockCached;
            T.newN0 += R.newN0;
            T.fastPath += R.fastPath;
            T.slowPath += R.slowPath;
            T.startLeftBand += R.startLeftBand;
            T.crossRef += R.crossRef;
            T.movedAway += R.movedAway;
            T.towardCap += R.towardCap;
            T.towardKeep += R.towardKeep;
            T.clampTarget += R.clampTarget;
            T.configs += R.configs;
            T.liqChanges += R.liqChanges;
            T.directPos += R.directPos;
            T.exactOut += R.exactOut;
            T.windowStops += R.windowStops;
            if (R.mode == 1) T.mode += 1;
        }
        T.ts = 20;
        _logCoverage(T);
        assertGt(T.inBand, 0);
        assertGt(T.outAdverse0, 0);
        assertGt(T.outCorrective, 0);
        assertGt(T.sameBlockCached, 0);
        assertGt(T.fastPath, 0);
        assertGt(T.slowPath, 0);
        assertGt(T.startLeftBand, 0);
        assertGt(T.movedAway, 0);
        assertGt(T.towardKeep, 0);
        assertGt(T.configs, 0);
        assertGt(T.liqChanges, 0);
        assertGt(T.exactOut, 0);
        assertGt(T.mode, 0);
        if (!_exclusive()) assertGt(T.directPos, 0, "no direct position");
    }

    function runSequenceExt(uint256 seed) external returns (Run memory) {
        require(msg.sender == address(this));
        return _runSequence(seed);
    }

    function _runSequence(uint256 seed) internal returns (Run memory R) {
        R.seed = seed;
        _setupRun(R);
        for (uint256 s; s < STEPS; s++) {
            if (_outsideFeeWindow(R)) {
                R.windowStops++;
                break;
            }
            uint256 x = _rand(seed, s, "step");
            uint256 a = x % 100;
            if (a < 55) _swapStep(R, x);
            else if (a < 92) _advance(R, _gap(x >> 8));
            else if (a < 95) _advance(R, 61 + (x >> 8) % 5000);
            else if (a < 98) _configStep(R, x);
            else _liqStep(R, x);
            if (R.stop) break;
        }
    }

    function _logCoverage(Run memory T) internal pure {
        console.log(
            string.concat(
                "COVERAGE|sequences=",
                vm.toString(int256(T.ts)),
                "|arbSysSequences=",
                vm.toString(T.mode),
                "|swaps=",
                vm.toString(T.swaps),
                "|reverts=",
                vm.toString(T.swapReverts),
                "|charged=",
                vm.toString(T.charged),
                "|zeroFee=",
                vm.toString(T.zeroFee),
                "|exactOut=",
                vm.toString(T.exactOut),
                "|windowStops=",
                vm.toString(T.windowStops)
            )
        );
        console.log(
            string.concat(
                "COVERAGE|inBand=",
                vm.toString(T.inBand),
                "|outAdverse0=",
                vm.toString(T.outAdverse0),
                "|outCorrective=",
                vm.toString(T.outCorrective),
                "|sameBlockCached=",
                vm.toString(T.sameBlockCached),
                "|newBlock0=",
                vm.toString(T.newN0),
                "|fastPow=",
                vm.toString(T.fastPath),
                "|lnExp=",
                vm.toString(T.slowPath)
            )
        );
        console.log(
            string.concat(
                "COVERAGE|startLeftBand=",
                vm.toString(T.startLeftBand),
                "|crossedRef=",
                vm.toString(T.crossRef),
                "|movedAway=",
                vm.toString(T.movedAway),
                "|towardCap=",
                vm.toString(T.towardCap),
                "|towardKeep=",
                vm.toString(T.towardKeep),
                "|clampedToTarget=",
                vm.toString(T.clampTarget),
                "|configResets=",
                vm.toString(T.configs),
                "|liquidityChanges=",
                vm.toString(T.liqChanges),
                "|directPositions=",
                vm.toString(T.directPos)
            )
        );
    }

    function _outsideFeeWindow(Run memory R) internal view returns (bool) {
        (uint160 p,,,) = pm.getSlot0(R.id[0]);
        (,,, uint160 ref) = IStablePair(R.h[0]).feeConfig(R.id[0]);
        return StableFeeCalculation.calculatePriceRatioX96(p, ref) < 71305346262837903834189555302;
    }

    function _gap(uint256 x) internal pure returns (uint256) {
        uint256 s = x % 100;
        if (s < 30) return 0;
        if (s < 65) return 1 + (x >> 8) % 4;
        return 5 + (x >> 8) % 56;
    }

    function _cfgRand(uint256 x, uint160 ref) internal pure returns (StableFeeConfig memory c) {
        uint256 kSel = x % 4;
        c.k = kSel < 2 ? K07 : (kSel == 2 ? uint24(1 + (x >> 8) % ((1 << 24) - 1)) : uint24(16_609_443));
        uint256 oSel = (x >> 40) % 10;
        c.optimalFeeE6 = oSel < 3 ? 7 : (oSel < 6 ? 50 : uint24((x >> 48) % 10_001));
        c.targetMultiplier = (x >> 80) % 2 == 0 ? 100 : uint8(1 + (x >> 88) % 100);
        c.referenceSqrtPriceX96 = ref;
    }

    function _setupRun(Run memory R) internal {
        uint256 x = _rand(R.seed, 0, "setup");
        R.mode = x % 10 < 6 ? 0 : 1;
        R.h = [R.mode == 0 ? spBN : spArb, lites[R.mode], typeds[R.mode]];
        uint256 tsSel = (x >> 8) % 10;
        R.ts = tsSel < 6 ? int24(1) : (tsSel < 9 ? int24(10) : int24(60));
        if (R.mode == 1) R.clock = 50_000_000;

        int24 refTick = int24(int256((x >> 16) % 401) - 200);
        uint160 ref = TickMath.getSqrtPriceAtTick(refTick);
        ref = uint160(uint256(ref) + (x >> 32) % (uint256(ref) / 100_000 + 1));
        StableFeeConfig memory c = _cfgRand(_rand(R.seed, 0, "cfg"), ref);

        uint256 sSel = (x >> 64) % 10;
        uint160 p0 = ref;
        if (sSel >= 4 && sSel < 7) {
            p0 = uint160(uint256(ref) * 1000290 / 1000000);
        } else if (sSel >= 7) {
            uint256 dev = uint256(ref) * ((x >> 72) % 5001) / 1_000_000;
            p0 = (x >> 90) & 1 == 0 ? uint160(uint256(ref) + dev) : uint160(uint256(ref) - dev);
        }

        for (uint256 i; i < N; i++) {
            R.k[i] = PoolKey(c0, c1, DYN, R.ts, IHooks(R.h[i]));
            R.id[i] = R.k[i].toId();
            _createPool(R.h[i], R.k[i], p0, c);
        }
        _cmpState(R, "setup");
        _seedPositions(R, p0);
    }

    function _seedPositions(Run memory R, uint160 p0) internal {
        uint256 y = _rand(R.seed, 0, "liq");
        int24 base = (TickMath.getTickAtSqrtPrice(p0) / R.ts) * R.ts;
        if (y % 5 != 0) {
            _addPos(
                R,
                TickMath.minUsableTick(R.ts),
                TickMath.maxUsableTick(R.ts),
                uint128(10 ** (18 + (y >> 8) % 5)),
                _direct(y >> 40)
            );
        }
        uint256 nc = 2 + (y >> 16) % 4;
        for (uint256 j; j < nc; j++) {
            _addConc(R, base, _rand(R.seed, j, "pos"));
        }
    }

    function _addConc(Run memory R, int24 base, uint256 z) internal {
        int24 off = int24(int256(z % 41) - 20) * R.ts;
        int24 w = int24(int256(1 + (z >> 8) % 50)) * R.ts;
        uint128 L = uint128(10 ** (19 + (z >> 16) % 6)) * uint128(1 + (z >> 24) % 9);
        _addPos(R, base + off - w, base + off + w, L, _direct(z >> 32));
    }

    /// @dev Open build only: about half the positions bypass the ledger (StablePair's always do).
    function _direct(uint256 x) internal pure returns (bool) {
        return !_exclusive() && x % 2 == 0;
    }

    function _addPos(Run memory R, int24 lo, int24 hi, uint128 L, bool direct) internal {
        for (uint256 i; i < N; i++) {
            if (direct) _addDirect(R.k[i], lo, hi, L);
            else _addLiq(R.h[i], R.k[i], lo, hi, L);
        }
        if (direct) R.directPos++;
        if (R.nPos < 8) {
            R.lo[R.nPos] = lo;
            R.hi[R.nPos] = hi;
            R.L[R.nPos] = L;
            R.direct[R.nPos] = direct;
            R.nPos++;
        }
    }

    function _clockNow(Run memory R) internal view returns (uint256) {
        return R.mode == 0 ? block.number : R.clock;
    }

    function _advance(Run memory R, uint256 d) internal {
        vm.roll(block.number + d);
        if (R.mode == 1) {
            R.clock += d;
            _arbSet(R.clock);
        }
    }

    function _configStep(Run memory R, uint256 x) internal {
        (,,, uint160 ref) = IStablePair(R.h[0]).feeConfig(R.id[0]);
        StableFeeConfig memory c = _cfgRand(_rand(x, 1, "cfg2"), ref);
        for (uint256 i; i < N; i++) {
            _updateConfig(R.h[i], R.k[i], c);
        }
        R.configs++;
        _cmpState(R, "config");
    }

    function addLiqExt(address h, PoolKey calldata key, int24 lo, int24 hi, uint128 L, bool direct) external {
        require(msg.sender == address(this));
        if (direct) _addDirect(key, lo, hi, L);
        else _addLiq(h, key, lo, hi, L);
    }

    function removeLiqExt(address h, PoolKey calldata key, int24 lo, int24 hi, uint128 L, bool direct) external {
        require(msg.sender == address(this));
        if (direct) _removeDirect(key, lo, hi, L);
        else _removeLiq(h, key, lo, hi, L);
    }

    function _modAll(Run memory R, int24 lo, int24 hi, int256 delta, bool direct) internal returns (bool ok) {
        int24 mn = TickMath.minUsableTick(R.ts);
        int24 mx = TickMath.maxUsableTick(R.ts);
        if (lo < mn) lo = mn;
        if (hi > mx) hi = mx;
        if (lo >= hi) return false;
        for (uint256 i; i < N; i++) {
            bool oki;
            if (delta > 0) {
                try this.addLiqExt(R.h[i], R.k[i], lo, hi, uint128(uint256(delta)), direct) {
                    oki = true;
                } catch {}
            } else {
                try this.removeLiqExt(R.h[i], R.k[i], lo, hi, uint128(uint256(-delta)), direct) {
                    oki = true;
                } catch {}
            }
            if (i == 0) ok = oki;
            else if (oki != ok) _fail(R, "liquidity change outcome differs", i);
        }
    }

    function _liqStep(Run memory R, uint256 x) internal {
        (, int24 tick,,) = pm.getSlot0(R.id[0]);
        int24 base = (tick / R.ts) * R.ts;
        if ((x >> 8) % 2 == 0 && R.nPos > 0) {
            uint256 j = (x >> 16) % R.nPos;
            uint128 cut = R.L[j] / uint128(1 + (x >> 24) % 2);
            if (cut > 0 && _modAll(R, R.lo[j], R.hi[j], -int256(uint256(cut)), R.direct[j])) R.L[j] -= cut;
        } else {
            int24 off = int24(int256((x >> 16) % 21) - 10) * R.ts;
            int24 w = int24(int256(1 + (x >> 24) % 20)) * R.ts;
            int24 lo = base + off - w;
            int24 hi = base + off + w;
            uint128 L = uint128(10 ** (19 + (x >> 32) % 5));
            bool direct = _direct(x >> 40);
            if (_modAll(R, lo, hi, int256(uint256(L)), direct)) {
                if (direct) R.directPos++;
                if (R.nPos < 8) {
                    int24 mn = TickMath.minUsableTick(R.ts);
                    int24 mx = TickMath.maxUsableTick(R.ts);
                    R.lo[R.nPos] = lo < mn ? mn : lo;
                    R.hi[R.nPos] = hi > mx ? mx : hi;
                    R.L[R.nPos] = L;
                    R.direct[R.nPos] = direct;
                    R.nPos++;
                }
            }
        }
        R.liqChanges++;
    }

    function _swapStep(Run memory R, uint256 x) internal {
        (uint160 p,,,) = pm.getSlot0(R.id[0]);
        bool zfo = x & 1 == 0;
        if (zfo && p <= TickMath.MIN_SQRT_PRICE + 1) zfo = false;
        if (!zfo && p >= TickMath.MAX_SQRT_PRICE - 1) zfo = true;
        bool exactOut = (x >> 1) & 1 == 1;
        uint256 L = pm.getLiquidity(R.id[0]);
        if (L == 0) L = 1e18;
        uint256 amt;
        if ((x >> 2) % 10 == 0) {
            amt = 1 + (x >> 8) % 1000;
        } else {
            uint256 e = (x >> 16) % 15;
            if ((x >> 20) % 10 < 3) e = 6 + (x >> 28) % 9;
            amt = L * 3 / 100 / (10 ** e) * (100 + (x >> 24) % 900) / 1000;
            if (amt == 0) amt = 1;
        }
        if (amt > 1e36) amt = 1e36;
        uint160 lim;
        if ((x >> 40) & 1 == 0) {
            lim = zfo ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        } else {
            uint256 u = 1 + (x >> 48) % 20_000;
            uint256 d = uint256(p) * u / 1_000_000;
            if (d == 0) d = 1;
            lim = zfo ? uint160(uint256(p) - d) : uint160(uint256(p) + d);
            if (zfo && lim <= TickMath.MIN_SQRT_PRICE) lim = TickMath.MIN_SQRT_PRICE + 1;
            if (!zfo && lim >= TickMath.MAX_SQRT_PRICE) lim = TickMath.MAX_SQRT_PRICE - 1;
        }
        _cmpViews(R);
        int256 spec = exactOut ? int256(amt) : -int256(amt);
        (uint24 r0, uint24 r1) = _getFee(R.h[0], R.k[0]);
        if ((zfo ? r0 : r1) > FABLES_FEE_CAP) {
            _swapCapped(R, zfo, spec, lim);
            return;
        }
        _classify(R, zfo);
        if (exactOut) R.exactOut++;
        _swapAll(R, zfo, spec, lim);
    }

    struct SwapOut {
        bool ok;
        bytes err;
        int128 a0;
        int128 a1;
        uint160 sqrtP;
        uint128 liq;
        int24 tick;
        uint24 fee;
    }

    function _swapOne(Run memory R, uint256 i, bool zfo, int256 spec, uint160 lim) internal returns (SwapOut memory o) {
        vm.recordLogs();
        (o.ok, o.err) = sw.swap(R.k[i], zfo, spec, lim);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        if (o.ok) {
            bool found;
            for (uint256 j; j < logs.length; j++) {
                if (
                    logs[j].emitter == PM_ADDR && logs[j].topics[0] == SWAP_TOPIC
                        && logs[j].topics[1] == PoolId.unwrap(R.id[i])
                ) {
                    (o.a0, o.a1, o.sqrtP, o.liq, o.tick, o.fee) =
                        abi.decode(logs[j].data, (int128, int128, uint160, uint128, int24, uint24));
                    found = true;
                }
            }
            require(found, "no Swap event");
        } else {
            o.err = _normRevert(o.err);
        }
    }

    function _swapCapped(Run memory R, bool zfo, int256 spec, uint160 lim) internal {
        SwapOut memory a = _swapOne(R, 1, zfo, spec, lim);
        SwapOut memory b = _swapOne(R, 2, zfo, spec, lim);
        if (a.ok != b.ok || keccak256(a.err) != keccak256(b.err)) _fail(R, "capped swap: Lite vs Typed", 2);
        if (a.ok) {
            if (a.fee != FABLES_FEE_CAP || b.fee != FABLES_FEE_CAP) _fail(R, "capped swap: FEE != 10%", 1);
            if (a.a0 != b.a0 || a.a1 != b.a1 || a.sqrtP != b.sqrtP || a.tick != b.tick) {
                _fail(R, "capped swap: Lite vs Typed amounts", 2);
            }
        }
        R.cappedStops++;
        R.stop = true;
    }

    function _swapAll(Run memory R, bool zfo, int256 spec, uint160 lim) internal {
        SwapOut memory o0 = _swapOne(R, 0, zfo, spec, lim);
        for (uint256 i = 1; i < N; i++) {
            SwapOut memory o = _swapOne(R, i, zfo, spec, lim);
            if (o.ok != o0.ok) _fail(R, "swap success differs", i);
            if (!o.ok) {
                if (keccak256(o.err) != keccak256(o0.err)) _fail(R, "swap revert differs", i);
                continue;
            }
            if (o.fee != o0.fee) _fail(R, "FEE differs", i);
            if (o.a0 != o0.a0 || o.a1 != o0.a1) _fail(R, "amounts differ", i);
            if (o.sqrtP != o0.sqrtP || o.tick != o0.tick || o.liq != o0.liq) _fail(R, "post price differs", i);
            (uint160 p, int24 t,,) = pm.getSlot0(R.id[i]);
            (uint160 p0, int24 t0,,) = pm.getSlot0(R.id[0]);
            if (p != p0 || t != t0) _fail(R, "slot0 differs", i);
        }
        R.swaps++;
        if (!o0.ok) R.swapReverts++;
        else if (o0.fee == 0) R.zeroFee++;
        else R.charged++;
        _cmpState(R, "post-swap");
    }

    function _fail(Run memory R, string memory why, uint256 i) internal pure {
        revert(string.concat(why, " | hook #", vm.toString(i), " | seed ", vm.toString(R.seed)));
    }

    function _cmpViews(Run memory R) internal view {
        (uint24 f0, uint24 f1) = _getFee(R.h[0], R.k[0]);
        (f0, f1) = (_capped(f0), _capped(f1));
        for (uint256 i = 1; i < N; i++) {
            (uint24 g0, uint24 g1) = _getFee(R.h[i], R.k[i]);
            if (g0 != f0 || g1 != f1) _fail(R, "getFee differs", i);
            if (FablesStableHookLite(R.h[i]).currentFee(R.id[i], true) != f0) _fail(R, "currentFee(0for1) differs", i);
            if (FablesStableHookLite(R.h[i]).currentFee(R.id[i], false) != f1) {
                _fail(R, "currentFee(1for0) differs", i);
            }
            if (FablesStableHookLite(R.h[i]).feeFor(R.k[i], true, address(sw)) != f0) {
                _fail(R, "feeFor(0for1) differs", i);
            }
            if (FablesStableHookLite(R.h[i]).feeFor(R.k[i], false, address(sw)) != f1) {
                _fail(R, "feeFor(1for0) differs", i);
            }
        }
        _cmpState(R, "pre-swap");
    }

    function _cmpState(Run memory R, string memory tag) internal view {
        bytes32 h0 = keccak256(_stateBytes(R.h[0], R.id[0]));
        for (uint256 i = 1; i < N; i++) {
            if (keccak256(_stateBytes(R.h[i], R.id[i])) != h0) {
                _fail(R, string.concat("feeState/feeConfig differs ", tag), i);
            }
        }
    }

    struct Pre {
        uint256 dec;
        uint256 cached;
        uint256 blk;
        uint256 ref;
        uint256 opt;
        uint256 tm;
        uint256 clock;
        uint256 amm;
        uint256 ratio;
        int256 close;
        bool below;
        bool isNew;
    }

    function _pre(Run memory R) internal view returns (Pre memory q) {
        (uint40 dec, uint160 cached, uint40 blk) = IStablePair(R.h[0]).feeState(R.id[0]);
        (, uint24 opt, uint8 tm, uint160 ref) = IStablePair(R.h[0]).feeConfig(R.id[0]);
        q.dec = dec;
        q.cached = cached;
        q.blk = blk;
        q.ref = ref;
        q.opt = opt;
        q.tm = tm;
        q.clock = _clockNow(R);
        q.isNew = q.clock > q.blk || q.cached == 0;
        q.amm = q.cached;
        if (q.isNew) {
            (uint160 p,,,) = pm.getSlot0(R.id[0]);
            q.amm = p;
        }
        q.ratio = StableFeeCalculation.calculatePriceRatioX96(q.amm, q.ref);
        q.close = StableFeeCalculation.calculateCloseBoundaryFee(q.ratio, q.opt);
        q.below = q.amm < q.ref;
    }

    function _classify(Run memory R, bool zfo) internal view {
        Pre memory q = _pre(R);
        if (q.close <= 0) {
            R.inBand++;
            return;
        }
        if (q.below == zfo) R.outAdverse0++;
        else R.outCorrective++;
        if (!q.isNew) {
            R.sameBlockCached++;
            return;
        }
        _classifyNew(R, q);
    }

    function _classifyNew(Run memory R, Pre memory q) internal pure {
        uint256 el = q.clock > q.blk ? q.clock - q.blk : 0;
        if (el == 0) R.newN0++;
        else if (el <= 4) R.fastPath++;
        else R.slowPath++;
        uint256 far = StableFeeCalculation.calculateFarBoundaryFee(q.ratio, q.opt);
        uint256 start;
        if (q.dec == UNDEF) {
            R.startLeftBand++;
            start = far;
        } else if ((q.cached < q.ref) != q.below) {
            R.crossRef++;
            start = far;
        } else if (q.below == (q.amm < q.cached)) {
            R.movedAway++;
            start = StableFeeCalculation.adjustPreviousFeeForPriceMovement(
                StableFeeCalculation.calculatePriceRatioX96(q.amm, q.cached), q.dec
            );
        } else if (q.dec > far) {
            R.towardCap++;
            start = far;
        } else {
            R.towardKeep++;
            start = q.dec;
        }
        if (start < far - uint256(q.close) * q.tm / 100) R.clampTarget++;
    }

    function _writeStats(Run memory R) internal view {
        if (!stats) return;
        string memory a = string.concat(
            vm.toString(R.mode),
            ",",
            vm.toString(int256(R.ts)),
            ",",
            vm.toString(R.swaps),
            ",",
            vm.toString(R.swapReverts),
            ",",
            vm.toString(R.charged),
            ",",
            vm.toString(R.zeroFee),
            ",",
            vm.toString(R.inBand),
            ",",
            vm.toString(R.outAdverse0),
            ",",
            vm.toString(R.outCorrective),
            ","
        );
        string memory b = string.concat(
            vm.toString(R.sameBlockCached),
            ",",
            vm.toString(R.newN0),
            ",",
            vm.toString(R.fastPath),
            ",",
            vm.toString(R.slowPath),
            ",",
            vm.toString(R.startLeftBand),
            ",",
            vm.toString(R.crossRef),
            ",",
            vm.toString(R.movedAway),
            ",",
            vm.toString(R.towardCap),
            ",",
            vm.toString(R.towardKeep),
            ","
        );
        string memory c = string.concat(
            vm.toString(R.clampTarget),
            ",",
            vm.toString(R.configs),
            ",",
            vm.toString(R.liqChanges),
            ",",
            vm.toString(R.exactOut)
        );
        console.log(string.concat("STATS|", a, b, c));
    }
}

/// @notice On FablesStableHookLite, with direct positions next to the ledger's.
contract StableLiteVsStablePairTest is StableLiteVsStablePairBase {}

/// @notice On FablesStableHookLiteExclusive.
contract StableLiteVsStablePairExclusiveTest is StableLiteVsStablePairBase {
    function _exclusive() internal pure override returns (bool) {
        return true;
    }
}
