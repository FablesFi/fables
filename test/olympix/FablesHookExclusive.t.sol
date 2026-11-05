// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {FablesHookExclusive} from "../../src/FablesHookExclusive.sol";
import {OlympixHookFixture} from "./OlympixHookFixture.sol";
import {OlympixUnitTest} from "./OlympixUnitTest.sol";

/// @notice Olympix skeleton: FablesHookExclusive (liquidity only through the ledger).
contract FablesHookExclusiveOlympixTest is OlympixHookFixture, OlympixUnitTest("FablesHookExclusive") {
    FablesHookExclusive internal fablesHook;

    function setUp() public {
        _setUpBuild(2);
        fablesHook = FablesHookExclusive(payable(hookAddr));
    }

    function test_directLiquidityIsRefused() public {
        _expectGateRevert();
        modifyLiquidityRouter.modifyLiquidity(key, LIQUIDITY_PARAMS, ZERO_BYTES);
    }
}
