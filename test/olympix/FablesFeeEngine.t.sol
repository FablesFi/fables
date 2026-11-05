// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {FablesHook} from "../../src/FablesHook.sol";
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
}
