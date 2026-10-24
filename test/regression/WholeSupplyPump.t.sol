// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {FablesLedgerV2} from "../../src/base/FablesLedgerV2.sol";
import {RangeState} from "../../src/base/LedgerTypesV2.sol";
import {LedgerFixture} from "../utils/LedgerFixture.sol";

/// @notice A token's whole supply recycled through one range cannot block a later holder.
abstract contract WholeSupplyPumpBase is LedgerFixture {
    using PoolIdLibrary for PoolKey;

    int24 internal constant LO = -60;
    int24 internal constant HI = 60;
    uint128 internal constant L_VICTIM = 1e21;

    struct Outcome {
        uint256 feeA;
        uint256 feeB;
        uint256 principalA;
        uint256 principalB;
        uint256 traderShares;
    }

    uint256 internal SUPPLY;
    FablesLedgerV2 internal hook;
    PoolKey internal k;
    uint256 internal rid;
    MockERC20 internal A;
    MockERC20 internal B;
    bool internal aIs0;
    address internal victim = makeAddr("victim");
    address internal trader = makeAddr("trader");

    function _supply() internal pure virtual returns (uint256) {
        return (uint256(1) << 127) - 1;
    }

    function setUp() public {
        SUPPLY = _supply();
        deployFreshManagerAndRouters();
        A = new MockERC20("A", "A", 18);
        B = new MockERC20("B", "B", 18);
        A.mint(address(this), SUPPLY);
        B.mint(address(this), SUPPLY);
        aIs0 = address(A) < address(B);
        (currency0, currency1) = aIs0
            ? (Currency.wrap(address(A)), Currency.wrap(address(B)))
            : (Currency.wrap(address(B)), Currency.wrap(address(A)));
        address h = _deployBuild(0x13A3, address(new AccessManager(address(this))));
        hook = FablesLedgerV2(payable(h));
        k = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(h));
        _configureFlat(h, k, 3_000, 0, 10_000);
        _initPool(k, SQRT_PRICE_1_1);
        rid = hook.rangeId(k.toId(), LO, HI);
        A.transfer(victim, 1e24);
        B.transfer(victim, 1e24);
        A.transfer(trader, 1e24);
        B.transfer(trader, 1e24);
        A.approve(h, type(uint256).max);
        B.approve(h, type(uint256).max);
        A.approve(address(donateRouter), type(uint256).max);
        B.approve(address(donateRouter), type(uint256).max);
        vm.startPrank(victim);
        A.approve(h, type(uint256).max);
        B.approve(h, type(uint256).max);
        vm.stopPrank();
        vm.startPrank(trader);
        A.approve(address(swapRouter), type(uint256).max);
        B.approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();
    }

    function _accA() internal view returns (uint256) {
        RangeState memory r = hook.rangeState(rid);
        return aIs0 ? r.accFee0X128 : r.accFee1X128;
    }

    function _donateA(uint256 amt) internal {
        if (aIs0) donateRouter.donate(k, amt, 0, "");
        else donateRouter.donate(k, 0, amt, "");
    }

    function _depositSelf(uint128 liq) internal {
        hook.deposit(k, LO, HI, liq, type(uint128).max, type(uint128).max, block.timestamp);
    }

    function _pump() internal {
        uint256 a0 = A.balanceOf(address(this));
        _depositSelf(1);
        while (true) {
            uint256 f = (type(uint256).max - _accA()) >> 128;
            if (f <= 2) break;
            uint256 bal = A.balanceOf(address(this));
            if (f - 2 > bal) f = bal + 2;
            if (f - 2 > uint256(uint128(type(int128).max))) f = uint256(uint128(type(int128).max)) + 2;
            _donateA(f - 2);
            hook.claimFees(k, LO, HI, address(this), 10_000);
        }
        uint128 big = uint128(1) << 90;
        _depositSelf(big);
        uint256 u = uint256(big) + 1;
        uint256 g = (type(uint256).max - _accA() - (uint256(1) << 64)) * u / (uint256(1) << 128);
        _donateA(g);
        hook.claimFees(k, LO, HI, address(this), 10_000);
        vm.roll(block.number + 1);
        hook.withdraw(k, LO, HI, big + 1, address(this), 0, 0, block.timestamp);
        assertEq(hook.rangeState(rid).totalShares, 0, "range empty, level kept");
        assertLt(type(uint256).max - _accA(), uint256(1) << 65, "parked within ~2^64 of 2^256");
        assertLt(a0 - A.balanceOf(address(this)), 1e6, "the attacker recovered its capital");
    }

    function _victimsLife() internal returns (Outcome memory o) {
        vm.prank(victim);
        hook.deposit(k, LO, HI, L_VICTIM, type(uint128).max, type(uint128).max, block.timestamp);
        vm.prank(trader);
        swapRouter.swap(
            k,
            IPoolManager.SwapParams({
                zeroForOne: aIs0,
                amountSpecified: -1e18,
                sqrtPriceLimitX96: aIs0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        (uint256 a0, uint256 b0) = (A.balanceOf(victim), B.balanceOf(victim));
        vm.prank(victim);
        hook.claimFees(k, LO, HI, victim, 10_000);
        (o.feeA, o.feeB) = (A.balanceOf(victim) - a0, B.balanceOf(victim) - b0);
        vm.prank(victim);
        hook.transfer(trader, rid, 1);
        o.traderShares = hook.balanceOf(trader, rid);
        (a0, b0) = (A.balanceOf(victim), B.balanceOf(victim));
        vm.prank(victim);
        hook.withdraw(k, LO, HI, L_VICTIM - 1, victim, 0, 0, block.timestamp);
        (o.principalA, o.principalB) = (A.balanceOf(victim) - a0, B.balanceOf(victim) - b0);
        assertEq(hook.balanceOf(victim, rid), 0, "the victim is out");
    }

    function test_control_unpumpedRange() public {
        Outcome memory o = _victimsLife();
        assertGt(o.feeA, 0, "the swap fee reached the victim");
        assertEq(o.traderShares, 1);
    }

    function test_pumpedRange_victimsDoorsLandAndPayInFull() public {
        uint256 snap = vm.snapshotState();
        Outcome memory ctl = _victimsLife();
        vm.revertToState(snap);

        _pump();
        uint256 level = _accA();
        Outcome memory got = _victimsLife();
        assertLt(_accA(), level, "the swap fee carried the level across 2^256");
        assertEq(got.feeA, ctl.feeA, "fees in A");
        assertEq(got.feeB, ctl.feeB, "fees in B");
        assertEq(got.traderShares, ctl.traderShares, "the transfer landed");
        assertEq(got.principalA, ctl.principalA, "principal in A");
        assertEq(got.principalB, ctl.principalB, "principal in B");
    }
}

contract WholeSupplyPumpTest is WholeSupplyPumpBase {}

/// @notice Same with a 2^118 token supply.
contract WholeSupplyPump2pow118Test is WholeSupplyPumpBase {
    function _supply() internal pure override returns (uint256) {
        return uint256(1) << 118;
    }
}
