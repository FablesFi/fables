// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";

import {FablesFeeEngine} from "../../src/base/FablesFeeEngine.sol";
import {PoolWordLib} from "../../src/libraries/PoolWordLib.sol";
import {DiscountLib} from "../../src/libraries/DiscountLib.sol";
import {FeeRef} from "../../src/libraries/FeeRef.sol";
import {EngineHarness, EngineSymmetricHarness} from "../utils/EngineHarness.sol";

/// @notice Engine admin / poke rules under random category writes, configures, pokes, clears, discounts and warps.
contract FablesFeeEngineInvariantTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;

    EngineInvariantHandler handler;

    function setUp() public virtual {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();
        AccessManager authority = new AccessManager(address(this));
        address hookAddr = address(uint160(0x7777 << 144) | uint160(Hooks.BEFORE_INITIALIZE_FLAG));
        deployCodeTo("EngineHarness.sol:EngineHarness", abi.encode(manager, address(authority)), hookAddr);
        _finishSetup(FablesFeeEngine(hookAddr), authority, false);
    }

    function _finishSetup(FablesFeeEngine hook, AccessManager authority, bool symmetric) internal {
        vm.warp(1_785_859_200);
        hook.setCategory(1, 0, 50_000, 2500, "STOCK");
        hook.setCategory(2, 2500, 100_000, 10_000, "MEME");
        PoolKey[] memory keys = new PoolKey[](3);
        int24[3] memory spacings = [int24(10), int24(60), int24(200)];
        for (uint256 i = 0; i < 3; ++i) {
            keys[i] = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, spacings[i], IHooks(address(hook)));
            hook.configurePool(keys[i], 1, 700, symmetric ? 700 : 900, 300, 8000);
            hook.initializePool(keys[i], SQRT_PRICE_1_1);
        }
        handler = new EngineInvariantHandler(hook, keys, symmetric);
        authority.grantRole(0, address(handler), 0);
        targetContract(address(handler));
    }

    function invariant_feeInsideTheBandOnBothSides() public view {
        for (uint256 i = 0; i < 3; ++i) {
            (PoolId id, EngineInvariantHandler.GPool memory g) = handler.pool(i);
            uint256 w = handler.hook().poolWord(id);
            for (uint256 side = 0; side < 2; ++side) {
                bool zeroForOne = side == 0;
                uint256 fee = FeeRef.keeperFee(w, zeroForOne, block.timestamp);
                assertGe(fee, g.floor, "floor");
                assertLe(fee, g.cap, "cap");
                assertLe(fee, 100_000, "absolute");
                assertEq(fee, handler.modelFee(i, zeroForOne), "fee diverged from the design pipeline");
                if (!handler.symmetric()) {
                    (uint256 f,) =
                        FeeRef.resolve(w, zeroForOne, handler.desk(), handler.entry(i), 0, 0, block.timestamp);
                    assertGe(f, g.floor, "floor (listed)");
                    assertLe(f, fee, "a discount raised the fee");
                }
            }
        }
    }

    function invariant_livePokeHonoursTheFiftyPercentFloor() public view {
        for (uint256 i = 0; i < 3; ++i) {
            (PoolId id, EngineInvariantHandler.GPool memory g) = handler.pool(i);
            if (block.timestamp >= g.expiry) continue;
            uint256 w = handler.hook().poolWord(id);
            for (uint256 side = 0; side < 2; ++side) {
                bool zeroForOne = side == 0;
                uint256 poke = zeroForOne ? g.poke0 : g.poke1;
                if (poke == 0) continue;
                uint256 base = zeroForOne ? g.base0 : g.base1;
                uint256 half = (base > g.cap ? g.cap : base) / 2;
                uint256 lo = half > g.floor ? half : g.floor;
                assertGe(FeeRef.keeperFee(w, zeroForOne, block.timestamp), lo, "fifty-percent floor");
            }
        }
    }

    function invariant_raiseStepAndCadence() public view {
        assertEq(handler.raiseStepViolations(), 0, "a landed poke raised a side by more than the step");
        assertEq(handler.raiseCadenceViolations(), 0, "two raises landed inside one interval");
        assertEq(handler.ceilingViolations(), 0, "a poke above min(cap, capMax) landed");
        for (uint256 i = 0; i < 3; ++i) {
            (PoolId id, EngineInvariantHandler.GPool memory g) = handler.pool(i);
            assertEq(handler.hook().lastRaiseAt(id), g.lastRaiseAt, "lastRaiseAt diverged");
        }
    }

    function invariant_configChain() public view {
        for (uint256 i = 0; i < 3; ++i) {
            (PoolId id, EngineInvariantHandler.GPool memory g) = handler.pool(i);
            PoolWordLib.PoolWord memory p = handler.hook().poolFee(id);
            assertGe(p.cap, 1, "cap back to 0");
            assertLe(p.cap, 100_000);
            assertEq(handler.hook().maxFee(id), p.cap, "core marker != cap");
            assertLe(p.floor, p.base0 < p.base1 ? p.base0 : p.base1, "floor above a base");
            assertLe(p.base0 > p.base1 ? p.base0 : p.base1, p.cap, "a base above the cap");
            assertEq(p.floor, g.floor);
            assertEq(p.cap, g.cap);
            assertEq(p.base0, g.base0);
            assertEq(p.base1, g.base1);
            assertEq(p.poke0, g.poke0);
            assertEq(p.poke1, g.poke1);
            assertEq(p.expiry, g.expiry);
            assertEq(handler.hook().categoryOf(id), g.cat);
            if (handler.symmetric()) {
                assertEq(p.base0, p.base1, "symmetric mode: bases differ");
                assertEq(p.poke0, p.poke1, "symmetric mode: pokes differ");
                assertEq(p.bloom, 0, "symmetric mode: bloom");
                assertFalse(p.cfOn, "symmetric mode: cfOn");
            }
        }
        assertEq(handler.configChainViolations(), 0, "a configure landed outside its category band");
    }

    function invariant_settersTouchOnlyTheirFields() public view {
        assertEq(handler.fieldViolations(), 0, "a setter changed a field group it does not own");
    }

    function test_theHandlersActionsActuallyReachTheHook() public {
        handler.setCategory(1, 0, 50_000, 2500);
        handler.configure(0, 1, 1000, 1200, 500, 9000, false);
        handler.poke(0, 3000, 3200, 1 hours, 0);
        handler.poke(0, 3001, 0, 1 hours, 0);
        handler.poke(0, 9001, 0, 1 hours, 2);
        handler.poke(0, 600, 0, 1 hours, 0);
        handler.warp(60, false);
        handler.poke(0, 3100, 0, 1 hours, 0);
        handler.clear(0);
        if (!handler.symmetric()) handler.discount(0, 2500, 0, 3);
        assertGt(handler.categoriesSet(), 0);
        assertGt(handler.configuresLanded(), 0);
        assertGt(handler.pokesLanded(), 2);
        assertGt(handler.pokesRefused(), 1);
        assertGt(handler.raisesLanded(), 1);
        assertGt(handler.cutsLanded(), 0);
        assertGt(handler.clearsLanded(), 0);
        if (!handler.symmetric()) assertGt(handler.discountsLanded(), 0);
        invariant_feeInsideTheBandOnBothSides();
        invariant_raiseStepAndCadence();
        invariant_configChain();
    }
}

/// @notice The same walk in the engine's symmetric mode.
contract FablesFeeEngineSymmetricInvariantTest is FablesFeeEngineInvariantTest {
    function setUp() public override {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();
        AccessManager authority = new AccessManager(address(this));
        address hookAddr = address(uint160(0x8888 << 144) | uint160(Hooks.BEFORE_INITIALIZE_FLAG));
        deployCodeTo("EngineHarness.sol:EngineSymmetricHarness", abi.encode(manager, address(authority)), hookAddr);
        _finishSetup(FablesFeeEngine(hookAddr), authority, true);
    }
}

/// @notice Random walk over the engine's admin and poke entry points.
contract EngineInvariantHandler is Test {
    using PoolIdLibrary for PoolKey;
    using PoolWordLib for uint256;

    struct GCat {
        uint24 floorMin;
        uint24 capMax;
        uint24 raiseStep;
    }

    struct GPool {
        uint8 cat;
        uint24 floor;
        uint24 cap;
        uint24 base0;
        uint24 base1;
        uint24 poke0;
        uint24 poke1;
        uint40 expiry;
        uint40 lastRaiseAt;
    }

    FablesFeeEngine public hook;
    bool public symmetric;
    address public desk = makeAddr("desk");
    PoolKey[] internal keys;
    PoolId[] internal ids;

    mapping(uint8 => GCat) internal gCat;
    GPool[3] internal gPool;
    uint256[3] internal gEntry;

    uint256 public categoriesSet;
    uint256 public configuresLanded;
    uint256 public configuresRefused;
    uint256 public pokesLanded;
    uint256 public pokesRefused;
    uint256 public raisesLanded;
    uint256 public cutsLanded;
    uint256 public clearsLanded;
    uint256 public discountsLanded;
    uint256 public raiseStepViolations;
    uint256 public raiseCadenceViolations;
    uint256 public ceilingViolations;
    uint256 public configChainViolations;
    uint256 public fieldViolations;

    constructor(FablesFeeEngine hook_, PoolKey[] memory keys_, bool symmetric_) {
        hook = hook_;
        symmetric = symmetric_;
        gCat[1] = GCat(0, 50_000, 2500);
        gCat[2] = GCat(2500, 100_000, 10_000);
        for (uint256 i = 0; i < keys_.length; ++i) {
            keys.push(keys_[i]);
            ids.push(keys_[i].toId());
            gPool[i] = GPool(1, 300, 8000, 700, symmetric_ ? 700 : 900, 0, 0, 0, 0);
        }
    }

    function pool(uint256 i) external view returns (PoolId, GPool memory) {
        return (ids[i], gPool[i]);
    }

    function entry(uint256 i) external view returns (uint256) {
        return gEntry[i];
    }

    function modelFee(uint256 i, bool zeroForOne) public view returns (uint256) {
        GPool memory g = gPool[i];
        return _model(g, zeroForOne, zeroForOne ? g.poke0 : g.poke1, g.expiry, block.timestamp);
    }

    function _model(GPool memory g, bool zeroForOne, uint256 pokeFee, uint256 expiry, uint256 nowTs)
        internal
        pure
        returns (uint256 fee)
    {
        uint256 pre = zeroForOne ? g.base0 : g.base1;
        fee = pre;
        if (nowTs < expiry && pokeFee != 0) {
            uint256 half = (pre > g.cap ? g.cap : pre) / 2;
            uint256 lo = half > g.floor ? half : g.floor;
            fee = pokeFee > lo ? pokeFee : lo;
        }
        if (fee > g.cap) fee = g.cap;
    }

    function setCategory(uint8 which, uint24 floorMin, uint24 capMax, uint24 raiseStep) external {
        which = uint8(bound(which, 1, 2));
        capMax = uint24(bound(capMax, 0, 100_000));
        floorMin = uint24(bound(floorMin, 0, capMax));
        raiseStep = uint24(bound(raiseStep, 1, capMax == 0 ? 1 : capMax));
        hook.setCategory(which, floorMin, capMax, raiseStep, "");
        gCat[which] = GCat(floorMin, capMax, raiseStep);
        categoriesSet++;
    }

    function configure(uint8 p, uint8 which, uint24 b0, uint24 b1, uint24 floor_, uint24 cap, bool invalid) external {
        uint256 i = bound(p, 0, 2);
        which = uint8(bound(which, 1, 2));
        GCat memory c = gCat[which];
        if (invalid || c.capMax == 0) {
            vm.expectRevert(FablesFeeEngine.InvalidConfig.selector);
            hook.configurePool(keys[i], which, 0, 0, 0, 0);
            configuresRefused++;
            return;
        }
        cap = uint24(bound(cap, c.floorMin == 0 ? 1 : c.floorMin, c.capMax));
        floor_ = uint24(bound(floor_, c.floorMin, cap));
        b0 = uint24(bound(b0, floor_, cap));
        b1 = symmetric ? b0 : uint24(bound(b1, floor_, cap));
        uint256 before = hook.poolWord(ids[i]);
        hook.configurePool(keys[i], which, b0, b1, floor_, cap);
        uint256 after_ = hook.poolWord(ids[i]);
        uint256 mask = PoolWordLib.BASES_MASK | PoolWordLib.BOUNDS_MASK;
        if (after_ & ~mask != before & ~mask) fieldViolations++;
        uint24 lo = b0 < b1 ? b0 : b1;
        uint24 hi = b0 < b1 ? b1 : b0;
        if (!(c.floorMin <= floor_ && floor_ <= lo && hi <= cap && cap <= c.capMax && cap >= 1)) {
            configChainViolations++;
        }
        GPool storage g = gPool[i];
        (g.cat, g.floor, g.cap, g.base0, g.base1) = (which, floor_, cap, b0, b1);
        configuresLanded++;
    }

    function poke(uint8 p, uint24 s0, uint24 s1, uint40 ttl, uint8 shape) external {
        uint256 i = bound(p, 0, 2);
        GPool memory g = gPool[i];
        uint256 ceiling = _ceiling(g);
        s0 = _drawSide(s0, g.floor, ceiling, shape & 1 != 0, shape & 2 != 0);
        s1 = symmetric ? s0 : _drawSide(s1, g.floor, ceiling, shape & 4 != 0, shape & 8 != 0);
        ttl = shape & 16 != 0 ? (ttl % 2 == 0 ? 0 : 72 hours + 1) : uint40(bound(ttl, 1, 72 hours));
        bytes4 err = _predict(g, ceiling, s0, s1, ttl);
        if (err != bytes4(0)) _pokeRefused(i, s0, s1, ttl, err);
        else _pokeLanded(i, g, ceiling, s0, s1, ttl);
    }

    function _ceiling(GPool memory g) internal view returns (uint256) {
        uint24 capMax = gCat[g.cat].capMax;
        return g.cap < capMax ? g.cap : capMax;
    }

    function _pokeRefused(uint256 i, uint24 s0, uint24 s1, uint40 ttl, bytes4 err) internal {
        uint256 before = hook.poolWord(ids[i]);
        vm.expectRevert(err);
        hook.pokeFee(ids[i], s0, s1, ttl);
        if (hook.poolWord(ids[i]) != before) fieldViolations++;
        pokesRefused++;
    }

    function _pokeLanded(uint256 i, GPool memory g, uint256 ceiling, uint24 s0, uint24 s1, uint40 ttl) internal {
        uint256 before = hook.poolWord(ids[i]);
        hook.pokeFee(ids[i], s0, s1, ttl);
        uint256 after_ = hook.poolWord(ids[i]);
        if (after_ & ~PoolWordLib.POKES_MASK != before & ~PoolWordLib.POKES_MASK) fieldViolations++;
        if ((s0 != 0 && s0 > ceiling) || (s1 != 0 && s1 > ceiling)) ceilingViolations++;
        (bool raised, bool tooLarge) = _raiseCheck(g, s0, s1, ttl, gCat[g.cat].raiseStep);
        if (tooLarge) raiseStepViolations++;
        GPool storage gs = gPool[i];
        if (raised) {
            if (block.timestamp < uint256(g.lastRaiseAt) + 60) raiseCadenceViolations++;
            gs.lastRaiseAt = uint40(block.timestamp);
            raisesLanded++;
        } else {
            cutsLanded++;
        }
        (gs.poke0, gs.poke1, gs.expiry) = (s0, s1, uint40(block.timestamp + ttl));
        pokesLanded++;
    }

    function _raiseCheck(GPool memory g, uint24 s0, uint24 s1, uint40 ttl, uint24 raiseStep)
        internal
        view
        returns (bool raised, bool tooLarge)
    {
        for (uint256 side = 0; side < 2; ++side) {
            bool z = side == 0;
            uint256 cur = _model(g, z, z ? g.poke0 : g.poke1, g.expiry, block.timestamp);
            uint256 nxt = _model(g, z, z ? s0 : s1, block.timestamp + ttl, block.timestamp);
            if (nxt > cur) {
                raised = true;
                if (nxt - cur > raiseStep) tooLarge = true;
            }
        }
    }

    function _drawSide(uint24 v, uint24 floor_, uint256 ceiling, bool sentinel, bool raw)
        internal
        pure
        returns (uint24)
    {
        if (sentinel) return 0;
        if (raw || floor_ > ceiling) return v == 0 ? 1 : v;
        return uint24(bound(v, floor_, ceiling));
    }

    function _predict(GPool memory g, uint256 ceiling, uint24 s0, uint24 s1, uint40 ttl)
        internal
        view
        returns (bytes4)
    {
        if (s0 == 0 && s1 == 0) return FablesFeeEngine.EmptyPoke.selector;
        if (symmetric && s0 != s1) return FablesFeeEngine.SymmetricRequired.selector;
        if (ttl == 0 || ttl > 72 hours) return FablesFeeEngine.InvalidTtl.selector;
        if (s0 != 0) {
            if (s0 > ceiling) return FablesFeeEngine.FeeAboveCap.selector;
            if (s0 < g.floor) return FablesFeeEngine.FeeBelowFloor.selector;
        }
        if (s1 != 0) {
            if (s1 > ceiling) return FablesFeeEngine.FeeAboveCap.selector;
            if (s1 < g.floor) return FablesFeeEngine.FeeBelowFloor.selector;
        }
        (bool raised, bool tooLarge) = _raiseCheck(g, s0, s1, ttl, gCat[g.cat].raiseStep);
        if (tooLarge) return FablesFeeEngine.RaiseTooLarge.selector;
        if (raised && block.timestamp < uint256(g.lastRaiseAt) + 60) return FablesFeeEngine.RaiseTooSoon.selector;
        return bytes4(0);
    }

    function clear(uint8 p) external {
        uint256 i = bound(p, 0, 2);
        uint256 before = hook.poolWord(ids[i]);
        hook.clearPoke(ids[i]);
        uint256 after_ = hook.poolWord(ids[i]);
        if (after_ & ~PoolWordLib.POKES_MASK != before & ~PoolWordLib.POKES_MASK) fieldViolations++;
        GPool storage g = gPool[i];
        (g.poke0, g.poke1, g.expiry) = (0, 0, 0);
        clearsLanded++;
    }

    function discount(uint8 p, uint16 bps, uint24 minFee, uint8 dirs) external {
        if (symmetric) return;
        uint256 i = bound(p, 0, 2);
        bps = uint16(bound(bps, 1, 5000));
        dirs = uint8(bound(dirs, 1, 3));
        uint40 expiry = uint40(block.timestamp + 1 days);
        PoolId[] memory one = new PoolId[](1);
        one[0] = ids[i];
        uint256 before = hook.poolWord(ids[i]);
        hook.setDiscount(one, desk, bps, minFee, dirs, expiry);
        uint256 after_ = hook.poolWord(ids[i]);
        if (after_ & ~PoolWordLib.BLOOM_MASK != before & ~PoolWordLib.BLOOM_MASK) fieldViolations++;
        gEntry[i] = DiscountLib.pack(bps, minFee, dirs, expiry);
        discountsLanded++;
    }

    function warp(uint16 by, bool far) external {
        vm.warp(block.timestamp + (far ? bound(by, 1, 80 hours) : bound(by, 0, 120)));
    }
}
