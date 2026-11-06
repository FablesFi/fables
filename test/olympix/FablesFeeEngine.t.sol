// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {FablesHook} from "../../src/FablesHook.sol";
import {FeeRef} from "../../src/libraries/FeeRef.sol";
import {OlympixHookFixture} from "./OlympixHookFixture.sol";
import {OlympixUnitTest} from "./OlympixUnitTest.sol";

/// @notice Olympix skeleton: FablesFeeEngine (categories, pool config, pokes, discounts, continuation fee), on the
///         FablesHook build. `engine` is the configured hook; quotes come from `FablesHook.currentFee` / `feeFor`.
contract FablesFeeEngineOlympixTest is OlympixHookFixture, OlympixUnitTest("FablesFeeEngine") {
    function setUp() public {
        _setUpBuild(0);
    }

    function test_quotesTheBaseFeeBothWays() public view {
        FablesHook h = FablesHook(payable(hookAddr));
        assertEq(h.currentFee(poolId, true), BASE_FEE);
        assertEq(h.currentFee(poolId, false), BASE_FEE);
        assertEq(h.feeFor(poolId, true, address(swapRouter)), BASE_FEE);
    }

    /// @dev Price 100 ticks below the anchor: continuation mode charges the swap that pushes it further down
    ///      (zeroForOne), reverse mode the swap that brings it back, by the same amount.
    function test_cfModeChargesTheContinuationOrTheReversal() public pure {
        uint256 cont = FeeRef.packCF(_cfWord(FeeRef.CF_MODE_CONTINUATION));
        uint256 rev = FeeRef.packCF(_cfWord(FeeRef.CF_MODE_REVERSE));
        (uint256 contDown,) = FeeRef.cfStep(cont, 0, true, 1000);
        (uint256 contUp,) = FeeRef.cfStep(cont, 0, false, 1000);
        (uint256 revDown,) = FeeRef.cfStep(rev, 0, true, 1000);
        (uint256 revUp,) = FeeRef.cfStep(rev, 0, false, 1000);
        assertGt(contDown, 0);
        assertEq(contUp, 0);
        assertEq(revDown, 0);
        assertEq(revUp, contDown);
    }

    /// @dev Anchored at tick 100 at t = 1000, k = 1, no dead band; period 1 so a read at t = 1000 keeps the anchor.
    function _cfWord(uint8 mode) internal pure returns (FeeRef.CFWord memory c) {
        c.tLast = 1000;
        c.anchor = 100 * 256;
        c.decay1 = FeeRef.decay1Q32(60);
        c.kQ8 = 256;
        c.cfCap = 1_000_000;
        c.maxAge = 255;
        c.period = 1;
        c.tau = 60;
        c.mode = mode;
    }
}
