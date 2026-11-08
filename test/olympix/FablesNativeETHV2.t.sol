// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";

import {FablesNativeETHV2} from "../../src/base/FablesNativeETHV2.sol";
import {ClaimFeeSwept, DistributorSwept} from "../../src/base/LedgerTypesV2.sol";
import {OlympixHookFixture} from "./OlympixHookFixture.sol";
import {OlympixUnitTest} from "./OlympixUnitTest.sol";

/// @notice FablesNativeETHV2 on the FablesHookETH build: native revenue sweeps pay WETH and report both the sweep and
///         the wrap. The native pool has a staker and a 10% claim fee; one ETH-input swap and a sync book both sinks.
contract FablesNativeETHV2OlympixTest is OlympixHookFixture, OlympixUnitTest("FablesNativeETHV2") {
    Currency internal constant ETH = CurrencyLibrary.ADDRESS_ZERO;

    function setUp() public {
        _setUpBuild(1);
        ledger.setClaimFee(nativeKey, new Currency[](0), CLAIM_FEE_BPS, claimFeeRecipient);
        vm.startPrank(bob);
        ledger.deposit{value: 1 ether}(nativeKey, LO, HI, LIQ, 1 ether, type(uint128).max, block.timestamp);
        ledger.stake(nativeKey, LO, HI, LIQ / 2, 0);
        vm.stopPrank();
        swapNativeInput(nativeKey, true, -1e15, ZERO_BYTES, 1e15);
        vm.prank(alice);
        ledger.claimFees(nativeKey, LO, HI, alice, 10_000); // syncs the range
    }

    function test_nativeDistributorSweepPaysWethAndReportsBoth() public {
        address dist = ledger.distributor();
        uint256 owed = ledger.distributorOwed(ETH);
        assertGt(owed, 0);
        uint256 before = weth.balanceOf(dist);

        vm.expectEmit(hookAddr);
        emit DistributorSwept(ETH, dist, owed);
        vm.expectEmit(hookAddr);
        emit FablesNativeETHV2.NativeRevenueWrappedToWeth(dist, address(weth), owed);
        ledger.sweepDistributor(ETH);

        assertEq(ledger.distributorOwed(ETH), 0);
        assertEq(weth.balanceOf(dist) - before, owed);
        assertEq(weth.balanceOf(hookAddr), 0, "the hook keeps no WETH");
    }

    function test_nativeClaimFeeSweepPaysWethAndReportsBoth() public {
        uint256 owed = ledger.claimFeeOwed(ETH);
        assertGt(owed, 0);
        uint256 before = weth.balanceOf(claimFeeRecipient);

        vm.expectEmit(hookAddr);
        emit ClaimFeeSwept(ETH, claimFeeRecipient, owed);
        vm.expectEmit(hookAddr);
        emit FablesNativeETHV2.NativeClaimFeeWrappedToWeth(claimFeeRecipient, address(weth), owed);
        ledger.sweepClaimFee(ETH);

        assertEq(ledger.claimFeeOwed(ETH), 0);
        assertEq(weth.balanceOf(claimFeeRecipient) - before, owed);
        assertEq(claimFeeRecipient.balance, 0, "paid in WETH, not ETH");
    }

    /// @dev Once both native sinks are paid, sweeping again moves nothing and emits nothing.
    function test_nativeSweepsWithNothingOwedAreSilent() public {
        ledger.sweepDistributor(ETH);
        ledger.sweepClaimFee(ETH);
        uint256 wethSupply = weth.totalSupply();

        vm.recordLogs();
        ledger.sweepDistributor(ETH);
        ledger.sweepClaimFee(ETH);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 0, "nothing owed: no wrap, no event");
        assertEq(weth.totalSupply(), wethSupply);
    }
}
