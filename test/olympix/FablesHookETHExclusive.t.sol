// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {FablesHookETHExclusive} from "../../src/FablesHookETHExclusive.sol";
import {OlympixHookFixture} from "./OlympixHookFixture.sol";
import {OlympixUnitTest} from "./OlympixUnitTest.sol";

/// @notice Olympix skeleton: FablesHookETHExclusive (native ETH pools, liquidity only through the ledger).
contract FablesHookETHExclusiveOlympixTest is OlympixHookFixture, OlympixUnitTest("FablesHookETHExclusive") {
    FablesHookETHExclusive internal fablesHook;

    function setUp() public {
        _setUpBuild(3);
        fablesHook = FablesHookETHExclusive(payable(hookAddr));
    }

    function test_directNativeLiquidityIsRefused() public {
        _expectGateRevert();
        modifyLiquidityRouter.modifyLiquidity{value: 1 ether}(nativeKey, LIQUIDITY_PARAMS, ZERO_BYTES);
    }
}
