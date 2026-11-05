// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {FablesHookETH} from "../../src/FablesHookETH.sol";
import {OlympixHookFixture} from "./OlympixHookFixture.sol";
import {OlympixUnitTest} from "./OlympixUnitTest.sol";

/// @notice Olympix skeleton: FablesHookETH (ERC-20 pools and pools whose currency0 is native ETH).
contract FablesHookETHOlympixTest is OlympixHookFixture, OlympixUnitTest("FablesHookETH") {
    FablesHookETH internal fablesHook;

    function setUp() public {
        _setUpBuild(1);
        fablesHook = FablesHookETH(payable(hookAddr));
    }

    function test_nativeSwapLeavesNoETHInTheHook() public {
        swapNativeInput(nativeKey, true, -1e15, ZERO_BYTES, 1e15);
        assertEq(hookAddr.balance, 0);
    }
}
