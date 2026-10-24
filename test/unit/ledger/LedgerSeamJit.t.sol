// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IERC6909Claims} from "v4-core/src/interfaces/external/IERC6909Claims.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";

import {FablesLedgerV2} from "../../../src/base/FablesLedgerV2.sol";
import {Action, PayoutData, FeesCollected} from "../../../src/base/LedgerTypesV2.sol";
import {TestJitHookV2, TestHookV2SeamProbe} from "../../utils/TestJitHookV2.sol";

/// @notice With `_isJit()` true every position-touching ledger path reaches its `_jit*` seam entry; on a resting
///         concrete the defaults revert.
contract LedgerSeamJitTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;

    uint128 constant L = 1e18;

    AccessManager authority;
    TestJitHookV2 jit;
    TestHookV2SeamProbe probe;
    PoolKey jitKey;
    PoolId poolId;
    uint256 bookId;
    int24 lower;
    int24 upper;
    address bob = makeAddr("bob");

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();
        authority = new AccessManager(address(this));
        jit = new TestJitHookV2(manager, address(authority));
        probe = new TestHookV2SeamProbe(manager, address(authority));

        (lower, upper) = (jit.OUTER_LOWER(), jit.OUTER_UPPER());
        jitKey = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(address(jit)));
        poolId = jitKey.toId();
        bookId = jit.rangeId(poolId, lower, upper);
        jit.configure(poolId, 3000);
    }

    function test_isJitIsResolvedPerConcrete() public view {
        assertTrue(jit.isJit());
        assertFalse(probe.isJit());
    }

    function test_depositRoutesToTheSeamAfterTheSharesAreMinted() public {
        jit.deposit(jitKey, lower, upper, L, 11, 22, block.timestamp);

        (uint256 id, uint128 shares, uint128 max0, uint128 max1, uint128 seen, address payer) = jit.lastDeposit();
        assertEq(id, bookId, "the book's range id");
        assertEq(shares, L);
        assertEq(max0, 11, "amount0Max handed through");
        assertEq(max1, 22, "amount1Max handed through");
        assertEq(seen, L, "totalShares already includes the new shares when the seam runs");
        assertEq(payer, address(this));
        assertEq(jit.depositCalls(), 1);
        assertEq(jit.balanceOf(address(this), bookId), L, "receipts minted 1:1");
        assertEq(jit.rangeState(bookId).totalShares, L);
        (,,, bool set) = jit.rangeKey(bookId);
        assertTrue(set, "the range descriptor is registered as for any range");
    }

    function test_theBookEnforcesOneShareClassPerPool() public {
        vm.expectRevert(TestJitHookV2.NotTheBooksRange.selector);
        jit.deposit(jitKey, -60, 60, L, type(uint128).max, type(uint128).max, block.timestamp);
    }

    function test_theRebaseBaselineLogsTheBooksGrowth() public {
        jit.setGrowth(bookId, 11, 22);
        vm.recordLogs();
        jit.deposit(jitKey, lower, upper, L, type(uint128).max, type(uint128).max, block.timestamp);
        Collected memory c = _lastCollected(vm.getRecordedLogs());
        assertEq(c.fee0, 0, "a baseline carries no value");
        assertEq(c.fee1, 0);
        assertEq(c.growth0, 11, "growth0 is the book's level, not a feeGrowthInside read");
        assertEq(c.growth1, 22, "growth1 idem");
        assertEq(c.totalShares, L);
        assertEq(c.collectionSeq, 1, "the baseline consumes the first sequence number");
        assertEq(c.resetSeq, 1, "the up-crossing from zero");
    }

    function test_syncDrainsThePotIntoGrowthAndCreditsWithoutMinting() public {
        jit.deposit(jitKey, lower, upper, L, type(uint128).max, type(uint128).max, block.timestamp);
        jit.fundPot(bookId, 1000, 2000);
        uint256 claims0Before = IERC6909Claims(address(manager)).balanceOf(address(jit), currency0.toId());

        vm.recordLogs();
        jit.syncRange(bookId);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(jit.syncCalls(), 1);
        (uint128 pot0, uint128 pot1, uint256 g0, uint256 g1) = jit.book(bookId);
        assertEq(pot0, 0);
        assertEq(pot1, 0);
        assertEq(g0, FullMath.mulDiv(1000, 1 << 128, L), "growth += pot * 2^128 / totalShares");
        assertEq(g1, FullMath.mulDiv(2000, 1 << 128, L));

        Collected memory c = _lastCollected(logs);
        assertEq(c.fee0, 1000);
        assertEq(c.fee1, 2000);
        assertEq(c.cut0, 0, "nothing staked, no voters' cut");
        assertEq(c.cut1, 0);
        assertEq(c.growth0, g0, "FeesCollected carries the passed growth");
        assertEq(c.growth1, g1);
        assertEq(c.collectionSeq, 2, "after the deposit's baseline");
        assertEq(jit.rangeState(bookId).accFee0X128, FullMath.mulDiv(1000, 1 << 128, L), "all unstaked: full accrual");
        assertEq(jit.rangeState(bookId).accFee1X128, FullMath.mulDiv(2000, 1 << 128, L));

        assertEq(IERC6909Claims(address(manager)).balanceOf(address(jit), currency0.toId()), claims0Before);
        assertEq(IERC6909Claims(address(manager)).balanceOf(address(jit), currency1.toId()), 0);
        for (uint256 i = 0; i < logs.length; i++) {
            assertTrue(logs[i].emitter != address(manager), "the PoolManager was not touched");
        }
    }

    function test_syncOnAnEmptyBookDoesNotReachTheSeam() public {
        jit.fundPot(bookId, 1000, 2000);
        jit.syncRange(bookId);
        assertEq(jit.syncCalls(), 0, "no shares, no drain (the pot would divide by zero)");
        (uint128 pot0,,,) = jit.book(bookId);
        assertEq(pot0, 1000, "the pot waits for shares");
    }

    function test_theSyncFeedsTheClaimFeeSkimLikeAnyCollection() public {
        address treasury = makeAddr("treasury");
        jit.deposit(jitKey, lower, upper, L, type(uint128).max, type(uint128).max, block.timestamp);
        jit.setClaimFee(jitKey, new Currency[](0), 1000, treasury);
        jit.fundPot(bookId, 1000, 2000);
        jit.syncRange(bookId);
        assertEq(jit.claimFeeOwed(currency0), 0, "backlog opened before any rate: charged nothing");
        jit.fundPot(bookId, 1000, 2000);
        jit.syncRange(bookId);
        assertEq(jit.claimFeeOwed(currency0), 100, "10% of the next window's fee0");
        assertEq(jit.claimFeeOwed(currency1), 200);
    }

    function test_rangeGrowthReadsTheBook() public {
        (uint256 g0, uint256 g1) = jit.rangeGrowth(bookId);
        assertEq(g0, 0, "unregistered range: zero, as on any ledger");
        assertEq(g1, 0);
        jit.deposit(jitKey, lower, upper, L, type(uint128).max, type(uint128).max, block.timestamp);
        jit.setGrowth(bookId, 5, 6);
        (g0, g1) = jit.rangeGrowth(bookId);
        assertEq(g0, 5, "the book's level");
        assertEq(g1, 6);
    }

    function test_withdrawRoutesToTheSeamAfterTheSharesAreBurned() public {
        jit.deposit(jitKey, lower, upper, L, type(uint128).max, type(uint128).max, block.timestamp);
        jit.withdraw(jitKey, lower, upper, L / 2, bob, 1, 2, block.timestamp);

        (uint256 id, uint128 shares, uint128 min0, uint128 min1, address to, uint128 seen) = jit.lastWithdraw();
        assertEq(id, bookId);
        assertEq(shares, L / 2);
        assertEq(min0, 1, "amount0Min handed through");
        assertEq(min1, 2, "amount1Min handed through");
        assertEq(to, bob, "the payout target handed through");
        assertEq(seen, L / 2, "totalShares already excludes the burned shares when the seam runs");
        assertEq(jit.withdrawCalls(), 1);
        assertEq(jit.balanceOf(address(this), bookId), L / 2);
        assertEq(jit.rangeState(bookId).totalShares, L / 2);
    }

    function test_withdrawCollectsFromTheBookBeforeBurning() public {
        jit.deposit(jitKey, lower, upper, L, type(uint128).max, type(uint128).max, block.timestamp);
        jit.fundPot(bookId, 1000, 2000);
        vm.recordLogs();
        jit.withdraw(jitKey, lower, upper, L, address(this), 0, 0, block.timestamp);
        Collected memory c = _lastCollected(vm.getRecordedLogs());
        assertEq(jit.syncCalls(), 1, "the exit's own sync drained the book");
        assertEq(c.fee0, 1000);
        assertEq(c.totalShares, L, "collected at pre-burn totals");
        uint256 expected = FullMath.mulDiv(L, FullMath.mulDiv(1000, 1 << 128, L), 1 << 128);
        assertEq(jit.userPosition(bookId, address(this)).owed0, expected, "credited to the exiting holder");
        assertEq(jit.rangeState(bookId).totalShares, 0);
    }

    function test_actionJitReachesJitUnlockWithThePayloadAsEncoded() public {
        bytes memory payload = abi.encode(uint256(42), "hello");
        bytes memory result = jit.unlockJit(payload);
        assertEq(result, abi.encode(keccak256(payload), payload.length), "the book's return travels back");
        assertEq(jit.lastUnlockPayload(), payload, "the payload arrived byte for byte");
    }

    function test_actionJitSliceIsExactForAnUnpaddedPayload() public {
        bytes memory payload = hex"0102030405";
        jit.unlockJit(payload);
        assertEq(jit.lastUnlockPayload(), payload);
        jit.unlockJit("");
        assertEq(jit.lastUnlockPayload(), "");
    }

    function test_otherActionsStillReachTheLibraryOnAJitHook() public {
        bytes memory result =
            jit.unlockRaw(abi.encode(Action.PAYOUT, abi.encode(PayoutData(currency0, currency1, 0, 0, bob))));
        assertEq(result, "");
    }

    function test_theDefaultsRevertOnARestingLiquidityHook() public {
        vm.expectRevert(FablesLedgerV2.NotJitHook.selector);
        probe.jitSync(bookId);
        vm.expectRevert(FablesLedgerV2.NotJitHook.selector);
        probe.jitDeposit(jitKey, bookId, 1, 1, 1);
        vm.expectRevert(FablesLedgerV2.NotJitHook.selector);
        probe.jitWithdraw(jitKey, bookId, 1, 0, 0, bob);
        vm.expectRevert(FablesLedgerV2.NotJitHook.selector);
        probe.jitRangeGrowth(bookId);
        vm.expectRevert(FablesLedgerV2.NotJitHook.selector);
        probe.jitUnlock("");
    }

    function test_actionJitIsNeverRoutedOnARestingLiquidityHook() public {
        vm.expectRevert();
        probe.unlockRaw(abi.encode(Action.JIT, ""));
    }

    struct Collected {
        uint256 fee0;
        uint256 fee1;
        uint256 cut0;
        uint256 cut1;
        uint256 growth0;
        uint256 growth1;
        uint128 totalShares;
        uint64 collectionSeq;
        uint64 resetSeq;
    }

    function _lastCollected(Vm.Log[] memory logs) internal pure returns (Collected memory c) {
        bool found;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] != FeesCollected.selector) continue;
            uint256[12] memory w = abi.decode(logs[i].data, (uint256[12]));
            c.fee0 = w[0];
            c.fee1 = w[1];
            c.cut0 = w[2];
            c.cut1 = w[3];
            c.growth0 = w[6];
            c.growth1 = w[7];
            c.totalShares = uint128(w[8]);
            c.collectionSeq = uint64(w[10]);
            c.resetSeq = uint64(w[11]);
            found = true;
        }
        require(found, "no FeesCollected emitted");
    }
}
