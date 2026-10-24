// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FablesLedgerV2} from "../../src/base/FablesLedgerV2.sol";
import {RangeState, UserPosition} from "../../src/base/LedgerTypesV2.sol";
import {LedgerLibV2} from "../../src/libraries/LedgerLibV2.sol";
import {LedgerFixture} from "../utils/LedgerFixture.sol";

/// @notice Runs `LedgerLibV2.settleUser` on its own storage.
contract SettleHarness {
    RangeState internal _range;
    UserPosition internal _pos;

    function set(uint256 acc0, uint256 acc1, uint128 owed0, uint128 owed1) external {
        (_range.accFee0X128, _range.accFee1X128) = (acc0, acc1);
        (_pos.owed0, _pos.owed1) = (owed0, owed1);
    }

    function settle(uint256 balance) external {
        LedgerLibV2.settleUser(_range, _pos, balance, address(this), 1);
    }

    function position() external view returns (UserPosition memory) {
        return _pos;
    }
}

/// @notice `settleUser` saturates `owed` at 2^128 - 1 instead of truncating or reverting.
contract OwedSaturatesSettleUserTest is Test {
    uint256 internal constant BAL = 1 << 64;
    uint128 internal constant MAX = uint128(type(int128).max);

    SettleHarness internal h;

    function setUp() public {
        h = new SettleHarness();
    }

    function _settle(uint128 owed0, uint128 owed1, uint256 inc0, uint256 inc1) internal returns (UserPosition memory) {
        h.set(inc0 << 64, inc1 << 64, owed0, owed1);
        h.settle(BAL);
        return h.position();
    }

    function test_incrementAboveTheCap_saturates() public {
        UserPosition memory p = _settle(0, 0, (uint256(1) << 128) + 5, uint256(1) << 127);
        assertEq(p.owed0, MAX, "saturated, not truncated");
        assertEq(p.owed1, MAX, "saturated at the int128 cap");
        assertEq(p.checkpoint0X128, ((uint256(1) << 128) + 5) << 64, "checkpoint moves to the level");
    }

    function test_sumAboveTheCap_saturates() public {
        UserPosition memory p = _settle(MAX - 10, MAX, 11, type(uint128).max);
        assertEq(p.owed0, MAX);
        assertEq(p.owed1, MAX, "already at the cap: stays there");
    }

    function test_largestIncrement_saturates() public {
        h.set(type(uint256).max, type(uint256).max, MAX - 1, 0);
        h.settle(type(uint128).max);
        assertEq(h.position().owed0, MAX);
        assertEq(h.position().owed1, MAX);
    }

    function test_upToTheCap_exact() public {
        UserPosition memory p = _settle(MAX - 10, 3, 10, 4);
        assertEq(p.owed0, MAX, "exactly the cap");
        assertEq(p.owed1, 7);
    }

    function testFuzz_saturatingAccrual(uint128 owed0, uint128 owed1, uint256 inc0, uint256 inc1) public {
        owed0 = uint128(bound(owed0, 0, MAX));
        owed1 = uint128(bound(owed1, 0, MAX));
        inc0 = bound(inc0, 0, (uint256(1) << 192) - 1);
        inc1 = bound(inc1, 0, (uint256(1) << 192) - 1);
        UserPosition memory p = _settle(owed0, owed1, inc0, inc1);
        uint256 s0 = uint256(owed0) + inc0;
        uint256 s1 = uint256(owed1) + inc1;
        assertEq(p.owed0, s0 > MAX ? MAX : s0);
        assertEq(p.owed1, s1 > MAX ? MAX : s1);
    }
}

/// @notice Owed saturation on the real hook with a 2^255-supply token.
abstract contract OwedSaturatesE2EBase is LedgerFixture {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    int24 internal constant LO = -600;
    int24 internal constant HI = 600;
    uint128 internal constant L_ALICE = 1e18;
    uint256 internal constant D = (uint256(1) << 127) - (uint256(1) << 120);
    uint128 internal constant MAX = uint128(type(int128).max);

    FablesLedgerV2 internal hook;
    PoolKey internal k;
    uint256 internal rid;
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();
        address h = _deployBuild(0x12E1, address(new AccessManager(address(this))));
        hook = FablesLedgerV2(payable(h));
        k = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(h));
        _configureFlat(h, k, 3_000, 0, 10_000);
        _initPool(k, SQRT_PRICE_1_1);
        rid = hook.rangeId(k.toId(), LO, HI);
        address[2] memory who = [alice, bob];
        for (uint256 i; i < 2; ++i) {
            currency0.transfer(who[i], 1e30);
            currency1.transfer(who[i], 1e30);
            vm.startPrank(who[i]);
            IERC20(Currency.unwrap(currency0)).approve(h, type(uint256).max);
            IERC20(Currency.unwrap(currency1)).approve(h, type(uint256).max);
            vm.stopPrank();
        }
        _deposit(alice, L_ALICE);
        _deposit(bob, 1);
    }

    function _deposit(address who, uint128 liq) internal {
        vm.prank(who);
        hook.deposit(k, LO, HI, liq, type(uint128).max, type(uint128).max, block.timestamp);
    }

    function _withdrawAll(address who) internal {
        uint128 bal = uint128(hook.balanceOf(who, rid));
        vm.prank(who);
        hook.withdraw(k, LO, HI, bal, who, 0, 0, block.timestamp);
    }

    function _window() internal {
        donateRouter.donate(k, D, D, "");
        _deposit(bob, 1);
    }

    function _settledThenTwoWindows() internal {
        donateRouter.donate(k, D, D, "");
        _deposit(alice, 1);
        assertGt(hook.userPosition(rid, alice).owed0, D - D / 1e9, "alice is owed ~D");
        _window();
        _window();
    }

    function _claim(address who) internal returns (uint256 got0, uint256 got1) {
        (uint256 b0, uint256 b1) = (currency0.balanceOf(who), currency1.balanceOf(who));
        vm.prank(who);
        hook.claimFees(k, LO, HI, who, 10_000);
        (got0, got1) = (currency0.balanceOf(who) - b0, currency1.balanceOf(who) - b1);
    }

    function test_withdrawAndClaimLand_owedSaturates() public {
        _settledThenTwoWindows();
        _withdrawAll(alice);
        UserPosition memory p = hook.userPosition(rid, alice);
        assertEq(hook.balanceOf(alice, rid), 0, "alice is out");
        assertEq(p.owed0, MAX, "saturated");
        assertEq(p.owed1, MAX, "saturated");
        (uint256 got0, uint256 got1) = _claim(alice);
        assertEq(got0, MAX, "the claim pays exactly 2^127 - 1");
        assertEq(got1, MAX, "the claim pays exactly 2^127 - 1");
        assertEq(hook.userPosition(rid, alice).owed0, 0);
        (got0,) = _claim(bob);
        assertGt(got0, 0, "bob's small accrual still claims");
    }

    function test_withdrawAndClaimInOneCall_paysTheCap() public {
        _settledThenTwoWindows();
        uint128 bal = uint128(hook.balanceOf(alice, rid));
        (uint256 b0, uint256 b1) = (currency0.balanceOf(alice), currency1.balanceOf(alice));
        vm.prank(alice);
        hook.withdrawAndClaim(k, LO, HI, bal, alice, 0, 0, block.timestamp, 10_000);
        uint256 got0 = currency0.balanceOf(alice) - b0;
        uint256 got1 = currency1.balanceOf(alice) - b1;
        assertGe(got0, MAX);
        assertGe(got1, MAX);
        assertLt(got0 - MAX, 1e18, "the rest is the principal");
        assertLt(got1 - MAX, 1e18, "the rest is the principal");
        assertEq(hook.userPosition(rid, alice).owed0, 0);
    }

    function test_owedAboveTheCap_claimLands() public {
        _window();
        _window();
        _withdrawAll(alice);
        assertEq(hook.userPosition(rid, alice).owed0, MAX, "capped");
        (uint256 got0, uint256 got1) = _claim(alice);
        assertEq(got0, MAX);
        assertEq(got1, MAX);
    }

    function test_singleIncrementAbove2to128_saturatesNotTruncates() public {
        _window();
        _window();
        _window();
        _withdrawAll(alice);
        assertEq(hook.userPosition(rid, alice).owed0, MAX, "not truncated");
        assertEq(hook.userPosition(rid, alice).owed1, MAX, "not truncated");
    }

    function test_belowTheCap_unchanged() public {
        _window();
        _withdrawAll(alice);
        uint128 owed = hook.userPosition(rid, alice).owed0;
        assertGt(owed, D - D / 1e9, "~D");
        assertLt(owed, D);
        (uint256 got0,) = _claim(alice);
        assertEq(got0, owed, "paid in full");
    }
}

contract OwedSaturatesE2ETest is OwedSaturatesE2EBase {}
