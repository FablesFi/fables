// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {FablesStableHookLite} from "../../src/FablesStableHookLite.sol";
import {FablesStableFee, StableFeeConfig} from "../../src/base/FablesStableFee.sol";
import {FablesLedgerV2} from "../../src/base/FablesLedgerV2.sol";
import {DiscountLib} from "../../src/libraries/DiscountLib.sol";
import {MockERC20} from "../utils/mocks/MockERC20.sol";
import {FullCycleBase} from "./FullCycleBase.sol";
import {StableBuild} from "../utils/Artifacts.sol";

/// @notice Stable lifecycle fixture: two 6-decimal stables at parity.
abstract contract StableCycleBase is FullCycleBase {
    using PoolIdLibrary for PoolKey;

    uint24 internal constant K07 = 11_744_051;
    uint24 internal constant OPT_50 = 50;
    uint8 internal constant TM_100 = 100;
    uint160 internal constant SQRT_1_1 = 79_228_162_514_264_337_593_543_950_336;
    uint16 internal constant CLAIM_BPS = 1_000;

    MockERC20 internal s0;
    MockERC20 internal s1;
    PoolKey internal key;
    PoolId internal id;
    address internal hook;

    address internal alice = makeAddr("st.alice");
    address internal bob = makeAddr("st.bob");
    address internal eve = makeAddr("st.eve");
    address internal mm = makeAddr("st.mm");

    mapping(address currency => uint256) internal lpFees;

    function _setUpStable(string memory artifact, string memory family, uint160 flags) internal {
        setUpRC(6, 6, 18);
        _deployAuthority();
        MockERC20[3] memory t = [tokA, tokB, tokC];
        for (uint256 i; i < 3; i++) {
            if (t[i].decimals() != 6) continue;
            if (address(s0) == address(0)) s0 = t[i];
            else s1 = t[i];
        }
        hook = flagged(string.concat("fc.", artifact), flags);
        deployCodeTo(string.concat(artifact, ".sol:", artifact), abi.encode(pm, address(am)), hook);
        _bindFamily(hook, family);
        _handOver();
        key = dynamicKey(Currency.wrap(address(s0)), Currency.wrap(address(s1)), 1, hook);
        id = key.toId();
        address[5] memory who = [alice, bob, eve, mm, multisig];
        for (uint256 i; i < who.length; i++) {
            _fund(who[i], key.currency0, 10_000_000e6);
            _fund(who[i], key.currency1, 10_000_000e6);
            _approveAll(who[i], key.currency0, hook);
            _approveAll(who[i], key.currency1, hook);
        }
    }

    function _cfg() internal pure returns (StableFeeConfig memory) {
        return
            StableFeeConfig({k: K07, optimalFeeE6: OPT_50, targetMultiplier: TM_100, referenceSqrtPriceX96: SQRT_1_1});
    }

    function _configureData() internal view returns (bytes memory) {
        return abi.encodeCall(FablesStableFee.configureStablePool, (key, SQRT_1_1, _cfg()));
    }

    function _swapT(bool zeroForOne, uint128 amount) internal returns (uint24 fee) {
        vm.roll(block.number + 3);
        vm.warp(block.timestamp + 1);
        fee = _swap(trader, key, zeroForOne, amount);
        assertLe(fee, 100_000, "stable fee within the 10% hard cap");
    }

    function _claim(address lp, int24 lo, int24 hi) internal {
        FablesLedgerV2 l = FablesLedgerV2(payable(hook));
        uint256 rid = l.rangeId(id, lo, hi);
        if (l.balanceOf(lp, rid) == 0 && l.userPosition(rid, lp).owed0 == 0 && l.userPosition(rid, lp).owed1 == 0) {
            return;
        }
        uint256 b0 = _bal(key.currency0, lp);
        uint256 b1 = _bal(key.currency1, lp);
        vm.prank(lp);
        l.claimFees(key, lo, hi, lp, 2_000);
        lpFees[Currency.unwrap(key.currency0)] += _bal(key.currency0, lp) - b0;
        lpFees[Currency.unwrap(key.currency1)] += _bal(key.currency1, lp) - b1;
        _assertSettled();
    }
}

/// @notice Full lifecycle on a Stable Lite build: configure, deposits, discounted and router swaps, pause, exits and
///         fee conservation. On the open build an outside LP holds direct liquidity in the same range throughout.
abstract contract StableLiteFullCycleBase is StableCycleBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    int24 internal constant LO = -60;
    int24 internal constant HI = 60;

    FablesStableHookLite internal sl;
    PoolSwapTest internal mmExec;
    uint256 internal rid;
    address[3] internal lps;
    uint128[3] internal ls;
    uint128 internal outsideL;

    /// @notice The build under test: false = FablesStableHookLite, true = FablesStableHookLiteExclusive.
    function _exclusive() internal pure virtual returns (bool) {
        return false;
    }

    function setUp() public {
        _setUpStable(StableBuild.name(_exclusive()), "FablesStableHookLite", StableBuild.flags(_exclusive()));
        sl = FablesStableHookLite(payable(hook));
        lps = [alice, bob, eve];
    }

    function test_fullCycle_StableLite() public {
        _liteConfigureAndDeposit();
        _liteDiscountAndSwaps();
        _litePause();
        _liteExitAndConserve();
    }

    function _liteConfigureAndDeposit() internal {
        bytes[] memory d = new bytes[](2);
        d[0] = _configureData();
        d[1] = abi.encodeCall(FablesLedgerV2.setClaimFee, (key, new Currency[](0), CLAIM_BPS, treasury));
        _adminBatch(hook, d);
        (uint160 sqrtP,,,) = pm.getSlot0(id);
        assertEq(sqrtP, SQRT_1_1, "initialized by the hook");

        if (_exclusive()) {
            vm.expectRevert();
            addLiquidity(key, LO, HI, 1e12);
        }

        rid = sl.rangeId(id, LO, HI);
        uint128 l = _liqFor(id, LO, HI, 500_000e6, 500_000e6);
        ls = [l, l / 2, l / 3];
        for (uint256 i; i < 3; i++) {
            (uint256 e0, uint256 e1) = _amountsFor(id, LO, HI, ls[i]);
            vm.prank(lps[i]);
            sl.deposit(key, LO, HI, ls[i], uint128(e0 + 2), uint128(e1 + 2), block.timestamp);
        }
        assertEq(sl.rangeState(rid).totalShares, uint256(ls[0]) + ls[1] + ls[2], "shares == liquidity");
        if (!_exclusive()) {
            outsideL = l / 4;
            addLiquidity(key, LO, HI, int256(uint256(outsideL)));
            assertEq(pm.getLiquidity(id), uint256(ls[0]) + ls[1] + ls[2] + outsideL, "ledger + outside liquidity");
        }
    }

    function _liteDiscountAndSwaps() internal {
        mmExec = new PoolSwapTest(pm);
        _approveAll(mm, key.currency0, address(mmExec));
        _approveAll(mm, key.currency1, address(mmExec));
        PoolId[] memory ids = new PoolId[](1);
        ids[0] = id;
        _delayed(
            discountAdmin,
            hook,
            abi.encodeCall(
                FablesStableFee.setDiscount,
                (ids, address(mmExec), 5_000, 0, uint8(DiscountLib.DIR_BOTH), uint40(block.timestamp + 30 days))
            )
        );
        for (uint256 i; i < 6; i++) {
            vm.roll(block.number + 2);
            vm.warp(block.timestamp + 7);
            bool z = i % 2 == 0;
            uint24 full = sl.currentFee(id, z);
            assertLe(sl.feeFor(key, z, address(mmExec)), full, "a discount never raises the fee");
            assertEq(_swap(trader, key, z, 20_000e6), full, "router pays the sender-free fee");
            vm.roll(block.number + 1);
            uint24 disc = sl.feeFor(key, !z, address(mmExec));
            assertEq(_swapVia(mmExec, mm, key, !z, 10_000e6), disc, "executor pays its discounted fee");
        }
        address[] memory accts = new address[](1);
        accts[0] = address(mmExec);
        vm.prank(guardian);
        sl.revokeDiscount(ids, accts);
        vm.roll(block.number + 1);
        assertEq(sl.feeFor(key, true, address(mmExec)), sl.currentFee(id, true), "revoked");
    }

    function _litePause() internal {
        vm.prank(guardian);
        sl.pause(2 days);
        vm.prank(alice);
        vm.expectRevert(FablesLedgerV2.LedgerPaused.selector);
        sl.claimFees(key, LO, HI, alice, 2_000);
        if (!_exclusive()) {
            _outsideCollect();
            addLiquidity(key, LO, HI, 1e12);
            addLiquidity(key, LO, HI, -1e12);
        }
        (uint256 e0, uint256 e1) = _amountsFor(id, LO, HI, ls[2]);
        uint256 b0 = _bal(key.currency0, eve);
        vm.prank(eve);
        sl.withdraw(key, LO, HI, ls[2], eve, uint128(e0), uint128(e1), block.timestamp);
        assertApproxEqAbs(_bal(key.currency0, eve) - b0, e0, 1, "exit during a pause pays the principal");
        _admin(hook, abi.encodeCall(FablesLedgerV2.setPaused, (uint256(0))));
    }

    function _liteExit(address lp) internal {
        uint128 s = uint128(sl.balanceOf(lp, rid));
        (uint256 x0, uint256 x1) = _amountsFor(id, LO, HI, s);
        uint256 c0b = _bal(key.currency0, lp);
        uint256 c1b = _bal(key.currency1, lp);
        vm.prank(lp);
        sl.withdraw(key, LO, HI, s, lp, 0, 0, block.timestamp);
        assertApproxEqAbs(_bal(key.currency0, lp) - c0b, x0, 1, "principal c0");
        assertApproxEqAbs(_bal(key.currency1, lp) - c1b, x1, 1, "principal c1");
    }

    /// @dev The outside LP collects its fees (any modify of its position would pay them out).
    function _outsideCollect() internal {
        BalanceDelta fees = addLiquidity(key, LO, HI, 0);
        lpFees[Currency.unwrap(key.currency0)] += uint128(fees.amount0());
        lpFees[Currency.unwrap(key.currency1)] += uint128(fees.amount1());
    }

    function _outsideExit() internal {
        _outsideCollect();
        (uint256 x0, uint256 x1) = _amountsFor(id, LO, HI, outsideL);
        BalanceDelta out = addLiquidity(key, LO, HI, -int256(uint256(outsideL)));
        assertApproxEqAbs(uint128(out.amount0()), x0, 1, "outside principal c0");
        assertApproxEqAbs(uint128(out.amount1()), x1, 1, "outside principal c1");
    }

    function _liteExitAndConserve() internal {
        _liteExit(alice);
        _liteExit(bob);
        if (!_exclusive()) _outsideExit();
        for (uint256 i; i < 3; i++) {
            _claim(lps[i], LO, HI);
        }
        vm.startPrank(stranger);
        sl.sweepClaimFee(key.currency0);
        sl.sweepClaimFee(key.currency1);
        vm.stopPrank();

        assertEq(pm.getLiquidity(id), 0, "no liquidity left");
        Currency[2] memory cs = [key.currency0, key.currency1];
        for (uint256 i; i < 2; i++) {
            address a = Currency.unwrap(cs[i]);
            uint256 hookClaims = pm.balanceOf(hook, cs[i].toId());
            uint256 paid = lpFees[a] + IERC20(a).balanceOf(treasury);
            uint256 tol = 8 * swapsIn[a] + 64;
            assertApproxEqAbs(paid + hookClaims, feesCharged[a], tol, "fees paid out == fees charged");
            assertLe(hookClaims, 64, "hook keeps only rounding dust");
            assertLe(_bal(cs[i], PM_ADDR) - hookClaims, tol, "PoolManager keeps only rounding dust");
            assertEq(IERC20(a).balanceOf(hook), 0, "hook holds no tokens");
        }
        _assertSettled();
    }
}

/// @notice On FablesStableHookLite, next to an outside LP.
contract StableLiteFullCycleTest is StableLiteFullCycleBase {}

/// @notice On FablesStableHookLiteExclusive.
contract StableLiteFullCycleExclusiveTest is StableLiteFullCycleBase {
    function _exclusive() internal pure override returns (bool) {
        return true;
    }
}
