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

/// @notice FablesStableFee vs `StableFeeCalculation` at the price-window and 10% fee-cap clamps.
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

    /// forge-config: default.fuzz.runs = 2048
    /// forge-config: deep.fuzz.runs = 50000
    function testFuzz_beyondWindowReadsAsEdge(
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
        uint256 fee0 = st % 7 == 0 ? UNDEF : bound(st & ((1 << 40) - 1), 0, 1e12);
        st = fee0 | (st & (((1 << 160) - 1) << 40)) | (uint256(bound(st >> 200, 0, clock)) << 200);
        uint256 previous = (st >> 40) & ((1 << 160) - 1);
        vm.assume(previous != 0 || isNewBlock);
        uint256 cfg = _cfg(k, opt, tm, ref);
        (uint256 fee, uint256 stateLow) = probe.getFee(cfg, st, sqrtP, isNewBlock, zfo, clock);
        (uint256 feeEdge, uint256 stateEdge) = probe.getFee(cfg, st, edge, isNewBlock, zfo, clock);
        assertEq(fee, feeEdge, "fee beyond the window == fee at its edge");
        assertEq(stateLow, stateEdge, "state written beyond the window == at its edge");
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
