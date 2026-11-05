// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {OlympixStableFixture} from "./OlympixStableFixture.sol";
import {OlympixUnitTest} from "./OlympixUnitTest.sol";

/// @notice Olympix skeleton: FablesStableFee (pool config, reference moves, minimum fee, quotes), on the
///         FablesStableHookLite build.
contract FablesStableFeeOlympixTest is OlympixStableFixture, OlympixUnitTest("FablesStableFee") {
    function setUp() public {
        _setUpStable();
    }

    function test_quotesAgreeWithoutADiscount() public view {
        assertEq(stableHook.feeFor(stableKey, true, address(swapper)), stableHook.currentFee(poolId, true));
        assertEq(stableHook.feeFor(stableKey, false, address(swapper)), stableHook.currentFee(poolId, false));
    }

    /// @dev At the reference price with no minimum fee set, both directions quote a positive fee, and repeated reads
    ///      in one block agree.
    function test_feeIsPositiveAndStableWithinABlockAtTheReference() public view {
        uint24 fee0 = stableHook.currentFee(poolId, true);
        uint24 fee1 = stableHook.currentFee(poolId, false);
        assertGt(fee0, 0);
        assertGt(fee1, 0);
        assertEq(stableHook.currentFee(poolId, true), fee0);
        assertEq(stableHook.currentFee(poolId, false), fee1);
    }
}
