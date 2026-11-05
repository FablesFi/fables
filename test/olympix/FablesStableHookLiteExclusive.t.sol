// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {OlympixStableFixture} from "./OlympixStableFixture.sol";
import {OlympixUnitTest} from "./OlympixUnitTest.sol";

/// @notice Olympix skeleton: FablesStableHookLiteExclusive (StablePair fee, liquidity only through the ledger).
contract FablesStableHookLiteExclusiveOlympixTest is
    OlympixStableFixture,
    OlympixUnitTest("FablesStableHookLiteExclusive")
{
    function _exclusive() internal pure override returns (bool) {
        return true;
    }

    function setUp() public {
        _setUpStable();
    }

    function test_directLiquidityIsRefused() public {
        vm.expectRevert(_gateRevert(address(stableHook)));
        _addDirect(stableKey, INIT_TICK - RANGE, INIT_TICK + RANGE, 1e18);
    }
}
