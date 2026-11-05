// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {OlympixHookFixture} from "./OlympixHookFixture.sol";
import {OlympixUnitTest} from "./OlympixUnitTest.sol";

/// @notice Olympix skeleton: FablesLedgerV2 (deposits, withdrawals, staking, fee claims, claim fee, sinks, pause),
///         on the FablesHook build.
contract FablesLedgerV2OlympixTest is OlympixHookFixture, OlympixUnitTest("FablesLedgerV2") {
    function setUp() public {
        _setUpBuild(0);
    }

    function test_withdrawBurnsTheReceipts() public {
        assertEq(ledger.balanceOf(alice, rid), LIQ);
        vm.prank(alice);
        ledger.withdraw(key, LO, HI, LIQ, alice, 0, 0, block.timestamp);
        assertEq(ledger.balanceOf(alice, rid), 0);
    }
}
