// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";

import {ClaimFeeAccrued, FeesForgone, UserPosition} from "../../src/base/LedgerTypesV2.sol";
import {AccWrapHarness} from "../regression/LedgerAccumulatorWrap.t.sol";

/// @notice LedgerLibV2 on its own storage (`AccWrapHarness`, no PoolManager): the fee split, staked remainders,
///         claim-fee reporting and forgone accounting that Olympix mutation testing of the library showed unchecked.
contract LedgerLibV2OlympixTest is Test {
    using PoolIdLibrary for PoolKey;

    uint256 internal constant ID = 1;
    uint16 internal constant BPS = 1000;
    address internal constant LP = address(0xA11CE);
    address internal constant STAKER = address(0xB0B);

    AccWrapHarness internal h;
    Currency internal c0;
    Currency internal c1;

    function setUp() public {
        h = new AccWrapHarness();
        c0 = h.currency(true);
        c1 = h.currency(false);
    }

    /// @dev Fees credited to a range nobody holds go to the distributor whole.
    function test_feesOnARangeWithoutSharesGoToTheDistributor() public {
        h.credit(5, 7);
        h.credit(11, 13);
        assertEq(h.distributorOwed(c0), 16);
        assertEq(h.distributorOwed(c1), 20);
    }

    /// @dev A third of the shares staked, fee0 = 1 and fee1 = 2 per collection: each token's staked cut carries its own
    ///      remainder, so 300 collections give cuts of 100 and 200 (each within one unit of Q128 flooring).
    function test_stakedCutCarriesEachTokensOwnRemainder() public {
        h.join(LP, 2);
        h.join(STAKER, 1);
        h.stake(STAKER, 1);
        for (uint256 i; i < 300; ++i) {
            h.credit(1, 2);
        }
        assertApproxEqAbs(h.distributorOwed(c0), 100, 1);
        assertApproxEqAbs(h.distributorOwed(c1), 200, 1);
    }

    /// @dev Every share staked: the staked cut is the whole fee (no remainder), so the distributor gets every unit and
    ///      the unstaked branch adds exactly zero.
    function testFuzz_allStakedSendsEveryFeeToTheDistributor(uint128 shares, uint128[4] memory fees) public {
        shares = uint128(bound(shares, 1, type(uint128).max));
        h.join(STAKER, shares);
        h.stake(STAKER, shares);
        uint256 sum0;
        uint256 sum1;
        for (uint256 i; i < 2; ++i) {
            uint128 f0 = uint128(bound(fees[2 * i], 0, type(uint64).max));
            uint128 f1 = uint128(bound(fees[2 * i + 1], 0, type(uint64).max));
            h.credit(f0, f1);
            sum0 += f0;
            sum1 += f1;
        }
        assertEq(h.distributorOwed(c0), sum0);
        assertEq(h.distributorOwed(c1), sum1);
        assertEq(h.range().stakedResidual0, 0);
        assertEq(h.range().stakedResidual1, 0);
    }

    function test_claimFeeIsBookedAndReportedOnAToken0OnlyCollection() public {
        _oneSidedClaimFee(true);
    }

    function test_claimFeeIsBookedAndReportedOnAToken1OnlyCollection() public {
        _oneSidedClaimFee(false);
    }

    /// @dev A staker's token1-only stream is counted as forgone and reported; a settle with nothing new stays quiet.
    function test_forgoneCountsAToken1OnlyStakedStream() public {
        h.join(LP, 2);
        h.join(STAKER, 1);
        h.stake(STAKER, 1);
        h.credit(0, 9); // staked cut 9 / 3 = 3, no claim fee

        vm.expectEmit(address(h));
        emit FeesForgone(STAKER, ID, 0, 3);
        h.settle(STAKER);
        UserPosition memory p = h.position(STAKER);
        assertEq(p.forgone0, 0);
        assertEq(p.forgone1, 3);

        vm.recordLogs();
        h.settle(STAKER);
        assertEq(vm.getRecordedLogs().length, 0, "nothing new: no FeesForgone");
        assertEq(h.position(STAKER).forgone1, 3);
    }

    /// @dev 10% claim fee, no stakers, a fee in one currency only: the cut is booked at the exact rate and reported.
    function _oneSidedClaimFee(bool zero) internal {
        h.setClaimFee(BPS);
        h.join(LP, 10);
        h.credit(0, 0); // opens the backlog at the current claim-fee entry
        uint128 fee = 12_345;
        uint256 cut = uint256(fee) * BPS / 10_000;

        vm.expectEmit(address(h));
        emit ClaimFeeAccrued(ID, _poolId(), zero ? cut : 0, zero ? 0 : cut, BPS);
        h.credit(zero ? fee : 0, zero ? 0 : fee);

        assertEq(h.claimFeeOwed(c0), zero ? cut : 0);
        assertEq(h.claimFeeOwed(c1), zero ? 0 : cut);
    }

    function _poolId() internal view returns (PoolId) {
        return PoolKey(c0, c1, 0x800000, 60, IHooks(address(h))).toId();
    }
}
