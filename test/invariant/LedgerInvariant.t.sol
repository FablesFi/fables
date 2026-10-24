// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {Position} from "v4-core/src/libraries/Position.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {IERC20Minimal} from "v4-core/src/interfaces/external/IERC20Minimal.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

import {FablesLedgerV2} from "../../src/base/FablesLedgerV2.sol";
import {RangeState, UserPosition} from "../../src/base/LedgerTypesV2.sol";
import {MockDistributor} from "../utils/mocks/MockDistributor.sol";
import {MockBallotGate} from "../utils/mocks/MockBallotGate.sol";
import {LedgerFixture, levelSince} from "../utils/LedgerFixture.sol";

/// @notice Random walk over every ledger entry point across three ranges and three actors.
contract LedgerHandler is Test {
    FablesLedgerV2 public immutable hook;
    PoolSwapTest public immutable swapRouter;
    PoolKey public key;
    PoolId public immutable poolId;
    address[3] public actors;
    int24[3] public lowers = [int24(-120), -600, -60];
    int24[3] public uppers = [int24(120), 600, 60];

    uint256 public callCount;

    modifier counted() {
        callCount++;
        _;
    }

    uint256 public withdrawAndClaimsLanded;
    uint256 public refusedWhilePaused;
    uint256 public overStakesRefused;
    uint256 public swapsLanded;
    bytes4 internal constant PRICE_LIMIT_EXCEEDED = bytes4(keccak256("PriceLimitAlreadyExceeded(uint160,uint160)"));
    bytes4 internal constant PRICE_LIMIT_INVALID = bytes4(keccak256("PriceLimitOutOfBounds(uint160)"));

    uint256 public claimedTotal0;
    uint256 public claimedTotal1;
    address public immutable admin;
    address public constant feeSink = address(0xFEE5);

    constructor(FablesLedgerV2 hook_, PoolSwapTest swapRouter_, PoolKey memory key_, address[3] memory actors_) {
        hook = hook_;
        swapRouter = swapRouter_;
        key = key_;
        poolId = key_.toId();
        actors = actors_;
        admin = msg.sender;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % 3];
    }

    function _range(uint256 seed) internal view returns (int24 lower, int24 upper) {
        uint256 i = seed % 3;
        return (lowers[i], uppers[i]);
    }

    function deposit(uint256 actorSeed, uint256 rangeSeed, uint128 liquidity) external counted {
        if (hook.pausedUntil() > block.timestamp) return;
        liquidity = uint128(bound(liquidity, 1e6, 1e20));
        (int24 lower, int24 upper) = _range(rangeSeed);
        vm.prank(_actor(actorSeed));
        hook.deposit(key, lower, upper, liquidity, type(uint128).max, type(uint128).max, block.timestamp);
    }

    function withdrawAll(uint256 actorSeed, uint256 rangeSeed) external counted {
        address actor = _actor(actorSeed);
        (int24 lower, int24 upper) = _range(rangeSeed);
        uint256 balance = hook.balanceOf(actor, hook.rangeId(poolId, lower, upper));
        if (balance == 0) return;
        vm.prank(actor);
        hook.withdraw(key, lower, upper, uint128(balance), address(this), 0, 0, block.timestamp);
    }

    function withdraw(uint256 actorSeed, uint256 rangeSeed, uint128 liquidity) external counted {
        address actor = _actor(actorSeed);
        (int24 lower, int24 upper) = _range(rangeSeed);
        uint256 id = hook.rangeId(poolId, lower, upper);
        uint256 balance = hook.balanceOf(actor, id);
        if (balance == 0) return;
        liquidity = uint128(bound(liquidity, 1, balance));
        vm.prank(actor);
        hook.withdraw(key, lower, upper, liquidity, address(this), 0, 0, block.timestamp);
    }

    function withdrawAndClaim(uint256 actorSeed, uint256 rangeSeed, uint128 liquidity, uint16 maxFeeBps)
        external
        counted
    {
        address actor = _actor(actorSeed);
        (int24 lower, int24 upper) = _range(rangeSeed);
        uint256 id = hook.rangeId(poolId, lower, upper);
        uint256 balance = hook.balanceOf(actor, id);
        if (balance == 0) return;
        liquidity = uint128(bound(liquidity, 1, balance));
        maxFeeBps = uint16(bound(maxFeeBps, 0, 10_000));
        vm.prank(actor);
        try hook.withdrawAndClaim(key, lower, upper, liquidity, address(this), 0, 0, block.timestamp, maxFeeBps) {
            withdrawAndClaimsLanded++;
        } catch (bytes memory reason) {
            bytes4 sel = reason.length >= 4 ? bytes4(reason) : bytes4(0);
            if (sel != FablesLedgerV2.LedgerPaused.selector && sel != FablesLedgerV2.ClaimFeeAboveMax.selector) {
                assembly ("memory-safe") {
                    revert(add(reason, 0x20), mload(reason))
                }
            }
            if (sel == FablesLedgerV2.LedgerPaused.selector) refusedWhilePaused++;
        }
    }

    function stake(uint256 actorSeed, uint256 rangeSeed, uint128 shares) external counted {
        if (hook.pausedUntil() > block.timestamp) return;
        address actor = _actor(actorSeed);
        (int24 lower, int24 upper) = _range(rangeSeed);
        uint256 id = hook.rangeId(poolId, lower, upper);
        uint256 free = hook.balanceOf(actor, id) - hook.userPosition(id, actor).staked;
        if (free == 0) return;
        uint256 bal = hook.balanceOf(actor, id);
        shares = uint128(bound(shares, 1, bal));
        vm.prank(actor);
        if (shares > free) {
            try hook.stake(key, lower, upper, shares, 0) {
                revert("stake accepted more shares than the actor had free");
            } catch (bytes memory err) {
                require(bytes4(err) == FablesLedgerV2.InsufficientUnstakedShares.selector, "wrong refusal");
                overStakesRefused++;
                return;
            }
        }
        hook.stake(key, lower, upper, shares, 0);
    }

    function unstake(uint256 actorSeed, uint256 rangeSeed, uint128 shares) external counted {
        address actor = _actor(actorSeed);
        (int24 lower, int24 upper) = _range(rangeSeed);
        uint256 id = hook.rangeId(poolId, lower, upper);
        uint256 staked = hook.userPosition(id, actor).staked;
        if (staked == 0) return;
        shares = uint128(bound(shares, 1, staked));
        vm.prank(actor);
        hook.unstake(key, lower, upper, shares);
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 rangeSeed, uint256 amount) external counted {
        if (hook.pausedUntil() > block.timestamp) return;
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        if (from == to) return;
        (int24 lower, int24 upper) = _range(rangeSeed);
        uint256 id = hook.rangeId(poolId, lower, upper);
        uint256 free = hook.balanceOf(from, id) - hook.userPosition(id, from).staked;
        if (free == 0) return;
        amount = bound(amount, 1, free);
        vm.prank(from);
        hook.transfer(to, id, amount);
    }

    function claim(uint256 actorSeed, uint256 rangeSeed) external counted {
        if (hook.pausedUntil() > block.timestamp) return;
        address actor = _actor(actorSeed);
        (int24 lower, int24 upper) = _range(rangeSeed);
        uint256 before0 = IERC20Minimal(Currency.unwrap(key.currency0)).balanceOf(actor);
        uint256 before1 = IERC20Minimal(Currency.unwrap(key.currency1)).balanceOf(actor);
        uint256 id = hook.rangeId(key.toId(), lower, upper);
        UserPosition memory p = hook.userPosition(id, actor);
        if (hook.balanceOf(actor, id) == 0 && p.owed0 == 0 && p.owed1 == 0) return;
        vm.prank(actor);
        hook.claimFees(key, lower, upper, actor, 10_000);
        claimedTotal0 += IERC20Minimal(Currency.unwrap(key.currency0)).balanceOf(actor) - before0;
        claimedTotal1 += IERC20Minimal(Currency.unwrap(key.currency1)).balanceOf(actor) - before1;
    }

    function stakeAll(uint256 actorSeed, uint256 rangeSeed) external counted {
        if (hook.pausedUntil() > block.timestamp) return;
        address actor = _actor(actorSeed);
        (int24 lower, int24 upper) = _range(rangeSeed);
        uint256 id = hook.rangeId(key.toId(), lower, upper);
        uint256 free = hook.balanceOf(actor, id) - hook.userPosition(id, actor).staked;
        if (free == 0) return;
        vm.prank(actor);
        hook.stake(key, lower, upper, uint128(free), 0);
    }

    function setClaimFee(uint256 bpsSeed) external counted {
        uint16 bps = uint16(bound(bpsSeed, 0, hook.MAX_CLAIM_FEE_BPS()));
        vm.prank(admin);
        hook.setClaimFee(key, new Currency[](0), bps, feeSink);
    }

    function sweep(uint256 seed) external counted {
        if (hook.pausedUntil() > block.timestamp) return;
        if (seed % 2 == 0) {
            hook.sweepDistributor(seed % 4 < 2 ? key.currency0 : key.currency1);
        } else {
            hook.sweepClaimFee(seed % 4 < 2 ? key.currency0 : key.currency1);
        }
    }

    function pauseFor(uint256 secs) external counted {
        vm.prank(admin);
        hook.setPaused(bound(secs, 0, 6 days));
    }

    function warp(uint256 secs) external counted {
        vm.warp(block.timestamp + bound(secs, 1 minutes, 3 days));
    }

    function swapAround(uint256 seed, uint128 amount) external counted {
        amount = uint128(bound(amount, 1e12, 1e15));
        bool zeroForOne = seed % 2 == 0;
        vm.startPrank(actors[0]);
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

/// @notice Ledger share and stake accounting, solvency, exit totality and dust bound on FablesHook.
abstract contract LedgerInvariantBase is LedgerFixture {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    FablesLedgerV2 hook;
    LedgerHandler handler;
    PoolId poolId;
    address[3] actors;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        AccessManager authority = new AccessManager(address(this));
        address hookAddr = _deployBuild(0xDDDD, address(authority));
        hook = FablesLedgerV2(payable(hookAddr));

        key = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(hookAddr));
        _configureFlat(hookAddr, key, 3000, 3000, 10_000);
        poolId = key.toId();

        vm.warp(1785859200);
        _initPool(key, SQRT_PRICE_1_1);
        _beforeSeeding();
        modifyLiquidityRouter.modifyLiquidity(key, LIQUIDITY_PARAMS, ZERO_BYTES);

        actors = [makeAddr("alice"), makeAddr("bob"), makeAddr("carol")];
        for (uint256 i = 0; i < 3; i++) {
            assertTrue(IERC20Minimal(Currency.unwrap(currency0)).transfer(actors[i], 1e21));
            assertTrue(IERC20Minimal(Currency.unwrap(currency1)).transfer(actors[i], 1e21));
            vm.startPrank(actors[i]);
            IERC20Minimal(Currency.unwrap(currency0)).approve(address(hook), type(uint256).max);
            IERC20Minimal(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);
            IERC20Minimal(Currency.unwrap(currency0)).approve(address(swapRouter), type(uint256).max);
            IERC20Minimal(Currency.unwrap(currency1)).approve(address(swapRouter), type(uint256).max);
            vm.stopPrank();
        }

        hook.setDistributor(new Currency[](0), address(new MockDistributor(makeAddr("ff"))));
        hook.setBallotGate(address(new MockBallotGate()));

        int24[3] memory lo = [int24(-120), -600, -60];
        int24[3] memory hi = [int24(120), 600, 60];
        for (uint256 i = 0; i < 3; i++) {
            vm.startPrank(actors[0]);
            hook.deposit(key, lo[i], hi[i], 1e17, type(uint128).max, type(uint128).max, block.timestamp);
            hook.stake(key, lo[i], hi[i], 5e16, 0);
            vm.stopPrank();
        }

        handler = new LedgerHandler(hook, swapRouter, key, actors);
        targetContract(address(handler));
    }

    function _beforeSeeding() internal virtual {}

    function rangeLiquidity(int24 lower, int24 upper) internal view returns (uint128) {
        return
            manager.getPositionLiquidity(poolId, Position.calculatePositionKey(address(hook), lower, upper, bytes32(0)));
    }

    function invariant_stakedResidualStaysSubUnit() public view {
        int24[3] memory lo = [int24(-120), -600, -60];
        int24[3] memory hi = [int24(120), 600, 60];
        for (uint256 i = 0; i < 3; i++) {
            uint256 id = hook.rangeId(poolId, lo[i], hi[i]);
            RangeState memory r = hook.rangeState(id);
            assertLt(uint256(r.stakedResidual0), 1 << 128, "residual escaped the sub-unit range");
            assertLt(uint256(r.stakedResidual1), 1 << 128, "residual escaped the sub-unit range");
        }
    }

    function invariant_everyActorCanAlwaysExit() public {
        uint256 snap = vm.snapshotState();
        int24[3] memory lo = [int24(-120), -600, -60];
        int24[3] memory hi = [int24(120), 600, 60];
        for (uint256 a = 0; a < 3; a++) {
            address actor = handler.actors(a);
            for (uint256 i = 0; i < 3; i++) {
                uint256 bal = hook.balanceOf(actor, hook.rangeId(poolId, lo[i], hi[i]));
                if (bal == 0) continue;
                vm.prank(actor);
                hook.withdraw(key, lo[i], hi[i], uint128(bal), actor, 0, 0, block.timestamp);
            }
        }
        vm.revertToState(snap);
    }

    function invariant_sharesMatchPositionLiquidity() public view {
        int24[3] memory lowers = [int24(-120), -600, -60];
        int24[3] memory uppers = [int24(120), 600, 60];
        for (uint256 i = 0; i < 3; i++) {
            uint256 id = hook.rangeId(poolId, lowers[i], uppers[i]);
            assertEq(hook.rangeState(id).totalShares, rangeLiquidity(lowers[i], uppers[i]));
        }
    }

    function invariant_stakeAccountingConsistent() public view {
        int24[3] memory lowers = [int24(-120), -600, -60];
        int24[3] memory uppers = [int24(120), 600, 60];
        for (uint256 i = 0; i < 3; i++) {
            uint256 id = hook.rangeId(poolId, lowers[i], uppers[i]);
            uint256 sumStaked;
            uint256 sumBalances;
            for (uint256 a = 0; a < 3; a++) {
                sumStaked += hook.userPosition(id, actors[a]).staked;
                sumBalances += hook.balanceOf(actors[a], id);
                assertLe(hook.userPosition(id, actors[a]).staked, hook.balanceOf(actors[a], id));
            }
            assertEq(sumStaked, hook.rangeState(id).totalStaked);
            assertEq(sumBalances, hook.rangeState(id).totalShares);
            assertLe(hook.rangeState(id).totalStaked, hook.rangeState(id).totalShares);
        }
    }

    function invariant_feePotSolvent() public view {
        int24[3] memory lowers = [int24(-120), -600, -60];
        int24[3] memory uppers = [int24(120), 600, 60];
        uint256 owed0 = hook.distributorOwed(currency0) + hook.claimFeeOwed(currency0);
        uint256 owed1 = hook.distributorOwed(currency1) + hook.claimFeeOwed(currency1);
        for (uint256 i = 0; i < 3; i++) {
            uint256 id = hook.rangeId(poolId, lowers[i], uppers[i]);
            RangeState memory range = hook.rangeState(id);
            for (uint256 a = 0; a < 3; a++) {
                UserPosition memory position = hook.userPosition(id, actors[a]);
                owed0 += position.owed0;
                owed1 += position.owed1;
                uint256 unstaked = hook.balanceOf(actors[a], id) - position.staked;
                if (unstaked != 0) {
                    // forge-lint: disable-start(divide-before-multiply)
                    owed0 += FullMath.mulDiv(
                        unstaked, levelSince(range.accFee0X128, position.checkpoint0X128), 1 << 128
                    );
                    owed1 += FullMath.mulDiv(
                        unstaked, levelSince(range.accFee1X128, position.checkpoint1X128), 1 << 128
                    );
                    // forge-lint: disable-end(divide-before-multiply)
                }
            }
        }
        assertLe(owed0, manager.balanceOf(address(hook), CurrencyLibrary.toId(currency0)));
        assertLe(owed1, manager.balanceOf(address(hook), CurrencyLibrary.toId(currency1)));
    }

    function test_theHandlersActionsActuallyReachTheLedger() public {
        uint256 id = hook.rangeId(poolId, -120, 120);
        uint256 pot = manager.balanceOf(address(hook), CurrencyLibrary.toId(currency0));

        handler.swapAround(0, 1e15);
        uint256 shares = hook.rangeState(id).totalShares;
        handler.deposit(1, 0, 1e17);
        assertGt(hook.rangeState(id).totalShares, shares, "the handler's deposits never reach the ledger");
        handler.withdrawAndClaim(0, 0, 1e15, 10_000);
        assertGt(handler.withdrawAndClaimsLanded(), 0, "the composed withdraw+claim never lands");
        handler.swapAround(0, 1e14);
        handler.swapAround(1, 1e14);
        assertGt(handler.swapsLanded(), 0, "the handler's swaps never reach the pool");
        handler.deposit(1, 0, 1e16);
        handler.claim(1, 0);
        assertGt(
            handler.claimedTotal0() + handler.claimedTotal1(),
            0,
            "claims land but never pay anything: the fee path is not being exercised"
        );
        assertGt(
            manager.balanceOf(address(hook), CurrencyLibrary.toId(currency0)),
            pot,
            "the handler's swaps generate no fees for the ledger"
        );

        uint256 staked = hook.rangeState(id).totalStaked;
        handler.stake(1, 0, 1e16);
        assertGt(hook.rangeState(id).totalStaked, staked, "the handler's stakes never reach the ledger");

        handler.pauseFor(1 days);
        handler.withdrawAndClaim(0, 0, 1e15, 10_000);
        assertGt(handler.refusedWhilePaused(), 0, "a paused pool must refuse withdrawAndClaim");
    }

    function invariant_theFeePotHoldsNothingButDust() public {
        uint256 snap = vm.snapshotState();
        int24[3] memory lo = [int24(-120), -600, -60];
        int24[3] memory hi = [int24(120), 600, 60];

        vm.warp(block.timestamp + 8 days);
        for (uint256 a = 0; a < 3; a++) {
            address actor = handler.actors(a);
            for (uint256 i = 0; i < 3; i++) {
                uint256 id = hook.rangeId(poolId, lo[i], hi[i]);
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
                UserPosition memory p = hook.userPosition(id, actor);
                if (p.owed0 != 0 || p.owed1 != 0) {
                    vm.prank(actor);
                    hook.claimFees(key, lo[i], hi[i], actor, 10_000);
                }
            }
        }
        hook.sweepDistributor(currency0);
        hook.sweepDistributor(currency1);
        hook.setClaimFee(key, new Currency[](0), 1, handler.feeSink());
        hook.sweepClaimFee(currency0);
        hook.sweepClaimFee(currency1);

        uint256 dust = 3 * 3 * (handler.callCount() + 2);
        assertLe(manager.balanceOf(address(hook), CurrencyLibrary.toId(currency0)), dust, "fees stranded in the pot");
        assertLe(manager.balanceOf(address(hook), CurrencyLibrary.toId(currency1)), dust, "fees stranded in the pot");
        vm.revertToState(snap);
    }
}

contract LedgerInvariantTest is LedgerInvariantBase {}
