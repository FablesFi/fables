// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {IERC20Minimal} from "v4-core/src/interfaces/external/IERC20Minimal.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";

import {FablesLedgerV2} from "../../src/base/FablesLedgerV2.sol";
import {RangeState, UserPosition} from "../../src/base/LedgerTypesV2.sol";
import {MockDistributor} from "../utils/mocks/MockDistributor.sol";
import {MockBallotGate} from "../utils/mocks/MockBallotGate.sol";
import {LedgerFixture, levelSince} from "../utils/LedgerFixture.sol";

uint256 constant Q128 = 1 << 128;

/// @notice Ledger walk instrumented for per-action conservation identities.
contract ConservationHandler is Test {
    using CurrencyLibrary for Currency;

    bytes32 internal constant FEES_COLLECTED = keccak256(
        "FeesCollected(uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint128,uint128,uint64,uint64)"
    );
    bytes32 internal constant CLAIM_FEE_ACCRUED = keccak256("ClaimFeeAccrued(uint256,bytes32,uint256,uint256,uint16)");

    struct Snap {
        uint256 owed0;
        uint256 owed1;
        uint256 unstaked;
        uint256 cp0;
        uint256 cp1;
        int256 cp0Slack;
        int256 cp1Slack;
    }

    FablesLedgerV2 public immutable hook;
    IPoolManager public immutable manager;
    PoolSwapTest public immutable swapRouter;
    PoolKey public key;
    PoolId public immutable poolId;
    address public immutable admin;

    address[3] public actors;
    int24[3] public lowers = [int24(-120), -600, -60];
    int24[3] public uppers = [int24(120), 600, 60];

    address public constant swapper = address(0x5AA9);
    address public constant claimFeeSink = address(0xFEE5);
    address public distributor;

    int256 public preSlackQ0;
    int256 public preSlackQ1;

    mapping(uint256 => mapping(address => uint256)) public preEnt0;
    mapping(uint256 => mapping(address => uint256)) public preEnt1;

    uint256 public preDistAccrued0;
    uint256 public preDistAccrued1;
    uint256 public distributorSwept0;
    uint256 public distributorSwept1;

    uint256 public claimingId = type(uint256).max;
    address public claimingActor;

    uint256 public callCount;
    uint256 public depositsLanded;
    uint256 public withdrawsLanded;
    uint256 public withdrawAndClaimsLanded;
    uint256 public preSyncedClaimsLanded;
    uint256 public preSyncedWithFees0;
    uint256 public preSyncedWithFees1;
    uint256 public stakesLanded;
    uint256 public overStakesRefused;
    uint256 public unstakesLanded;
    uint256 public transfersLanded;
    uint256 public claimsLanded;
    uint256 public paidClaimsLanded;
    uint256 public sweepsLanded;
    bytes4 internal constant PRICE_LIMIT_EXCEEDED = bytes4(keccak256("PriceLimitAlreadyExceeded(uint160,uint160)"));
    bytes4 internal constant PRICE_LIMIT_INVALID = bytes4(keccak256("PriceLimitOutOfBounds(uint160)"));
    uint256 public swapsLanded;
    uint256 public slackGrowths;

    constructor(
        FablesLedgerV2 hook_,
        IPoolManager manager_,
        PoolSwapTest swapRouter_,
        PoolKey memory key_,
        address[3] memory actors_,
        address distributor_
    ) {
        hook = hook_;
        manager = manager_;
        swapRouter = swapRouter_;
        key = key_;
        poolId = key_.toId();
        actors = actors_;
        admin = msg.sender;
        distributor = distributor_;
    }

    function entitlementOf(uint256 id, address who) public view returns (uint256 e0, uint256 e1) {
        RangeState memory r = hook.rangeState(id);
        UserPosition memory p = hook.userPosition(id, who);
        e0 = p.owed0;
        e1 = p.owed1;
        uint256 unstaked = hook.balanceOf(who, id) - p.staked;
        if (unstaked != 0) {
            e0 += FullMath.mulDiv(unstaked, levelSince(r.accFee0X128, p.checkpoint0X128), Q128);
            e1 += FullMath.mulDiv(unstaked, levelSince(r.accFee1X128, p.checkpoint1X128), Q128);
        }
    }

    function promisedQ(Currency currency, bool isToken0) public view returns (uint256 q) {
        q = hook.distributorOwed(currency) + hook.claimFeeOwed(currency);
        for (uint256 i = 0; i < 3; i++) {
            uint256 id = hook.rangeId(poolId, lowers[i], uppers[i]);
            for (uint256 a = 0; a < 3; a++) {
                UserPosition memory p = hook.userPosition(id, actors[a]);
                q += isToken0 ? p.owed0 : p.owed1;
            }
        }
        q *= Q128;
        for (uint256 i = 0; i < 3; i++) {
            uint256 id = hook.rangeId(poolId, lowers[i], uppers[i]);
            RangeState memory r = hook.rangeState(id);
            uint256 acc = isToken0 ? r.accFee0X128 : r.accFee1X128;
            for (uint256 a = 0; a < 3; a++) {
                UserPosition memory p = hook.userPosition(id, actors[a]);
                uint256 unstaked = hook.balanceOf(actors[a], id) - p.staked;
                if (unstaked == 0) continue;
                q += unstaked * levelSince(acc, isToken0 ? p.checkpoint0X128 : p.checkpoint1X128);
            }
        }
    }

    function potQ(Currency currency) public view returns (uint256) {
        return manager.balanceOf(address(hook), currency.toId()) * Q128;
    }

    function slackQ(Currency currency, bool isToken0) public view returns (int256) {
        return int256(potQ(currency)) - int256(promisedQ(currency, isToken0));
    }

    modifier observed() {
        claimingId = type(uint256).max;
        claimingActor = address(0);
        preSlackQ0 = slackQ(key.currency0, true);
        preSlackQ1 = slackQ(key.currency1, false);
        preDistAccrued0 = hook.distributorOwed(key.currency0) + distributorSwept0;
        preDistAccrued1 = hook.distributorOwed(key.currency1) + distributorSwept1;
        for (uint256 i = 0; i < 3; i++) {
            uint256 id = hook.rangeId(poolId, lowers[i], uppers[i]);
            for (uint256 a = 0; a < 3; a++) {
                (uint256 e0, uint256 e1) = entitlementOf(id, actors[a]);
                preEnt0[id][actors[a]] = e0;
                preEnt1[id][actors[a]] = e1;
            }
        }
        callCount++;
        vm.recordLogs();
        _;
        _assertTheSkimIsTheRateAgreed();
        if (slackQ(key.currency0, true) > preSlackQ0 || slackQ(key.currency1, false) > preSlackQ1) slackGrowths++;
    }

    function _assertTheSkimIsTheRateAgreed() internal view {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 net0;
        uint256 net1;
        bool sawCollection;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length >= 1 && logs[i].topics[0] == FEES_COLLECTED) {
                (uint256 fee0, uint256 fee1, uint256 stakedCut0, uint256 stakedCut1) =
                    abi.decode(logs[i].data, (uint256, uint256, uint256, uint256));
                net0 += fee0 - stakedCut0;
                net1 += fee1 - stakedCut1;
                sawCollection = true;
            }
        }
        if (!sawCollection) return;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length >= 1 && logs[i].topics[0] == CLAIM_FEE_ACCRUED) {
                (uint256 cut0, uint256 cut1, uint16 bps) = abi.decode(logs[i].data, (uint256, uint256, uint16));
                assertEq(cut0, (net0 * bps) / 10_000, "currency0: the claim fee taken is not the rate advertised");
                assertEq(cut1, (net1 * bps) / 10_000, "currency1: the claim fee taken is not the rate advertised");
            }
        }
    }

    uint256 internal constant ACTOR_COUNT = 3;

    function actorAt(uint256 seed) external view returns (address) {
        return _actor(seed);
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % ACTOR_COUNT];
    }

    function _actorOtherThan(uint256 seed) internal view returns (address) {
        return actors[(seed % ACTOR_COUNT + 1) % ACTOR_COUNT];
    }

    function _range(uint256 seed) internal view returns (int24 lower, int24 upper) {
        uint256 i = seed % 3;
        return (lowers[i], uppers[i]);
    }

    function _assertClearedEqualsPaid(uint256, address, Snap memory pre) internal view {
        int256 allowance = int256(9 * Q128);
        assertLe(
            slackQ(key.currency0, true),
            pre.cp0Slack + allowance,
            "currency0: the claim was cleared for materially more than was paid out"
        );
        assertLe(
            slackQ(key.currency1, false),
            pre.cp1Slack + allowance,
            "currency1: the claim was cleared for materially more than was paid out"
        );
    }

    function _snap(uint256 id, address who) internal view returns (Snap memory s) {
        UserPosition memory p = hook.userPosition(id, who);
        s.owed0 = p.owed0;
        s.owed1 = p.owed1;
        s.unstaked = hook.balanceOf(who, id) - p.staked;
        s.cp0 = p.checkpoint0X128;
        s.cp1 = p.checkpoint1X128;
    }

    function _projected(Snap memory s, uint256 id) internal view returns (uint256 p0, uint256 p1) {
        RangeState memory r = hook.rangeState(id);
        p0 = s.owed0 + FullMath.mulDiv(s.unstaked, levelSince(r.accFee0X128, s.cp0), Q128);
        p1 = s.owed1 + FullMath.mulDiv(s.unstaked, levelSince(r.accFee1X128, s.cp1), Q128);
    }

    function _assertNeutral(uint256 id, address who, Snap memory before_, string memory what) internal view {
        (uint256 p0, uint256 p1) = _projected(before_, id);
        (uint256 e0, uint256 e1) = entitlementOf(id, who);
        assertEq(e0, p0, what);
        assertEq(e1, p1, what);
    }

    function deposit(uint256 actorSeed, uint256 rangeSeed, uint128 liquidity) external observed {
        if (hook.pausedFor(poolId)) return;
        address actor = _actor(actorSeed);
        (int24 lower, int24 upper) = _range(rangeSeed);
        uint256 id = hook.rangeId(poolId, lower, upper);
        liquidity = uint128(bound(liquidity, 1e6, 1e20));
        Snap memory before_ = _snap(id, actor);
        vm.prank(actor);
        hook.deposit(key, lower, upper, liquidity, type(uint128).max, type(uint128).max, block.timestamp);
        _assertNeutral(id, actor, before_, "a deposit moved the depositor's already-earned fees");
        depositsLanded++;
    }

    function withdraw(uint256 actorSeed, uint256 rangeSeed, uint128 liquidity, bool all) external observed {
        address actor = _actor(actorSeed);
        (int24 lower, int24 upper) = _range(rangeSeed);
        uint256 id = hook.rangeId(poolId, lower, upper);
        uint256 balance = hook.balanceOf(actor, id);
        if (balance == 0) return;
        liquidity = all ? uint128(balance) : uint128(bound(liquidity, 1, balance));
        Snap memory before_ = _snap(id, actor);
        vm.prank(actor);
        hook.withdraw(key, lower, upper, liquidity, actor, 0, 0, block.timestamp);
        _assertNeutral(id, actor, before_, "a withdrawal changed what the ledger owes the withdrawer");
        withdrawsLanded++;
    }

    function withdrawAndClaim(uint256 actorSeed, uint256 rangeSeed, uint128 liquidity, uint16 maxFeeBps)
        external
        observed
    {
        address actor = _actor(actorSeed);
        (int24 lower, int24 upper) = _range(rangeSeed);
        uint256 id = hook.rangeId(poolId, lower, upper);
        {
            uint256 balance = hook.balanceOf(actor, id);
            if (balance == 0) return;
            liquidity = uint128(bound(liquidity, 1, balance));
        }
        maxFeeBps = uint16(bound(maxFeeBps, 0, 10_000));
        Snap memory pre = _snap(id, actor);
        pre.cp0Slack = slackQ(key.currency0, true);
        pre.cp1Slack = slackQ(key.currency1, false);
        vm.prank(actor);
        try hook.withdrawAndClaim(key, lower, upper, liquidity, actor, 0, 0, block.timestamp, maxFeeBps) {
            _assertClearedEqualsPaid(id, actor, pre);
            claimingId = id;
            claimingActor = actor;
            withdrawAndClaimsLanded++;
        } catch (bytes memory reason) {
            bytes4 sel = reason.length >= 4 ? bytes4(reason) : bytes4(0);
            if (sel != FablesLedgerV2.LedgerPaused.selector && sel != FablesLedgerV2.ClaimFeeAboveMax.selector) {
                assembly ("memory-safe") {
                    revert(add(reason, 0x20), mload(reason))
                }
            }
        }
    }

    function withdrawAndClaimPreSynced(uint256 actorSeed, uint256 rangeSeed, uint128 liquidity) external observed {
        if (hook.pausedFor(poolId)) return;
        address actor = _actor(actorSeed);
        address other = _actorOtherThan(actorSeed);
        (int24 lower, int24 upper) = _range(rangeSeed);
        uint256 id = hook.rangeId(poolId, lower, upper);
        {
            uint256 balance = hook.balanceOf(actor, id);
            if (balance == 0) return;
            liquidity = uint128(bound(liquidity, 1, balance));
        }
        vm.prank(other);
        hook.deposit(key, lower, upper, 1e6, type(uint128).max, type(uint128).max, block.timestamp);

        (uint256 fee0, uint256 fee1) = entitlementOf(id, actor);
        int256 slack0 = slackQ(key.currency0, true);
        int256 slack1 = slackQ(key.currency1, false);
        vm.prank(actor);
        try hook.withdrawAndClaim(key, lower, upper, liquidity, actor, 0, 0, block.timestamp, 10_000) {
            assertLt(
                slackQ(key.currency0, true) - slack0,
                int256(Q128),
                "currency0: a whole unit of slack appeared with nothing left to credit"
            );
            assertLt(
                slackQ(key.currency1, false) - slack1,
                int256(Q128),
                "currency1: a whole unit of slack appeared with nothing left to credit"
            );
            claimingId = id;
            claimingActor = actor;
            preSyncedClaimsLanded++;
            if (fee0 != 0) preSyncedWithFees0++;
            if (fee1 != 0) preSyncedWithFees1++;
        } catch (bytes memory reason) {
            bytes4 sel = reason.length >= 4 ? bytes4(reason) : bytes4(0);
            if (sel != FablesLedgerV2.LedgerPaused.selector && sel != FablesLedgerV2.ClaimFeeAboveMax.selector) {
                assembly ("memory-safe") {
                    revert(add(reason, 0x20), mload(reason))
                }
            }
        }
    }

    function stake(uint256 actorSeed, uint256 rangeSeed, uint128 shares, bool all) external observed {
        if (hook.pausedFor(poolId)) return;
        address actor = _actor(actorSeed);
        (int24 lower, int24 upper) = _range(rangeSeed);
        uint256 id = hook.rangeId(poolId, lower, upper);
        uint256 free = hook.balanceOf(actor, id) - hook.userPosition(id, actor).staked;
        if (free == 0) return;
        uint256 bal = hook.balanceOf(actor, id);
        shares = all ? uint128(free) : uint128(bound(shares, 1, bal));
        if (shares > free) {
            vm.prank(actor);
            try hook.stake(key, lower, upper, shares, 0) {
                revert("stake accepted more shares than the actor had free");
            } catch (bytes memory err) {
                require(bytes4(err) == FablesLedgerV2.InsufficientUnstakedShares.selector, "wrong refusal");
                overStakesRefused++;
                return;
            }
        }
        Snap memory before_ = _snap(id, actor);
        vm.prank(actor);
        hook.stake(key, lower, upper, shares, 0);
        _assertNeutral(id, actor, before_, "staking reached back into fees earned before the stake");
        stakesLanded++;
    }

    function unstake(uint256 actorSeed, uint256 rangeSeed, uint128 shares) external observed {
        address actor = _actor(actorSeed);
        (int24 lower, int24 upper) = _range(rangeSeed);
        uint256 id = hook.rangeId(poolId, lower, upper);
        uint256 staked = hook.userPosition(id, actor).staked;
        if (staked == 0) return;
        shares = uint128(bound(shares, 1, staked));
        Snap memory before_ = _snap(id, actor);
        vm.prank(actor);
        hook.unstake(key, lower, upper, shares);
        _assertNeutral(id, actor, before_, "unstaking paid out fees the staked window had given up");
        unstakesLanded++;
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 rangeSeed, uint256 amount) external observed {
        if (hook.pausedFor(poolId)) return;
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        if (from == to) return;
        (int24 lower, int24 upper) = _range(rangeSeed);
        uint256 id = hook.rangeId(poolId, lower, upper);
        uint256 free = hook.balanceOf(from, id) - hook.userPosition(id, from).staked;
        if (free == 0) return;
        amount = bound(amount, 1, free);
        Snap memory fromBefore = _snap(id, from);
        Snap memory toBefore = _snap(id, to);
        vm.prank(from);
        hook.transfer(to, id, amount);
        _assertNeutral(id, from, fromBefore, "a transfer took the sender's already-earned fees with it");
        _assertNeutral(id, to, toBefore, "a transfer handed the receiver fees earned before they held");
        transfersLanded++;
    }

    function claim(uint256 actorSeed, uint256 rangeSeed) external observed {
        if (hook.pausedFor(poolId)) return;
        address actor = _actor(actorSeed);
        (int24 lower, int24 upper) = _range(rangeSeed);
        uint256 id = hook.rangeId(poolId, lower, upper);
        UserPosition memory p = hook.userPosition(id, actor);
        if (hook.balanceOf(actor, id) == 0 && p.owed0 == 0 && p.owed1 == 0) return;

        claimingId = id;
        claimingActor = actor;

        Snap memory before_ = _snap(id, actor);
        uint256 bal0 = IERC20Minimal(Currency.unwrap(key.currency0)).balanceOf(actor);
        uint256 bal1 = IERC20Minimal(Currency.unwrap(key.currency1)).balanceOf(actor);
        vm.prank(actor);
        hook.claimFees(key, lower, upper, actor, 10_000);
        uint256 got0 = IERC20Minimal(Currency.unwrap(key.currency0)).balanceOf(actor) - bal0;
        uint256 got1 = IERC20Minimal(Currency.unwrap(key.currency1)).balanceOf(actor) - bal1;

        (uint256 p0, uint256 p1) = _projected(before_, id);
        assertEq(got0, p0, "a claim did not pay what the ledger owed");
        assertEq(got1, p1, "a claim did not pay what the ledger owed");
        (uint256 e0, uint256 e1) = entitlementOf(id, actor);
        assertEq(e0, 0, "a claim left an unpaid remainder booked to the claimant");
        assertEq(e1, 0, "a claim left an unpaid remainder booked to the claimant");
        claimsLanded++;
        if (got0 != 0 || got1 != 0) paidClaimsLanded++;
    }

    function setClaimFee(uint256 bpsSeed) external observed {
        uint16 bps = uint16(bound(bpsSeed, 0, hook.MAX_CLAIM_FEE_BPS()));
        vm.prank(admin);
        hook.setClaimFee(key, new Currency[](0), bps, claimFeeSink);
    }

    function sweep(uint256 seed) external observed {
        if (hook.pausedFor(poolId)) return;
        bool zero = seed % 4 < 2;
        Currency c = zero ? key.currency0 : key.currency1;
        address token = Currency.unwrap(c);
        if (seed % 2 == 0) {
            uint256 owedBefore = hook.distributorOwed(c);
            uint256 sinkBefore = IERC20Minimal(token).balanceOf(distributor);
            hook.sweepDistributor(c);
            uint256 drop = owedBefore - hook.distributorOwed(c);
            assertEq(IERC20Minimal(token).balanceOf(distributor) - sinkBefore, drop, "distributor sweep short-paid");
            if (zero) distributorSwept0 += drop;
            else distributorSwept1 += drop;
        } else {
            uint256 owedBefore = hook.claimFeeOwed(c);
            uint256 sinkBefore = IERC20Minimal(token).balanceOf(claimFeeSink);
            hook.sweepClaimFee(c);
            uint256 drop = owedBefore - hook.claimFeeOwed(c);
            assertEq(IERC20Minimal(token).balanceOf(claimFeeSink) - sinkBefore, drop, "claim-fee sweep short-paid");
        }
        sweepsLanded++;
    }

    function pauseFor(uint256 secs, bool perPool) external observed {
        vm.prank(admin);
        if (perPool) hook.setPoolPaused(key, bound(secs, 0, 6 days));
        else hook.setPaused(bound(secs, 0, 6 days));
    }

    function warp(uint256 secs) external observed {
        vm.warp(block.timestamp + bound(secs, 1 minutes, 3 days));
    }

    function swapAround(uint256 seed, uint128 amount) external observed {
        amount = uint128(bound(amount, 1e12, 1e15));
        bool zeroForOne = seed % 2 == 0;
        vm.startPrank(swapper);
        try swapRouter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(uint256(amount)),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        ) {
            swapsLanded++;
        } catch (bytes memory reason) {
            bytes4 sel = reason.length >= 4 ? bytes4(reason) : bytes4(0);
            if (sel != PRICE_LIMIT_EXCEEDED && sel != PRICE_LIMIT_INVALID) {
                assembly ("memory-safe") {
                    revert(add(reason, 0x20), mload(reason))
                }
            }
        }
        vm.stopPrank();
    }
}

/// @notice Ledger fee conservation per action, exact in Q128, on FablesHook.
abstract contract LedgerConservationInvariantBase is LedgerFixture {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    FablesLedgerV2 hook;
    ConservationHandler handler;
    PoolId poolId;
    address[3] actors;
    address distributor;

    int24[3] lo = [int24(-120), -600, -60];
    int24[3] hi = [int24(120), 600, 60];

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        AccessManager authority = new AccessManager(address(this));
        address hookAddr = _deployBuild(0xC0C0, address(authority));
        hook = FablesLedgerV2(payable(hookAddr));

        key = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(hookAddr));
        _configureFlat(hookAddr, key, 3000, 3000, 10_000);
        poolId = key.toId();

        vm.warp(1785859200);
        _initPool(key, SQRT_PRICE_1_1);
        _beforeSeeding();
        modifyLiquidityRouter.modifyLiquidity(key, LIQUIDITY_PARAMS, ZERO_BYTES);

        actors = [makeAddr("alice"), makeAddr("bob"), makeAddr("carol")];
        address swapper = address(0x5AA9);
        for (uint256 i = 0; i < 4; i++) {
            address who = i < 3 ? actors[i] : swapper;
            assertTrue(IERC20Minimal(Currency.unwrap(currency0)).transfer(who, 1e21));
            assertTrue(IERC20Minimal(Currency.unwrap(currency1)).transfer(who, 1e21));
            vm.startPrank(who);
            IERC20Minimal(Currency.unwrap(currency0)).approve(address(hook), type(uint256).max);
            IERC20Minimal(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);
            IERC20Minimal(Currency.unwrap(currency0)).approve(address(swapRouter), type(uint256).max);
            IERC20Minimal(Currency.unwrap(currency1)).approve(address(swapRouter), type(uint256).max);
            vm.stopPrank();
        }

        distributor = address(new MockDistributor(makeAddr("ff")));
        hook.setDistributor(new Currency[](0), distributor);
        hook.setBallotGate(address(new MockBallotGate()));

        for (uint256 i = 0; i < 3; i++) {
            vm.startPrank(actors[0]);
            hook.deposit(key, lo[i], hi[i], 1e17, type(uint128).max, type(uint128).max, block.timestamp);
            hook.stake(key, lo[i], hi[i], 5e16, 0);
            vm.stopPrank();
        }

        handler = new ConservationHandler(hook, manager, swapRouter, key, actors, distributor);
        targetContract(address(handler));
    }

    function _beforeSeeding() internal virtual {}

    function invariant_theLedgerNeverPromisesMoreThanItHolds() public view {
        assertLe(
            handler.promisedQ(currency0, true), handler.potQ(currency0), "currency0: promised more than the pot holds"
        );
        assertLe(
            handler.promisedQ(currency1, false), handler.potQ(currency1), "currency1: promised more than the pot holds"
        );
    }

    function invariant_slackNeverFalls() public view {
        assertGe(handler.slackQ(currency0, true), handler.preSlackQ0(), "currency0: the ledger over-promised");
        assertGe(handler.slackQ(currency1, false), handler.preSlackQ1(), "currency1: the ledger over-promised");
    }

    function invariant_noHolderIsDilutedByAnothersArrival() public view {
        uint256 exemptId = handler.claimingId();
        address exemptActor = handler.claimingActor();
        for (uint256 i = 0; i < 3; i++) {
            uint256 id = hook.rangeId(poolId, lo[i], hi[i]);
            for (uint256 a = 0; a < 3; a++) {
                address actor = actors[a];
                if (id == exemptId && actor == exemptActor) continue;
                (uint256 e0, uint256 e1) = handler.entitlementOf(id, actor);
                assertGe(e0, handler.preEnt0(id, actor), "currency0: a holder's accrued fees shrank");
                assertGe(e1, handler.preEnt1(id, actor), "currency1: a holder's accrued fees shrank");
            }
        }
    }

    function invariant_theDistributorsAccrualIsNeverClawedBack() public view {
        assertGe(
            hook.distributorOwed(currency0) + handler.distributorSwept0(),
            handler.preDistAccrued0(),
            "currency0: the voters' pot shrank outside a sweep"
        );
        assertGe(
            hook.distributorOwed(currency1) + handler.distributorSwept1(),
            handler.preDistAccrued1(),
            "currency1: the voters' pot shrank outside a sweep"
        );
    }

    function invariant_everyHolderCanExitAndBeMadeWhole() public {
        uint256 snap = vm.snapshotState();

        uint256[3][3] memory owedBefore0;
        uint256[3][3] memory owedBefore1;
        for (uint256 i = 0; i < 3; i++) {
            uint256 id = hook.rangeId(poolId, lo[i], hi[i]);
            for (uint256 a = 0; a < 3; a++) {
                (owedBefore0[i][a], owedBefore1[i][a]) = handler.entitlementOf(id, actors[a]);
            }
        }

        vm.warp(block.timestamp + 8 days);

        for (uint256 i = 0; i < 3; i++) {
            uint256 id = hook.rangeId(poolId, lo[i], hi[i]);
            for (uint256 a = 0; a < 3; a++) {
                address actor = actors[a];
                uint256 staked = hook.userPosition(id, actor).staked;
                if (staked != 0) {
                    vm.prank(actor);
                    hook.unstake(key, lo[i], hi[i], uint128(staked));
                }
                uint256 bal = hook.balanceOf(actor, id);
                if (bal != 0) {
                    vm.prank(actor);
                    hook.withdraw(key, lo[i], hi[i], uint128(bal), actor, 0, 0, block.timestamp);
                }
                uint256 got0 = IERC20Minimal(Currency.unwrap(currency0)).balanceOf(actor);
                uint256 got1 = IERC20Minimal(Currency.unwrap(currency1)).balanceOf(actor);
                UserPosition memory p = hook.userPosition(id, actor);
                if (p.owed0 != 0 || p.owed1 != 0) {
                    vm.prank(actor);
                    hook.claimFees(key, lo[i], hi[i], actor, 10_000);
                }
                got0 = IERC20Minimal(Currency.unwrap(currency0)).balanceOf(actor) - got0;
                got1 = IERC20Minimal(Currency.unwrap(currency1)).balanceOf(actor) - got1;
                assertGe(got0, owedBefore0[i][a], "currency0: an exiting holder was paid less than they were owed");
                assertGe(got1, owedBefore1[i][a], "currency1: an exiting holder was paid less than they were owed");
                (uint256 e0, uint256 e1) = handler.entitlementOf(id, actor);
                assertEq(e0, 0, "currency0: a full exit left fees stranded on the position");
                assertEq(e1, 0, "currency1: a full exit left fees stranded on the position");
            }
        }
        vm.revertToState(snap);
    }

    function test_theWalkReachesTheStatesTheseInvariantsAreAbout() public {
        uint256 id = hook.rangeId(poolId, -120, 120);

        handler.setClaimFee(1000);
        handler.deposit(1, 0, 1e17);
        handler.swapAround(0, 1e15);
        handler.swapAround(1, 1e15);
        handler.deposit(1, 0, 1e17);

        assertGt(handler.potQ(currency0), 0, "the walk's swaps put no fees in the pot");
        assertGt(hook.distributorOwed(currency0), 0, "the walk never credits the voters' pot");
        assertGt(hook.claimFeeOwed(currency0), 0, "the walk never takes a claim fee");
        assertGt(hook.rangeState(id).accFee0X128, 0, "the walk never credits an unstaked holder");

        assertGt(handler.promisedQ(currency0, true), 0, "nothing is ever promised, so solvency is vacuous");
        assertGt(handler.slackQ(currency0, true), int256(0), "slack is always zero, so its monotonicity is vacuous");
        assertGt(handler.slackGrowths(), 0, "slack never moves, so its monotonicity is vacuous");

        (uint256 e0,) = handler.entitlementOf(id, actors[0]);
        assertGt(e0, 0, "no holder ever accrues anything");

        handler.stake(1, 0, 1e16, false);
        handler.stake(1, 0, uint128(hook.balanceOf(handler.actorAt(1), id)), false);
        handler.unstake(1, 0, 1e15);
        handler.transfer(1, 2, 0, 1e15);
        handler.withdraw(1, 0, 1e15, false);
        handler.swapAround(0, 1e15);
        handler.claim(1, 0);
        handler.withdrawAndClaim(1, 0, 1e15, 10_000);
        handler.sweep(0);
        handler.sweep(1);

        assertEq(handler.depositsLanded(), 2, "deposits never land");
        assertEq(handler.stakesLanded(), 1, "stakes never land");
        assertGt(handler.overStakesRefused(), 0, "the walk never attempted an over-stake, so the guard is untested");
        assertEq(handler.unstakesLanded(), 1, "unstakes never land");
        assertEq(handler.transfersLanded(), 1, "transfers never land");
        assertEq(handler.withdrawsLanded(), 1, "withdrawals never land");
        assertEq(handler.claimsLanded(), 1, "claims never land");
        assertEq(handler.paidClaimsLanded(), 1, "claims land but never pay anything");
        assertEq(handler.withdrawAndClaimsLanded(), 1, "the composed withdraw+claim never lands");
        handler.swapAround(0, 1e15);
        handler.swapAround(1, 1e15);
        handler.withdrawAndClaimPreSynced(1, 0, 1e15);
        assertEq(handler.preSyncedClaimsLanded(), 1, "the pre-synced composed claim never lands");
        assertGt(handler.preSyncedWithFees0(), 0, "the pre-synced claim never saw currency0 fees");
        assertGt(handler.preSyncedWithFees1(), 0, "the pre-synced claim never saw currency1 fees");
        assertEq(handler.sweepsLanded(), 2, "sweeps never land");
        assertEq(handler.swapsLanded(), 5, "swaps never land");
    }
}

contract LedgerConservationInvariantTest is LedgerConservationInvariantBase {}
