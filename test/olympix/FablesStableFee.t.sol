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
}
