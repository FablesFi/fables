// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {FablesLedgerV2} from "../../src/base/FablesLedgerV2.sol";
import {RangeState} from "../../src/base/LedgerTypesV2.sol";
import {LedgerFixture} from "../utils/LedgerFixture.sol";

/// @notice A range pumped by recycled donations keeps a later holder's entry points working and paying in full.
abstract contract RecycledSharePumpBase is LedgerFixture {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    int24 internal constant T0 = -276_000;
    int24 internal constant S_LO = -276_600;
    int24 internal constant S_HI = -275_400;
    int24 internal constant R_LO = -275_400;
    int24 internal constant R_HI = -274_800;
    int24 internal constant IN_R = -275_100;
    uint128 internal constant L_BOB = 1e20;

    struct Outcome {
        uint256 fee0;
        uint256 fee1;
        uint256 principal0;
        uint256 principal1;
    }

    FablesLedgerV2 internal hook;
    PoolKey internal k;
    uint256 internal rid;
    MockERC20 internal tA;
    MockERC20 internal tB;
    address internal attacker = makeAddr("attacker");
    address internal bob = makeAddr("bob");
    address internal trader = makeAddr("trader");

    function setUp() public {
        deployFreshManagerAndRouters();
        MockERC20 a = new MockERC20("BIG", "BIG", 18);
        MockERC20 b = new MockERC20("USD", "USD", 6);
        (tA, tB) = address(a) < address(b) ? (a, b) : (b, a);
        tA.mint(attacker, (uint256(1) << 126) + (uint256(1) << 108));
        tA.mint(bob, uint256(1) << 108);
        tA.mint(trader, uint256(1) << 108);
        tA.mint(address(this), uint256(1) << 108);
        assertLt(tA.totalSupply(), uint256(1) << 127, "token0 supply below the documented 2^127 limit");
        address[4] memory who = [attacker, bob, trader, address(this)];
        for (uint256 i; i < 4; ++i) {
            tB.mint(who[i], 1e30);
        }

        address h = _deployBuild(0x13A1, address(new AccessManager(address(this))));
        hook = FablesLedgerV2(payable(h));
        k = PoolKey(
            Currency.wrap(address(tA)), Currency.wrap(address(tB)), LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(h)
        );
        _configureFlat(h, k, 3_000, 0, 10_000);
        _initPool(k, TickMath.getSqrtPriceAtTick(T0));
        rid = hook.rangeId(k.toId(), R_LO, R_HI);

        for (uint256 i; i < 4; ++i) {
            vm.startPrank(who[i]);
            tA.approve(h, type(uint256).max);
            tB.approve(h, type(uint256).max);
            tA.approve(address(swapRouter), type(uint256).max);
            tB.approve(address(swapRouter), type(uint256).max);
            tA.approve(address(donateRouter), type(uint256).max);
            tB.approve(address(donateRouter), type(uint256).max);
            vm.stopPrank();
        }
        hook.deposit(k, S_LO, S_HI, 1e20, type(uint128).max, type(uint128).max, block.timestamp);
    }

    function _swapTo(address who, int24 tick) internal {
        (, int24 cur,,) = manager.getSlot0(k.toId());
        bool zeroForOne = tick < cur;
        vm.prank(who);
        swapRouter.swap(
            k,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(uint256(1) << 100),
                sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(tick)
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function _pump() internal {
        _swapTo(attacker, IN_R);
        vm.prank(attacker);
        hook.deposit(k, R_LO, R_HI, 1, type(uint128).max, type(uint128).max, block.timestamp);
        uint256[4] memory d = [uint256(1) << 126, uint256(1) << 126, uint256(1) << 126, (uint256(1) << 126) - 1];
        for (uint256 i; i < 4; ++i) {
            vm.prank(attacker);
            donateRouter.donate(k, d[i], 0, "");
            uint256 before = tA.balanceOf(attacker);
            vm.prank(attacker);
            hook.claimFees(k, R_LO, R_HI, attacker, 10_000);
            assertEq(tA.balanceOf(attacker) - before, d[i], "the donation comes back in full");
        }
        vm.prank(attacker);
        hook.withdraw(k, R_LO, R_HI, 1, attacker, 0, 0, block.timestamp);
        _swapTo(attacker, T0);
        RangeState memory r = hook.rangeState(rid);
        assertEq(r.accFee0X128, type(uint256).max - (uint256(1) << 128) + 1, "pumped end state: 2^256 - 2^128");
        assertEq(r.totalShares, 0, "the range is empty, the level stays");
    }

    function _bobsLife() internal returns (Outcome memory o) {
        vm.prank(bob);
        hook.deposit(k, R_LO, R_HI, L_BOB, type(uint128).max, type(uint128).max, block.timestamp);
        _swapTo(trader, IN_R);
        _swapTo(trader, R_LO + 60);

        (uint256 a0, uint256 b0) = (tA.balanceOf(bob), tB.balanceOf(bob));
        vm.prank(bob);
        hook.claimFees(k, R_LO, R_HI, bob, 10_000);
        (o.fee0, o.fee1) = (tA.balanceOf(bob) - a0, tB.balanceOf(bob) - b0);

        vm.prank(trader);
        hook.deposit(k, R_LO, R_HI, 1, type(uint128).max, type(uint128).max, block.timestamp);

        (a0, b0) = (tA.balanceOf(bob), tB.balanceOf(bob));
        vm.prank(bob);
        hook.withdraw(k, R_LO, R_HI, L_BOB, bob, 0, 0, block.timestamp);
        (o.principal0, o.principal1) = (tA.balanceOf(bob) - a0, tB.balanceOf(bob) - b0);
        assertEq(hook.balanceOf(bob, rid), 0, "bob is out");
    }

    function test_control_bobExits() public {
        Outcome memory o = _bobsLife();
        assertGt(o.fee0, 0, "token0 fees earned");
        assertGt(o.fee1, 0, "token1 fees earned");
        assertGt(o.principal0, 0);
    }

    function test_pumpedRange_bobsDoorsLandAndPayInFull() public {
        uint256 snap = vm.snapshotState();
        Outcome memory ctl = _bobsLife();
        vm.revertToState(snap);

        _pump();
        uint256 level = hook.rangeState(rid).accFee0X128;
        Outcome memory got = _bobsLife();
        assertLt(hook.rangeState(rid).accFee0X128, level, "bob's fees carried the level across 2^256");
        assertEq(got.fee0, ctl.fee0, "bob's token0 fees");
        assertEq(got.fee1, ctl.fee1, "bob's token1 fees");
        assertEq(got.principal0, ctl.principal0, "bob's token0 principal");
        assertEq(got.principal1, ctl.principal1, "bob's token1 principal");
    }

    function test_pumpedRange_stillWorksAYearLater() public {
        _pump();
        vm.warp(block.timestamp + 365 days);
        Outcome memory o = _bobsLife();
        assertGt(o.fee0, 0);
    }
}

contract RecycledSharePumpTest is RecycledSharePumpBase {}
