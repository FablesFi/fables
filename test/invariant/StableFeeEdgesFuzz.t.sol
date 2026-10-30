// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {FablesStableFee} from "../../src/base/FablesStableFee.sol";
import {StableFeeCalculation} from "../../src/libraries/StableFeeCalculation.sol";

/// @notice FablesStableFee's fee core, exposed.
contract StableFeeProbe is FablesStableFee {
    constructor() FablesStableFee(IPoolManager(address(0xBEEF)), address(0xA11)) {}

    function getFee(uint256 cfg, uint256 st, uint256 sqrtP, bool isNewBlock, bool zfo, uint256 clock)
        external
        pure
        returns (uint256, uint256)
    {
        return _getFee(cfg, st, sqrtP, isNewBlock, zfo, clock);
    }

    function toPips(uint256 feeE12) external pure returns (uint24) {
        return _toPips(feeE12);
    }
}

/// @notice FablesStableFee vs `StableFeeCalculation` at the 10% price window (beyond it the decay target is floored
///         at its value at the edge) and the 10% fee cap.
contract StableFeeEdgesFuzzTest is Test {
    uint256 internal constant Q96 = 1 << 96;
    uint256 internal constant MIN_RATIO_X96 = 71305346262837903834189555302;
    uint256 internal constant SQRT_MIN_RATIO_X96 = 75162434512514379355924140470;
    uint256 internal constant UNDEF = 1e12 + 1;

    StableFeeProbe internal probe;

    function setUp() public {
        probe = new StableFeeProbe();
    }

    function _cfg(uint24 k, uint24 opt, uint8 tm, uint256 ref) internal pure returns (uint256) {
        return uint256(k) | (uint256(opt) << 24) | (uint256(tm) << 48) | (ref << 56);
    }

    function _fresh(uint256 clock) internal pure returns (uint256) {
        return UNDEF | (clock << 200);
    }

    function _bounded(uint24 k, uint24 opt, uint8 tm, uint256 ref)
        internal
        pure
        returns (uint24, uint24, uint8, uint256)
    {
        return (
            uint24(bound(k, 1, type(uint24).max)),
            uint24(bound(opt, 0, 1e4)),
            uint8(bound(tm, 1, 100)),
            bound(ref, 1 << 80, 1 << 120)
        );
    }

    /// @dev A reachable persisted state: decaying fee <= 1e12 or UNDEFINED, any cached price, a block <= the clock.
    function _reachable(uint256 st, uint40 clock) internal pure returns (uint256) {
        uint256 fee0 = st % 7 == 0 ? UNDEF : bound(st & ((1 << 40) - 1), 0, 1e12);
        return fee0 | (st & (((1 << 160) - 1) << 40)) | (uint256(bound(st >> 200, 0, clock)) << 200);
    }

    /// forge-config: default.fuzz.runs = 2048
    /// forge-config: deep.fuzz.runs = 50000
    /// @notice Beyond the 10% window a swap never pays less than it would at the window edge, from any reachable
    ///         state, and the price persisted is the price read.
    function testFuzz_beyondWindowPaysAtLeastTheEdge(
        uint24 k,
        uint24 opt,
        uint8 tm,
        uint256 ref,
        uint256 sqrtP,
        uint256 st,
        bool below,
        bool isNewBlock,
        bool zfo,
        uint40 clock
    ) public view {
        (k, opt, tm, ref) = _bounded(k, opt, tm, ref);
        uint256 edge = below ? ref * SQRT_MIN_RATIO_X96 / Q96 : ref * Q96 / SQRT_MIN_RATIO_X96;
        sqrtP = below ? bound(sqrtP, 1, edge - 1) : bound(sqrtP, edge + 1, type(uint160).max);
        vm.assume(StableFeeCalculation.calculatePriceRatioX96(sqrtP, ref) < MIN_RATIO_X96);
        st = _reachable(st, clock);
        vm.assume(((st >> 40) & ((1 << 160) - 1)) != 0 || isNewBlock);
        uint256 cfg = _cfg(k, opt, tm, ref);
        (uint256 fee, uint256 stateLow) = probe.getFee(cfg, st, sqrtP, isNewBlock, zfo, clock);
        (uint256 feeEdge,) = probe.getFee(cfg, st, edge, isNewBlock, zfo, clock);
        assertGe(fee, feeEdge, "fee beyond the window >= fee at its edge");
        assertEq((stateLow >> 40) & ((1 << 160) - 1), sqrtP, "the price read is persisted");
    }

    /// forge-config: default.fuzz.runs = 2048
    /// forge-config: deep.fuzz.runs = 50000
    /// @notice A price parked beyond the window (cached there, the decay run out) settles the paying side at
    ///         max(StablePair's target at the price, the target at the window edge); the other side pays 0.
    function testFuzz_parkedBeyondWindowSettlesAtTheFlooredTarget(
        uint24 opt,
        uint8 tm,
        uint256 ref,
        uint256 sqrtP,
        uint256 fee0,
        bool below,
        bool zfo
    ) public view {
        (, opt, tm, ref) = _bounded(1, opt, tm, ref); // k = 1 (Q24): the decay runs out at once
        sqrtP = _beyond(ref, sqrtP, below);
        uint256 expected = _flooredTarget(StableFeeCalculation.calculatePriceRatioX96(sqrtP, ref), opt, tm);
        // cached at the same price with any decaying fee at or above the target, 1,000 blocks ago
        uint256 st = bound(fee0, expected, 1e12) | (sqrtP << 40) | (uint256(1_000_000 - 1_000) << 200);
        (uint256 fee,) = probe.getFee(_cfg(1, opt, tm, ref), st, sqrtP, true, zfo, 1_000_000);
        assertEq(fee, below == zfo ? 0 : expected, "parked: the floored target on the paying side, 0 on the other");
    }

    /// @dev A sqrt price strictly beyond the window on the chosen side.
    function _beyond(uint256 ref, uint256 sqrtP, bool below) internal pure returns (uint256 p) {
        uint256 edge = below ? ref * SQRT_MIN_RATIO_X96 / Q96 : ref * Q96 / SQRT_MIN_RATIO_X96;
        p = below ? bound(sqrtP, 1, edge - 1) : bound(sqrtP, edge + 1, type(uint160).max);
        vm.assume(StableFeeCalculation.calculatePriceRatioX96(p, ref) < MIN_RATIO_X96);
    }

    /// @dev max(StablePair's target at `ratio`, the target at the window edge), restated from the library.
    function _flooredTarget(uint256 ratio, uint24 opt, uint8 tm) internal pure returns (uint256) {
        uint256 close = uint256(StableFeeCalculation.calculateCloseBoundaryFee(ratio, opt));
        uint256 target = StableFeeCalculation.calculateFarBoundaryFee(ratio, opt) - close * tm / 100;
        uint256 edgeTarget = StableFeeCalculation.calculateFarBoundaryFee(MIN_RATIO_X96, opt)
            - uint256(StableFeeCalculation.calculateCloseBoundaryFee(MIN_RATIO_X96, opt)) * tm / 100;
        return target > edgeTarget ? target : edgeTarget;
    }

    /// @notice A stored band that reaches the window edge (optimalFeeE6 20%: impossible for a validated config) skips
    ///         the floor instead of reverting, so the fee path still reverts only where StablePair's own math does.
    function test_bandReachingTheEdgeSkipsTheFloor() public view {
        uint256 ref = 1 << 96;
        uint256 sqrtP = ref * 70_710_678 / 100_000_000; // price ratio ~0.5
        uint256 ratio = StableFeeCalculation.calculatePriceRatioX96(sqrtP, ref);
        uint256 close = uint256(StableFeeCalculation.calculateCloseBoundaryFee(ratio, 200_000));
        uint256 far = StableFeeCalculation.calculateFarBoundaryFee(ratio, 200_000);
        uint256 expected = StableFeeCalculation.calculateDecayingFee(far - close, far, 11_744_051, 1);
        (uint256 fee,) = probe.getFee(_cfg(11_744_051, 200_000, 100, ref), _fresh(1), sqrtP, true, false, 2);
        assertEq(fee, expected, "StablePair's own target, no floor, no revert");
    }

    /// forge-config: default.fuzz.runs = 2048
    /// forge-config: deep.fuzz.runs = 50000
    function testFuzz_freshPoolBeyondWindowPaysTheCap(
        uint24 k,
        uint24 opt,
        uint8 tm,
        uint256 ref,
        uint256 sqrtP,
        bool below,
        bool zfo,
        uint40 clock
    ) public view {
        (k, opt, tm, ref) = _bounded(k, opt, tm, ref);
        uint256 edge = below ? ref * SQRT_MIN_RATIO_X96 / Q96 : ref * Q96 / SQRT_MIN_RATIO_X96;
        sqrtP = below ? bound(sqrtP, 1, edge) : bound(sqrtP, edge, type(uint160).max);
        (uint256 feeE12,) = probe.getFee(_cfg(k, opt, tm, ref), _fresh(clock), sqrtP, true, zfo, clock);
        bool pays = below != zfo;
        assertEq(uint256(probe.toPips(feeE12)), pays ? 100_000 : 0, "cap on the paying side, 0 on the other");
        if (pays) assertGe(feeE12, 1e11, "the far-boundary fee at the edge is >= 10%");
    }

    /// forge-config: default.fuzz.runs = 2048
    /// forge-config: deep.fuzz.runs = 50000
    function testFuzz_insideWindowMatchesTheLibrary(
        uint24 k,
        uint24 opt,
        uint8 tm,
        uint256 ref,
        uint256 sqrtP,
        bool zfo,
        uint40 clock
    ) public view {
        (k, opt, tm, ref) = _bounded(k, opt, tm, ref);
        uint256 lo = ref * SQRT_MIN_RATIO_X96 / Q96 * 10_001 / 10_000;
        uint256 hi = ref * Q96 / SQRT_MIN_RATIO_X96 * 9_999 / 10_000;
        sqrtP = bound(sqrtP, lo, hi);
        uint256 ratio = StableFeeCalculation.calculatePriceRatioX96(sqrtP, ref);
        assertGe(ratio, MIN_RATIO_X96, "inside the window");
        (uint256 feeE12, uint256 stateLow) = probe.getFee(_cfg(k, opt, tm, ref), _fresh(clock), sqrtP, true, zfo, clock);
        assertEq(stateLow >> 40, sqrtP, "the unclamped price is persisted");
        bool below = sqrtP < ref;
        if (StableFeeCalculation.calculateCloseBoundaryFee(ratio, opt) <= 0) {
            assertEq(feeE12, StableFeeCalculation.calculateInsideOptimalRangeFee(ratio, opt, below, zfo), "in band");
            assertEq(stateLow & ((1 << 40) - 1), UNDEF, "in band: decaying fee undefined");
        } else {
            uint256 far = StableFeeCalculation.calculateFarBoundaryFee(ratio, opt);
            assertEq(feeE12, below == zfo ? 0 : far, "out of band, fresh: far-boundary fee or 0");
            assertEq(stateLow & ((1 << 40) - 1), far, "the decay starts at the far boundary");
        }
    }

    /// forge-config: default.fuzz.runs = 4096
    /// forge-config: deep.fuzz.runs = 100000
    function testFuzz_toPipsCapsBelowTheLibraryClamp(uint256 feeE12) public view {
        feeE12 = bound(feeE12, 0, 1e15);
        uint256 lib = StableFeeCalculation.toFeeE6(feeE12);
        assertEq(lib, FixedPointMathLib.min(FixedPointMathLib.divUp(feeE12, 1e6), 999_998), "toFeeE6");
        assertEq(uint256(probe.toPips(feeE12)), FixedPointMathLib.min(lib, 100_000), "_toPips");
    }

    function test_toPipsEdges() public view {
        assertEq(probe.toPips(0), 0);
        assertEq(probe.toPips(1), 1, "a sub-pip fee charges one pip");
        assertEq(probe.toPips(99_999e6 + 1), 100_000);
        assertEq(probe.toPips(1e11), 100_000);
        assertEq(probe.toPips(1e11 + 1), 100_000, "capped, not 100_001");
        assertEq(probe.toPips(1e12), 100_000);
        assertEq(StableFeeCalculation.toFeeE6(1e12), 999_998, "StablePair's own clamp sits far above");
    }
}
