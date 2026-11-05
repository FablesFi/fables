// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {FablesHook} from "../../src/FablesHook.sol";
import {OlympixHookFixture} from "./OlympixHookFixture.sol";
import {OlympixUnitTest} from "./OlympixUnitTest.sol";

/// @notice Olympix skeleton: FablesHook (ERC-20 pools).
contract FablesHookOlympixTest is OlympixHookFixture, OlympixUnitTest("FablesHook") {
    FablesHook internal fablesHook;

    function setUp() public {
        _setUpBuild(0);
        fablesHook = FablesHook(payable(hookAddr));
    }

    function test_swapPaysTheBaseFee() public {
        vm.recordLogs();
        swap(key, true, -1e15, ZERO_BYTES);
        assertEq(_lastSwapFee(), BASE_FEE);
        assertEq(fablesHook.currentFee(poolId, true), BASE_FEE);
    }
}
