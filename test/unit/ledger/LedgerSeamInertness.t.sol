// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {console2} from "forge-std/console2.sol";
import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {Position} from "v4-core/src/libraries/Position.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IERC20Minimal} from "v4-core/src/interfaces/external/IERC20Minimal.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";

import {FablesLedgerV2} from "../../../src/base/FablesLedgerV2.sol";
import {FeesCollected} from "../../../src/base/LedgerTypesV2.sol";
import {TestHookV2} from "../../utils/TestHookV2.sol";
import {MockDistributor} from "../../utils/mocks/MockDistributor.sol";
import {MockBallotGate} from "../../utils/mocks/MockBallotGate.sol";

/// @notice With `_isJit()` false the ledger behaves as a plain resting-liquidity ledger, and the seam adds no gas to
///         its entry points.
contract LedgerSeamInertnessTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint128 constant DEPOSIT_LIQ = 5e17;
    address constant HOOK_ADDR = address(uint160(0x4444 << 144));

    uint256 constant GAS_BUDGET = 100;
    uint256 constant BASE_DEPOSIT_NEW_RANGE = 365_670;
    uint256 constant BASE_DEPOSIT_FEES_PENDING = 374_970;
    uint256 constant BASE_DEPOSIT_QUIET = 88_457;
    uint256 constant BASE_STAKE_FEES_PENDING = 81_702;
    uint256 constant BASE_UNSTAKE_FEES_PENDING = 263_492;
    uint256 constant BASE_TRANSFER_QUIET = 152_667;
    uint256 constant BASE_CLAIM_FEES_PENDING = 108_831;
    uint256 constant BASE_WITHDRAW_FEES_PENDING = 141_176;
    uint256 constant BASE_SWEEP_CLAIM_FEE = 45_528;
    uint256 constant BASE_SWEEP_DISTRIBUTOR = 43_835;
    uint256 constant BASE_WITHDRAW_AND_CLAIM = 197_500;
    uint256 constant BASE_WITHDRAW_QUIET_EMPTYING = 84_232;

    AccessManager authority;
    TestHookV2 hook;
    PoolId poolId;
    uint256 rid;
    address treasury = makeAddr("treasury");
    address distributor;
    address bob = makeAddr("bob");

    function setUp() public {
        distributor = address(new MockDistributor(makeAddr("ff")));
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        authority = new AccessManager(address(this));
        deployCodeTo("TestHookV2.sol:TestHookV2", abi.encode(manager, address(authority)), HOOK_ADDR);
        hook = TestHookV2(HOOK_ADDR);

        key = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(HOOK_ADDR));
        poolId = key.toId();
        rid = hook.rangeId(poolId, -120, 120);

        hook.configure(poolId, 3000);
        manager.initialize(key, SQRT_PRICE_1_1);
        vm.prank(HOOK_ADDR);
        manager.updateDynamicLPFee(key, 3000);

        modifyLiquidityRouter.modifyLiquidity(key, LIQUIDITY_PARAMS, ZERO_BYTES);

        hook.setBallotGate(address(new MockBallotGate()));

        IERC20Minimal(Currency.unwrap(currency0)).approve(address(hook), type(uint256).max);
        IERC20Minimal(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);
    }

    function positionLiquidity() internal view returns (uint128 liq) {
        bytes32 positionKey = Position.calculatePositionKey(address(hook), -120, 120, bytes32(0));
        liq = manager.getPositionLiquidity(poolId, positionKey);
    }

    function generateFees() internal {
        swap(key, true, -1e15, ZERO_BYTES);
        swap(key, false, -1e15, ZERO_BYTES);
    }

    function bal0(address who) internal view returns (uint256) {
        return IERC20Minimal(Currency.unwrap(currency0)).balanceOf(who);
    }

    function test_depositMintsSharesOneToOneWithPosition() public {
        hook.deposit(key, -120, 120, DEPOSIT_LIQ, type(uint128).max, type(uint128).max, block.timestamp);
        assertEq(hook.balanceOf(address(this), rid), DEPOSIT_LIQ);
        assertEq(positionLiquidity(), DEPOSIT_LIQ);
        assertEq(hook.rangeState(rid).totalShares, DEPOSIT_LIQ);
    }

    function test_withdrawReturnsPrincipal() public {
        hook.deposit(key, -120, 120, DEPOSIT_LIQ, type(uint128).max, type(uint128).max, block.timestamp);
        uint256 before = bal0(address(this));
        hook.withdraw(key, -120, 120, DEPOSIT_LIQ, address(this), 0, 0, block.timestamp);
        assertGt(bal0(address(this)), before);
        assertEq(hook.balanceOf(address(this), rid), 0);
        assertEq(positionLiquidity(), 0);
        assertEq(hook.rangeState(rid).totalShares, 0);
    }

    function test_withdrawIsUnconditional() public {
        hook.deposit(key, -120, 120, DEPOSIT_LIQ, type(uint128).max, type(uint128).max, block.timestamp);
        hook.stake(key, -120, 120, DEPOSIT_LIQ / 2, 0);
        hook.setPaused(1 days);
        hook.setClaimFee(key, new Currency[](0), 2000, treasury);
        vm.expectRevert(FablesLedgerV2.LedgerPaused.selector);
        hook.deposit(key, -120, 120, 1e15, type(uint128).max, type(uint128).max, block.timestamp);
        vm.expectRevert(FablesLedgerV2.LedgerPaused.selector);
        hook.claimFees(key, -120, 120, address(this), 10_000);
        vm.expectRevert(FablesLedgerV2.LedgerPaused.selector);
        hook.stake(key, -120, 120, 1, 0);
        vm.expectRevert(FablesLedgerV2.LedgerPaused.selector);
        hook.transfer(bob, rid, 1);
        hook.unstake(key, -120, 120, 1);
        hook.withdraw(key, -120, 120, DEPOSIT_LIQ, address(this), 0, 0, block.timestamp);
        assertEq(hook.balanceOf(address(this), rid), 0);
        assertEq(hook.rangeState(rid).totalStaked, 0);
    }

    function test_withdrawAutoUnstakes() public {
        hook.deposit(key, -120, 120, DEPOSIT_LIQ, type(uint128).max, type(uint128).max, block.timestamp);
        hook.stake(key, -120, 120, DEPOSIT_LIQ, 0);
        hook.withdraw(key, -120, 120, DEPOSIT_LIQ, address(this), 0, 0, block.timestamp);
        assertEq(hook.balanceOf(address(this), rid), 0);
        assertEq(hook.rangeState(rid).totalStaked, 0);
    }

    function test_feesAccrueAndClaim() public {
        hook.deposit(key, -120, 120, DEPOSIT_LIQ, type(uint128).max, type(uint128).max, block.timestamp);
        generateFees();
        uint256 before = bal0(address(this));
        hook.claimFees(key, -120, 120, address(this), 10_000);
        assertGt(bal0(address(this)), before);
        uint256 after_ = bal0(address(this));
        hook.claimFees(key, -120, 120, address(this), 10_000);
        assertEq(bal0(address(this)), after_);
    }

    function test_claimFeeTakesCutFromFeesOnly() public {
        hook.setClaimFee(key, new Currency[](0), 1000, treasury);
        hook.deposit(key, -120, 120, DEPOSIT_LIQ, type(uint128).max, type(uint128).max, block.timestamp);
        generateFees();
        hook.claimFees(key, -120, 120, address(this), 10_000);
        assertGt(hook.claimFeeOwed(currency0), 0);
        hook.sweepClaimFee(currency0);
        assertGt(bal0(treasury), 0);
        assertEq(hook.claimFeeOwed(currency0), 0);
    }

    function test_stakedFeesRouteToDistributor() public {
        hook.deposit(key, -120, 120, DEPOSIT_LIQ, type(uint128).max, type(uint128).max, block.timestamp);
        hook.stake(key, -120, 120, DEPOSIT_LIQ, 0);
        generateFees();
        hook.claimFees(key, -120, 120, address(this), 10_000);
        assertGt(hook.distributorOwed(currency0), 0);

        hook.setDistributor(new Currency[](0), distributor);
        hook.sweepDistributor(currency0);
        assertGt(bal0(distributor), 0);
        assertEq(hook.distributorOwed(currency0), 0);
    }

    function test_sweepingTheProtocolCutCannotReachTheVotersPot() public {
        hook.deposit(key, -120, 120, DEPOSIT_LIQ, type(uint128).max, type(uint128).max, block.timestamp);
        hook.stake(key, -120, 120, DEPOSIT_LIQ / 2, 0);
        hook.setClaimFee(key, new Currency[](0), 2000, treasury);
        generateFees();
        hook.claimFees(key, -120, 120, address(this), 2000);

        uint256 votersPot = hook.distributorOwed(currency0);
        assertGt(votersPot, 0, "fixture: the voters must be owed something");

        for (uint256 i = 0; i < 3; i++) {
            uint256 potBefore = hook.distributorOwed(currency0);
            uint256 cutBefore = hook.claimFeeOwed(currency0);
            hook.sweepClaimFee(currency0);
            assertEq(hook.claimFeeOwed(currency0), 0, "the sweep left its own bucket behind");
            assertEq(hook.distributorOwed(currency0), potBefore, "a protocol sweep moved the voters' pot");
            assertEq(bal0(treasury) > 0, cutBefore > 0);

            generateFees();
            hook.claimFees(key, -120, 120, address(this), 2000);
        }

        assertGt(hook.distributorOwed(currency0), votersPot, "the voters kept accruing throughout");
    }

    function test_theCollectionAndResetCountersTrackTheIndexerSignals() public {
        hook.deposit(key, -120, 120, DEPOSIT_LIQ, type(uint128).max, type(uint128).max, block.timestamp);
        hook.stake(key, -120, 120, DEPOSIT_LIQ / 2, 0);

        generateFees();
        Collected memory c1 = _collect();
        assertEq(c1.collectionSeq, 2, "the creating deposit's baseline consumed seq 1");
        assertEq(c1.resetSeq, 1, "the position was created once");
        assertGt(c1.fee0, 0);
        (uint256 g0, uint256 g1) = manager.getFeeGrowthInside(poolId, -120, 120);
        assertEq(c1.growth0, g0, "growth0 is v4's feeGrowthInside");
        assertEq(c1.growth1, g1, "growth1 is v4's feeGrowthInside");
        (uint256 v0, uint256 v1) = hook.rangeGrowth(rid);
        assertEq(v0, g0, "rangeGrowth reads v4");
        assertEq(v1, g1, "rangeGrowth reads v4");

        generateFees();
        Collected memory c2 = _collect();
        assertEq(c2.collectionSeq, 3);
        assertEq(c2.resetSeq, 1);

        hook.withdraw(key, -120, 120, DEPOSIT_LIQ, address(this), 0, 0, block.timestamp);
        assertEq(hook.rangeState(rid).totalShares, 0);
        hook.deposit(key, -120, 120, DEPOSIT_LIQ, type(uint128).max, type(uint128).max, block.timestamp);
        hook.stake(key, -120, 120, DEPOSIT_LIQ / 2, 0);

        generateFees();
        Collected memory c3 = _collect();
        assertEq(c3.collectionSeq, 5, "the refill's baseline consumed seq 4");
        assertEq(c3.resetSeq, 3, "two zero-crossings advanced resetSeq by two");
    }

    function test_gas_everyLedgerDoorStaysWithinBudget() public {
        hook.setClaimFee(key, new Currency[](0), 1000, treasury);
        hook.setDistributor(new Currency[](0), distributor);

        uint256 g = gasleft();
        hook.deposit(key, -120, 120, DEPOSIT_LIQ, type(uint128).max, type(uint128).max, block.timestamp);
        _check("deposit (new range)", g - gasleft(), BASE_DEPOSIT_NEW_RANGE);

        generateFees();
        g = gasleft();
        hook.deposit(key, -120, 120, DEPOSIT_LIQ, type(uint128).max, type(uint128).max, block.timestamp);
        _check("deposit (fees pending)", g - gasleft(), BASE_DEPOSIT_FEES_PENDING);

        g = gasleft();
        hook.deposit(key, -120, 120, DEPOSIT_LIQ, type(uint128).max, type(uint128).max, block.timestamp);
        _check("deposit (quiet)", g - gasleft(), BASE_DEPOSIT_QUIET);

        generateFees();
        g = gasleft();
        hook.stake(key, -120, 120, DEPOSIT_LIQ, 0);
        _check("stake (fees pending)", g - gasleft(), BASE_STAKE_FEES_PENDING);

        generateFees();
        g = gasleft();
        hook.unstake(key, -120, 120, DEPOSIT_LIQ / 2);
        _check("unstake (fees pending)", g - gasleft(), BASE_UNSTAKE_FEES_PENDING);

        g = gasleft();
        hook.transfer(bob, rid, 1e15);
        _check("transfer (quiet)", g - gasleft(), BASE_TRANSFER_QUIET);

        generateFees();
        g = gasleft();
        hook.claimFees(key, -120, 120, address(this), 10_000);
        _check("claimFees (fees pending)", g - gasleft(), BASE_CLAIM_FEES_PENDING);

        generateFees();
        g = gasleft();
        hook.withdraw(key, -120, 120, DEPOSIT_LIQ, address(this), 0, 0, block.timestamp);
        _check("withdraw (fees pending)", g - gasleft(), BASE_WITHDRAW_FEES_PENDING);

        g = gasleft();
        hook.sweepClaimFee(currency0);
        _check("sweepClaimFee", g - gasleft(), BASE_SWEEP_CLAIM_FEE);

        g = gasleft();
        hook.sweepDistributor(currency0);
        _check("sweepDistributor", g - gasleft(), BASE_SWEEP_DISTRIBUTOR);

        generateFees();
        g = gasleft();
        hook.withdrawAndClaim(key, -120, 120, DEPOSIT_LIQ, address(this), 0, 0, block.timestamp, 10_000);
        _check("withdrawAndClaim (fees pending)", g - gasleft(), BASE_WITHDRAW_AND_CLAIM);

        uint128 rest = uint128(hook.balanceOf(address(this), rid));
        assertEq(rest, DEPOSIT_LIQ - 1e15);
        g = gasleft();
        hook.withdraw(key, -120, 120, rest, address(this), 0, 0, block.timestamp);
        _check("withdraw (quiet, emptying)", g - gasleft(), BASE_WITHDRAW_QUIET_EMPTYING);
        vm.prank(bob);
        hook.withdraw(key, -120, 120, 1e15, bob, 0, 0, block.timestamp);
        assertEq(hook.rangeState(rid).totalShares, 0);
    }

    function _check(string memory door, uint256 used, uint256 base) internal pure {
        console2.log(door, used);
        if (base != 0) assertLe(used, base + GAS_BUDGET, door);
    }

    struct Collected {
        uint256 fee0;
        uint256 fee1;
        uint256 growth0;
        uint256 growth1;
        uint64 collectionSeq;
        uint64 resetSeq;
    }

    function _collect() internal returns (Collected memory c) {
        vm.recordLogs();
        hook.claimFees(key, -120, 120, address(this), 10_000);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] != FeesCollected.selector) continue;
            (c.fee0, c.fee1,,,,, c.growth0, c.growth1,,, c.collectionSeq, c.resetSeq) = abi.decode(
                logs[i].data,
                (
                    uint256,
                    uint256,
                    uint256,
                    uint256,
                    uint256,
                    uint256,
                    uint256,
                    uint256,
                    uint128,
                    uint128,
                    uint64,
                    uint64
                )
            );
            found = true;
        }
        assertTrue(found, "no FeesCollected emitted");
    }
}
