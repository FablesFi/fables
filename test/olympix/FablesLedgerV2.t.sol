// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IAccessManaged} from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20Minimal} from "v4-core/src/interfaces/external/IERC20Minimal.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";

import {FablesLedgerV2} from "../../src/base/FablesLedgerV2.sol";
import {ClaimFeeSwept, DistributorSwept, UserPosition} from "../../src/base/LedgerTypesV2.sol";
import {OlympixHookFixture} from "./OlympixHookFixture.sol";
import {OlympixUnitTest} from "./OlympixUnitTest.sol";

/// @notice Olympix skeleton: FablesLedgerV2 (deposits, withdrawals, staking, fee claims, claim fee, sinks, pause),
///         on the FablesHook build. Also pins the behaviours Olympix mutation testing showed unchecked: admin-only
///         setters, pause bounds, sweeps while paused, one-sided fee payouts and the ledger's events.
contract FablesLedgerV2OlympixTest is OlympixHookFixture, OlympixUnitTest("FablesLedgerV2") {
    uint256 internal constant T0 = 1_000_000;

    function setUp() public {
        _setUpBuild(0);
    }

    function test_withdrawBurnsTheReceipts() public {
        assertEq(ledger.balanceOf(alice, rid), LIQ);
        vm.prank(alice);
        ledger.withdraw(key, LO, HI, LIQ, alice, 0, 0, block.timestamp);
        assertEq(ledger.balanceOf(alice, rid), 0);
    }

    function test_effectiveClaimFeeIsZeroOnAnUnknownRange() public view {
        (,,, bool set) = ledger.rangeKey(rid + 1);
        assertFalse(set);
        assertEq(ledger.effectiveClaimFee(rid + 1), 0);
    }

    function test_stakeMovesSharesIntoTheStakedTotal() public {
        uint128 totalBefore = ledger.rangeState(rid).totalStaked;
        vm.prank(alice);
        ledger.stake(key, LO, HI, 1, 0);
        assertEq(ledger.userPosition(rid, alice).staked, 1);
        assertEq(ledger.rangeState(rid).totalStaked, totalBefore + 1);
    }

    function test_adminFunctionsRejectAStranger() public {
        address stranger = makeAddr("olympix.stranger");
        Currency[] memory none = new Currency[](0);
        bytes[9] memory calls = [
            abi.encodeCall(ledger.setClaimFee, (key, none, 0, claimFeeRecipient)),
            abi.encodeCall(ledger.setClaimFeeBps, (key, 0)),
            abi.encodeCall(ledger.setFFFeeSink, (none, address(0))),
            abi.encodeCall(ledger.setDistributor, (none, address(0))),
            abi.encodeCall(ledger.setPaused, (1)),
            abi.encodeCall(ledger.pause, (1)),
            abi.encodeCall(ledger.setPoolPaused, (key, 1)),
            abi.encodeCall(ledger.pausePool, (key, 1)),
            abi.encodeCall(ledger.setBallotGate, (address(0)))
        ];
        for (uint256 i; i < calls.length; ++i) {
            vm.prank(stranger);
            (bool ok, bytes memory ret) = hookAddr.call(calls[i]);
            assertFalse(ok, vm.toString(i));
            assertEq(ret, abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger));
        }
    }

    function test_maxPauseIsSevenDays() public {
        assertEq(ledger.MAX_PAUSE(), 7 days);
        vm.expectRevert(FablesLedgerV2.PauseTooLong.selector);
        ledger.setPoolPaused(key, 7 days + 1);
        ledger.setPoolPaused(key, 7 days);
        assertEq(ledger.pausedUntilOf(poolId), block.timestamp + 7 days);
    }

    function test_poolPauseEndsAfterItsDuration() public {
        vm.warp(T0);
        ledger.setPoolPaused(key, 1 days);
        assertEq(ledger.pausedUntilOf(poolId), T0 + 1 days);
        assertTrue(ledger.pausedFor(poolId));
        vm.warp(T0 + 1 days);
        assertFalse(ledger.pausedFor(poolId));
    }

    function test_sweepsWaitWhileTheLedgerIsPaused() public {
        ledger.setPaused(1 days);
        vm.expectRevert(FablesLedgerV2.LedgerPaused.selector);
        ledger.sweepDistributor(currency0);
        vm.expectRevert(FablesLedgerV2.LedgerPaused.selector);
        ledger.sweepClaimFee(currency0);
    }

    function test_withdrawAndClaimPaysAToken0OnlyBacklog() public {
        _withdrawAndClaimOneSided(true);
    }

    function test_withdrawAndClaimPaysAToken1OnlyBacklog() public {
        _withdrawAndClaimOneSided(false);
    }

    function test_adminSettersEmit() public {
        Currency[] memory none = new Currency[](0);
        vm.warp(T0);

        vm.expectEmit(hookAddr);
        emit FablesLedgerV2.ClaimFeeSet(poolId, 500, claimFeeRecipient);
        ledger.setClaimFee(key, none, 500, claimFeeRecipient);

        vm.expectEmit(hookAddr);
        emit FablesLedgerV2.ClaimFeeSet(poolId, 400, claimFeeRecipient);
        ledger.setClaimFeeBps(key, 400);

        address sink = makeAddr("olympix.ffSink");
        vm.expectEmit(hookAddr);
        emit FablesLedgerV2.FFFeeSinkSet(sink);
        ledger.setFFFeeSink(none, sink);

        vm.expectEmit(hookAddr);
        emit FablesLedgerV2.DistributorSet(address(0));
        ledger.setDistributor(none, address(0));

        vm.expectEmit(hookAddr);
        emit FablesLedgerV2.PausedSet(T0 + 1 days);
        ledger.setPaused(1 days);

        vm.expectEmit(hookAddr);
        emit FablesLedgerV2.PausedSet(T0 + 2 days);
        ledger.pause(2 days);

        vm.expectEmit(hookAddr);
        emit FablesLedgerV2.PoolPausedSet(poolId, T0 + 1 days);
        ledger.setPoolPaused(key, 1 days);

        vm.expectEmit(hookAddr);
        emit FablesLedgerV2.PoolPausedSet(poolId, T0 + 2 days);
        ledger.pausePool(key, 2 days);

        vm.expectEmit(hookAddr);
        emit FablesLedgerV2.BallotGateSet(address(0));
        ledger.setBallotGate(address(0));
    }

    function test_lpActionsEmit() public {
        address carol = makeAddr("olympix.carol");
        _fund(carol);
        vm.startPrank(carol);

        vm.expectEmit(hookAddr);
        emit FablesLedgerV2.Deposited(carol, rid, LIQ);
        ledger.deposit(key, LO, HI, LIQ, type(uint128).max, type(uint128).max, block.timestamp);

        vm.expectEmit(hookAddr);
        emit FablesLedgerV2.Staked(carol, rid, LIQ / 2);
        ledger.stake(key, LO, HI, LIQ / 2, 0);

        vm.expectEmit(hookAddr);
        emit FablesLedgerV2.Unstaked(carol, rid, LIQ / 4);
        ledger.unstake(key, LO, HI, LIQ / 4);
        vm.stopPrank();

        swap(key, true, -1e15, ZERO_BYTES);
        swap(key, false, -1e15, ZERO_BYTES);

        vm.startPrank(carol);
        vm.expectEmit(true, true, false, false, hookAddr);
        emit FablesLedgerV2.FeesClaimed(carol, rid, 0, 0);
        ledger.claimFees(key, LO, HI, carol, 10_000);

        // withdrawing every share first unstakes the LIQ / 4 still staked
        vm.expectEmit(hookAddr);
        emit FablesLedgerV2.Unstaked(carol, rid, LIQ / 4);
        vm.expectEmit(hookAddr);
        emit FablesLedgerV2.Withdrawn(carol, rid, LIQ);
        ledger.withdraw(key, LO, HI, LIQ, carol, 0, 0, block.timestamp);
        vm.stopPrank();
    }

    /// @dev After a sync books the staked cut and the claim fee, each sweep pays its sink and reports it; with nothing
    ///      owed both sweeps are silent no-ops.
    function test_sweepsPayAndReport() public {
        vm.prank(alice);
        ledger.claimFees(key, LO, HI, alice, 10_000); // syncs the range
        IERC20Minimal token = IERC20Minimal(Currency.unwrap(currency0));
        address dist = ledger.distributor();
        uint256 owedD = ledger.distributorOwed(currency0);
        uint256 owedC = ledger.claimFeeOwed(currency0);
        assertGt(owedD, 0);
        assertGt(owedC, 0);

        uint256 before = token.balanceOf(dist);
        vm.expectEmit(hookAddr);
        emit DistributorSwept(currency0, dist, owedD);
        ledger.sweepDistributor(currency0);
        assertEq(ledger.distributorOwed(currency0), 0);
        assertEq(token.balanceOf(dist) - before, owedD);

        before = token.balanceOf(claimFeeRecipient);
        vm.expectEmit(hookAddr);
        emit ClaimFeeSwept(currency0, claimFeeRecipient, owedC);
        ledger.sweepClaimFee(currency0);
        assertEq(ledger.claimFeeOwed(currency0), 0);
        assertEq(token.balanceOf(claimFeeRecipient) - before, owedC);

        vm.recordLogs();
        ledger.sweepClaimFee(currency0);
        ledger.sweepDistributor(currency0);
        assertEq(vm.getRecordedLogs().length, 0, "nothing owed: no transfer, no event");
    }

    /// @dev A fresh LP earns fees in one currency only (single-direction swap), then withdraws and claims: the
    ///      one-sided backlog must be paid and cleared.
    function _withdrawAndClaimOneSided(bool zeroForOne) internal {
        address carol = makeAddr("olympix.carol");
        _fund(carol);
        vm.prank(carol);
        ledger.deposit(key, LO, HI, LIQ, type(uint128).max, type(uint128).max, block.timestamp);
        swap(key, zeroForOne, -1e15, ZERO_BYTES);

        vm.recordLogs();
        vm.prank(carol);
        ledger.withdrawAndClaim(key, LO, HI, LIQ, carol, 0, 0, block.timestamp, 10_000);
        (uint256 paid0, uint256 paid1, bool found) = _feesClaimedOf(carol, vm.getRecordedLogs());

        assertTrue(found, "FeesClaimed not emitted");
        if (zeroForOne) {
            assertGt(paid0, 0);
            assertEq(paid1, 0);
        } else {
            assertEq(paid0, 0);
            assertGt(paid1, 0);
        }
        UserPosition memory p = ledger.userPosition(rid, carol);
        assertEq(p.owed0, 0);
        assertEq(p.owed1, 0);
    }

    function _feesClaimedOf(address owner, Vm.Log[] memory logs)
        internal
        view
        returns (uint256 amount0, uint256 amount1, bool found)
    {
        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory l = logs[i];
            if (
                l.emitter == hookAddr && l.topics[0] == FablesLedgerV2.FeesClaimed.selector
                    && l.topics[1] == bytes32(uint256(uint160(owner)))
            ) {
                (amount0, amount1) = abi.decode(l.data, (uint256, uint256));
                found = true;
            }
        }
    }
}

/// @notice Receives a native payout and, inside it, calls back into the ledger with each prepared call, recording the
///         revert selector of each (zero when a call succeeds).
contract ReentryProbe {
    FablesLedgerV2 internal immutable ledger;
    bytes[] internal inner;
    bytes4[] public seen;
    bool internal armed;

    constructor(FablesLedgerV2 ledger_) {
        ledger = ledger_;
    }

    function approve(address token) external {
        IERC20Minimal(token).approve(address(ledger), type(uint256).max);
    }

    function arm(bytes[] memory calls) external {
        delete inner;
        delete seen;
        for (uint256 i; i < calls.length; ++i) {
            inner.push(calls[i]);
        }
        armed = true;
    }

    function exec(bytes calldata data, uint256 value) external {
        (bool ok, bytes memory ret) = address(ledger).call{value: value}(data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 32), mload(ret))
            }
        }
    }

    function seenCount() external view returns (uint256) {
        return seen.length;
    }

    receive() external payable {
        if (!armed) return;
        armed = false;
        for (uint256 i; i < inner.length; ++i) {
            (bool ok, bytes memory ret) = address(ledger).call(inner[i]);
            seen.push(ok ? bytes4(0) : bytes4(ret));
        }
    }
}

/// @notice FablesHookETH: a native payout hands control to the recipient mid-call; every state-changing ledger entry
///         point must then refuse to run (one shared transient guard), whichever payout opened the window.
contract FablesLedgerV2ReentryOlympixTest is OlympixHookFixture {
    ReentryProbe internal probe;
    uint256 internal nrid;

    function setUp() public {
        _setUpBuild(1);
        nrid = ledger.rangeId(PoolIdLibrary.toId(nativeKey), LO, HI);
        probe = new ReentryProbe(ledger);
        // admin, so the guarded admin setters get past `restricted` to `nonReentrant`
        authority.grantRole(0, address(probe), 0);
        vm.deal(address(probe), 10 ether);
        IERC20Minimal(Currency.unwrap(currency1)).transfer(address(probe), 1e24);
        probe.approve(Currency.unwrap(currency1));
        probe.exec(
            abi.encodeCall(ledger.deposit, (nativeKey, LO, HI, LIQ, 1 ether, type(uint128).max, block.timestamp)),
            1 ether
        );
        // ETH-input swap: the probe's range earns native fees, so claimFees pays it ETH
        swapNativeInput(nativeKey, true, -1e15, ZERO_BYTES, 1e15);
    }

    function test_withdrawPayoutCannotReenter() public {
        _expectEveryReentryRefused(
            abi.encodeCall(ledger.withdraw, (nativeKey, LO, HI, LIQ / 2, address(probe), 0, 0, block.timestamp))
        );
    }

    function test_withdrawAndClaimPayoutCannotReenter() public {
        _expectEveryReentryRefused(
            abi.encodeCall(
                ledger.withdrawAndClaim, (nativeKey, LO, HI, LIQ / 2, address(probe), 0, 0, block.timestamp, 10_000)
            )
        );
    }

    function test_claimPayoutCannotReenter() public {
        _expectEveryReentryRefused(abi.encodeCall(ledger.claimFees, (nativeKey, LO, HI, address(probe), 10_000)));
    }

    function _expectEveryReentryRefused(bytes memory outer) internal {
        bytes[] memory calls = _reentries();
        probe.arm(calls);
        probe.exec(outer, 0);
        assertEq(probe.seenCount(), calls.length, "the payout never reached the probe");
        for (uint256 i; i < calls.length; ++i) {
            assertEq(probe.seen(i), ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector, vm.toString(i));
        }
    }

    function _reentries() internal view returns (bytes[] memory c) {
        Currency[] memory none = new Currency[](0);
        uint256[] memory ids = new uint256[](1);
        ids[0] = nrid;
        address p = address(probe);
        c = new bytes[](14);
        c[0] = abi.encodeCall(ledger.claimFees, (nativeKey, LO, HI, p, 10_000));
        c[1] = abi.encodeCall(ledger.withdraw, (nativeKey, LO, HI, 1, p, 0, 0, block.timestamp));
        c[2] = abi.encodeCall(ledger.withdrawAndClaim, (nativeKey, LO, HI, 1, p, 0, 0, block.timestamp, 10_000));
        c[3] = abi.encodeCall(ledger.stake, (nativeKey, LO, HI, 1, 0));
        c[4] = abi.encodeCall(ledger.unstake, (nativeKey, LO, HI, 1));
        c[5] = abi.encodeCall(ledger.transfer, (bob, nrid, 1));
        c[6] = abi.encodeCall(ledger.transferFrom, (p, bob, nrid, 1));
        c[7] = abi.encodeCall(ledger.syncRanges, (0, ids));
        c[8] = abi.encodeCall(ledger.sweepDistributor, (currency1));
        c[9] = abi.encodeCall(ledger.sweepClaimFee, (currency1));
        c[10] = abi.encodeCall(ledger.setClaimFee, (nativeKey, none, CLAIM_FEE_BPS, claimFeeRecipient));
        c[11] = abi.encodeCall(ledger.setClaimFeeBps, (nativeKey, CLAIM_FEE_BPS));
        c[12] = abi.encodeCall(ledger.setFFFeeSink, (none, address(0)));
        c[13] = abi.encodeCall(ledger.setDistributor, (none, ledger.distributor()));
    }
}
