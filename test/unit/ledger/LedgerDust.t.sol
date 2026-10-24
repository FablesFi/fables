// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";

import {FablesLedgerV2} from "../../../src/base/FablesLedgerV2.sol";
import {RangeState, UserPosition} from "../../../src/base/LedgerTypesV2.sol";
import {MockERC20} from "../../utils/mocks/MockERC20.sol";
import {MockDistributor} from "../../utils/mocks/MockDistributor.sol";
import {MockBallotGate} from "../../utils/mocks/MockBallotGate.sol";
import {LedgerFixture} from "../../utils/LedgerFixture.sol";

/// @notice The ledger at a 0 and 1 pip fee with 6-decimal tokens and micro swaps: solvent after every action, only dust
///         left.
abstract contract LedgerDustBase is LedgerFixture {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    uint256 constant Q128 = 1 << 128;
    bytes32 constant SWAP_TOPIC = keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");
    int24 constant LOWER = -100;
    int24 constant UPPER = 100;

    FablesLedgerV2 hook;
    address hookAddr;
    MockERC20 t0;
    MockERC20 t1;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address swapper = makeAddr("swapper");
    address[2] actors;

    function setUp() public {
        deployFreshManagerAndRouters();
        MockERC20 a = new MockERC20("USDG", "USDG", 6);
        MockERC20 b = new MockERC20("USDe", "USDE", 6);
        (t0, t1) = address(a) < address(b) ? (a, b) : (b, a);
        currency0 = Currency.wrap(address(t0));
        currency1 = Currency.wrap(address(t1));

        AccessManager authority = new AccessManager(address(this));
        hookAddr = _deployBuild(0xD057, address(authority));
        hook = FablesLedgerV2(hookAddr);
        hook.setDistributor(new Currency[](0), address(new MockDistributor(makeAddr("ff"))));
        hook.setBallotGate(address(new MockBallotGate()));

        actors = [alice, bob];
        address[3] memory funded = [alice, bob, swapper];
        for (uint256 i = 0; i < 3; i++) {
            t0.mint(funded[i], 1e15);
            t1.mint(funded[i], 1e15);
            vm.startPrank(funded[i]);
            t0.approve(hookAddr, type(uint256).max);
            t1.approve(hookAddr, type(uint256).max);
            t0.approve(address(swapRouter), type(uint256).max);
            t1.approve(address(swapRouter), type(uint256).max);
            vm.stopPrank();
        }
    }

    function _pool(uint24 fee) internal returns (PoolKey memory k) {
        k = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 10, IHooks(hookAddr));
        _configureFlat(hookAddr, k, fee, 0, 1);
        _initPool(k, SQRT_PRICE_1_1);
    }

    function _deposit(PoolKey memory k, address who, uint128 liq) internal {
        vm.prank(who);
        hook.deposit(k, LOWER, UPPER, liq, type(uint128).max, type(uint128).max, block.timestamp);
    }

    function _swap(PoolKey memory k, bool zeroForOne, uint256 amount) internal returns (uint24 feeCharged) {
        (uint160 sqrtP,,,) = manager.getSlot0(k.toId());
        if (zeroForOne ? sqrtP <= TickMath.MIN_SQRT_PRICE + 1 : sqrtP >= TickMath.MAX_SQRT_PRICE - 1) {
            zeroForOne = !zeroForOne;
        }
        vm.recordLogs();
        vm.prank(swapper);
        swapRouter.swap(
            k,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amount),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(manager) && logs[i].topics[0] == SWAP_TOPIC) {
                (,,,,, feeCharged) = abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
            }
        }
    }

    function _pot(Currency c) internal view returns (uint256) {
        return manager.balanceOf(hookAddr, c.toId());
    }

    function _assertSolvent(PoolKey memory k) internal view {
        uint256 id = hook.rangeId(k.toId(), LOWER, UPPER);
        RangeState memory r = hook.rangeState(id);
        uint256 owed0 = hook.distributorOwed(currency0) + hook.claimFeeOwed(currency0);
        uint256 owed1 = hook.distributorOwed(currency1) + hook.claimFeeOwed(currency1);
        for (uint256 a = 0; a < 2; a++) {
            UserPosition memory p = hook.userPosition(id, actors[a]);
            owed0 += p.owed0;
            owed1 += p.owed1;
            uint256 unstaked = hook.balanceOf(actors[a], id) - p.staked;
            if (unstaked != 0) {
                owed0 += FullMath.mulDiv(unstaked, r.accFee0X128 - p.checkpoint0X128, Q128);
                owed1 += FullMath.mulDiv(unstaked, r.accFee1X128 - p.checkpoint1X128, Q128);
            }
        }
        assertLe(owed0, _pot(currency0), "currency0: promised more than the pot holds");
        assertLe(owed1, _pot(currency1), "currency1: promised more than the pot holds");
    }

    function _drain(PoolKey memory k) internal returns (uint256 divisions) {
        uint256 id = hook.rangeId(k.toId(), LOWER, UPPER);
        for (uint256 a = 0; a < 2; a++) {
            address who = actors[a];
            uint256 staked = hook.userPosition(id, who).staked;
            if (staked != 0) {
                vm.prank(who);
                hook.unstake(k, LOWER, UPPER, uint128(staked));
                divisions += 2;
            }
            uint256 bal = hook.balanceOf(who, id);
            if (bal != 0) {
                vm.prank(who);
                hook.withdraw(k, LOWER, UPPER, uint128(bal), who, 0, 0, block.timestamp);
                divisions += 2;
            }
            UserPosition memory p = hook.userPosition(id, who);
            if (p.owed0 != 0 || p.owed1 != 0) {
                vm.prank(who);
                hook.claimFees(k, LOWER, UPPER, who, 10_000);
                divisions += 2;
            }
        }
        hook.sweepDistributor(currency0);
        hook.sweepDistributor(currency1);
        if (hook.claimFeeRecipient() == address(0)) hook.setClaimFee(k, new Currency[](0), 1, makeAddr("sink"));
        hook.sweepClaimFee(currency0);
        hook.sweepClaimFee(currency1);
        assertEq(hook.rangeState(id).totalShares, 0, "shares left after a full drain");
        assertEq(manager.getLiquidity(k.toId()), 0, "pool liquidity left after a full drain");
    }

    function test_fee0_nothingAccruesAndEveryoneExitsWhole() public {
        PoolKey memory k = _pool(0);
        uint256 id = hook.rangeId(k.toId(), LOWER, UPPER);
        hook.setClaimFee(k, new Currency[](0), 1000, makeAddr("sink"));

        _deposit(k, alice, 1e12);
        _deposit(k, bob, 3e11);
        vm.prank(bob);
        hook.stake(k, LOWER, UPPER, 15e10, 0);

        uint256[6] memory sizes = [uint256(1), 7, 999, 1e6, 1e7, 3e8];
        for (uint256 i = 0; i < 120; i++) {
            uint24 charged = _swap(k, i % 2 == 0, sizes[i % 6]);
            assertEq(charged, 0, "a fee-0 pool charged a fee");
            if (i % 20 == 19) {
                _deposit(k, alice, 1e6);
                _assertSolvent(k);
            }
        }
        _deposit(k, alice, 1e6);

        assertEq(_pot(currency0), 0, "currency0: a fee-0 pool put something in the pot");
        assertEq(_pot(currency1), 0, "currency1: a fee-0 pool put something in the pot");
        assertEq(hook.distributorOwed(currency0) + hook.distributorOwed(currency1), 0, "voters' pot moved at fee 0");
        assertEq(hook.claimFeeOwed(currency0) + hook.claimFeeOwed(currency1), 0, "claim-fee pot moved at fee 0");
        RangeState memory r = hook.rangeState(id);
        assertEq(r.accFee0X128 + r.accFee1X128, 0, "the accumulator moved at fee 0");

        _drain(k);
        assertEq(_pot(currency0) + _pot(currency1), 0, "a fee-0 pool left claims behind");
        assertEq(t0.balanceOf(hookAddr) + t1.balanceOf(hookAddr), 0, "raw tokens on the hook");
    }

    function test_fee1pip_conservationHoldsAcrossMicroCycles() public {
        PoolKey memory k = _pool(1);
        uint256 id = hook.rangeId(k.toId(), LOWER, UPPER);
        hook.setClaimFee(k, new Currency[](0), 500, makeAddr("sink"));

        _deposit(k, alice, 1e12);
        _deposit(k, bob, 3e11);
        vm.prank(bob);
        hook.stake(k, LOWER, UPPER, 15e10, 0);

        uint256 divisions;
        uint256[6] memory sizes = [uint256(1), 7, 999, 1e6, 1e7, 3e8];
        for (uint256 i = 0; i < 300; i++) {
            uint24 charged = _swap(k, i % 2 == 0, sizes[i % 6]);
            assertEq(charged, 1, "a 1-pip pool charged something else");
            if (i % 25 == 24) {
                if (i % 50 == 24) {
                    _deposit(k, alice, 1e6);
                } else {
                    vm.prank(alice);
                    hook.claimFees(k, LOWER, UPPER, alice, 10_000);
                }
                vm.prank(bob);
                hook.transfer(alice, id, 1);
                divisions += 6;
                _assertSolvent(k);
            }
        }

        assertGt(_pot(currency0) + _pot(currency1), 0, "300 micro swaps at 1 pip produced no fee at all");
        divisions += _drain(k);
        uint256 dust = divisions + 8;
        assertLe(_pot(currency0), dust, "currency0: fees stranded in the pot");
        assertLe(_pot(currency1), dust, "currency1: fees stranded in the pot");
        assertEq(t0.balanceOf(hookAddr) + t1.balanceOf(hookAddr), 0, "raw tokens on the hook");
    }

    function testFuzz_dust_microCycles(bool onePip, uint256 seed, uint8 steps) public {
        PoolKey memory k = _pool(onePip ? 1 : 0);
        uint256 id = hook.rangeId(k.toId(), LOWER, UPPER);
        steps = uint8(bound(steps, 5, 30));
        hook.setClaimFee(k, new Currency[](0), uint16(seed % 2001), makeAddr("sink"));

        _deposit(k, alice, 1e12);
        _deposit(k, bob, uint128(bound(uint256(keccak256(abi.encode(seed, "b"))), 1e6, 5e11)));
        uint256 divisions;
        for (uint256 i = 0; i < steps; i++) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            uint256 amount = bound(r >> 8, 1, 1e8);
            uint24 charged = _swap(k, r & 1 == 1, amount);
            assertEq(charged, onePip ? 1 : 0, "the engine charged a fee other than the resting one");
            address who = actors[(r >> 1) & 1];
            uint256 action = (r >> 2) % 5;
            uint256 bal = hook.balanceOf(who, id);
            uint256 staked = hook.userPosition(id, who).staked;
            if (action == 0) {
                _deposit(k, who, uint128(bound(r >> 16, 1e6, 1e10)));
            } else if (action == 1 && bal - staked != 0) {
                vm.prank(who);
                hook.stake(k, LOWER, UPPER, uint128(bound(r >> 16, 1, bal - staked)), 0);
            } else if (action == 2 && staked != 0) {
                vm.prank(who);
                hook.unstake(k, LOWER, UPPER, uint128(bound(r >> 16, 1, staked)));
            } else if (action == 3 && bal != 0) {
                vm.prank(who);
                hook.claimFees(k, LOWER, UPPER, who, 10_000);
            } else if (action == 4 && bal - staked > 1) {
                vm.prank(who);
                hook.withdraw(k, LOWER, UPPER, uint128(bound(r >> 16, 1, bal - staked - 1)), who, 0, 0, block.timestamp);
            }
            divisions += 4;
            _assertSolvent(k);
        }
        divisions += _drain(k);
        uint256 dust = divisions + 8;
        assertLe(_pot(currency0), dust, "currency0: fees stranded in the pot");
        assertLe(_pot(currency1), dust, "currency1: fees stranded in the pot");
        if (!onePip) assertEq(_pot(currency0) + _pot(currency1), 0, "a fee-0 pool left claims behind");
    }
}

contract LedgerDustTest is LedgerDustBase {}
