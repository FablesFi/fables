// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FablesLedgerV2} from "../../src/base/FablesLedgerV2.sol";
import {RangeState} from "../../src/base/LedgerTypesV2.sol";
import {StableFeeConfig} from "../../src/base/FablesStableFee.sol";
import {BuildsFixture} from "../utils/BuildsFixture.sol";
import {StableBuild} from "../utils/Artifacts.sol";

/// @notice Stable Lite configure entry.
interface IStableLiteConfigure {
    function configureStablePool(PoolKey calldata key, uint160 sqrtPriceX96, StableFeeConfig calldata config)
        external
        returns (int24);
}

/// @notice On every build, a range pumped to 2^256 - 2^96 still pays a later holder exactly what an unpumped range
///         pays.
contract AccumulatorWrapEveryBuildTest is BuildsFixture {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    int24 internal constant LO = -60;
    int24 internal constant HI = 60;
    uint256 internal constant MAX_DONATION = (uint256(1) << 127) - 1;
    uint256 internal constant PUMPED = type(uint256).max - (uint256(1) << 96) + 1;
    uint128 internal constant L_VICTIM = 1e18;

    struct Outcome {
        uint256 fee0;
        uint256 fee1;
        uint256 principal0;
        uint256 principal1;
    }

    address internal victim = makeAddr("victim");
    FablesLedgerV2 internal hook;
    PoolKey internal k;
    uint256 internal rid;

    function setUp() public {
        _setUpStack();
        vm.deal(address(this), uint256(1) << 130);
        vm.deal(victim, 1e24);
        IERC20(Currency.unwrap(currency0)).transfer(victim, 1e24);
        IERC20(Currency.unwrap(currency1)).transfer(victim, 1e24);
    }

    function _openBuild(uint256 index, bool native) internal {
        Build memory b = _builds()[index];
        address h = _deploy(b, uint160(0x13B0 + index));
        k = native
            ? PoolKey(CurrencyLibrary.ADDRESS_ZERO, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(h))
            : _erc20Key(h, 60);
        _configureFlat(h, k, 3_000);
        _initPool(k, SQRT_PRICE_1_1);
        _wire(h);
    }

    function _openStableLite(bool exclusive) internal {
        address h = address((uint160(exclusive ? 0x13BE : 0x13BF) << 144) | StableBuild.flags(exclusive));
        deployCodeTo(StableBuild.artifact(exclusive), abi.encode(manager, address(authority)), h);
        k = _erc20Key(h, 60);
        IStableLiteConfigure(h)
            .configureStablePool(k, SQRT_PRICE_1_1, StableFeeConfig(11_744_051, 50, 100, SQRT_PRICE_1_1));
        IERC20(Currency.unwrap(currency0)).approve(h, type(uint256).max);
        IERC20(Currency.unwrap(currency1)).approve(h, type(uint256).max);
        _wire(h);
    }

    function _wire(address h) internal {
        hook = FablesLedgerV2(payable(h));
        rid = hook.rangeId(k.toId(), LO, HI);
        vm.startPrank(victim);
        IERC20(Currency.unwrap(currency0)).approve(h, type(uint256).max);
        IERC20(Currency.unwrap(currency1)).approve(h, type(uint256).max);
        vm.stopPrank();
    }

    function _native() internal view returns (bool) {
        return k.currency0.isAddressZero();
    }

    function _deposit(address who, uint128 liq) internal {
        uint256 v = _native() ? 1e20 : 0;
        vm.prank(who);
        hook.deposit{value: v}(
            k, LO, HI, liq, _native() ? uint128(v) : type(uint128).max, type(uint128).max, block.timestamp
        );
    }

    function _donate(uint256 amount) internal {
        donateRouter.donate{value: _native() ? amount : 0}(k, amount, amount, "");
    }

    function _window(uint256 amount) internal {
        _donate(amount);
        hook.claimFees(k, LO, HI, address(this), 10_000);
    }

    function _pump() internal {
        _deposit(address(this), 1);
        _window(MAX_DONATION);
        _window(MAX_DONATION);
        _deposit(address(this), (uint128(1) << 40) - 1);
        _window((uint256(1) << 41) - 256);
        hook.withdraw(k, LO, HI, uint128(1) << 40, address(this), 0, 0, block.timestamp);
        RangeState memory r = hook.rangeState(rid);
        assertEq(r.totalShares, 0, "range empty");
        assertEq(r.accFee0X128, PUMPED, "accFee0 parked at 2^256 - 2^96");
        assertEq(r.accFee1X128, PUMPED, "accFee1 parked at 2^256 - 2^96");
    }

    function _bal(Currency c, address who) internal view returns (uint256) {
        return c.isAddressZero() ? who.balance : IERC20(Currency.unwrap(c)).balanceOf(who);
    }

    function _swap(bool zeroForOne, uint256 amount) internal {
        swapRouter.swap{value: zeroForOne && _native() ? amount : 0}(
            k,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amount),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function _victimsLife() internal returns (Outcome memory o) {
        _deposit(victim, L_VICTIM);
        _swap(true, 1e16);
        _swap(false, 1e16);
        (uint256 a, uint256 b) = (_bal(k.currency0, victim), _bal(k.currency1, victim));
        vm.prank(victim);
        hook.claimFees(k, LO, HI, victim, 10_000);
        (o.fee0, o.fee1) = (_bal(k.currency0, victim) - a, _bal(k.currency1, victim) - b);
        vm.prank(victim);
        hook.transfer(address(0xBEEF), rid, 1);
        (a, b) = (_bal(k.currency0, victim), _bal(k.currency1, victim));
        vm.prank(victim);
        hook.withdraw(k, LO, HI, L_VICTIM - 1, victim, 0, 0, block.timestamp);
        (o.principal0, o.principal1) = (_bal(k.currency0, victim) - a, _bal(k.currency1, victim) - b);
        assertEq(hook.balanceOf(victim, rid), 0, "the victim is out");
    }

    function _check() internal {
        uint256 snap = vm.snapshotState();
        Outcome memory ctl = _victimsLife();
        assertGt(ctl.fee0, 0, "control earns currency0 fees");
        assertGt(ctl.fee1, 0, "control earns currency1 fees");
        vm.revertToState(snap);

        _pump();
        Outcome memory got = _victimsLife();
        RangeState memory r = hook.rangeState(rid);
        assertLt(r.accFee0X128, PUMPED, "currency0 level crossed 2^256");
        assertLt(r.accFee1X128, PUMPED, "currency1 level crossed 2^256");
        assertEq(got.fee0, ctl.fee0, "fee0");
        assertEq(got.fee1, ctl.fee1, "fee1");
        assertEq(got.principal0, ctl.principal0, "principal0");
        assertEq(got.principal1, ctl.principal1, "principal1");
    }

    function test_FablesHook() public {
        _openBuild(0, false);
        _check();
    }

    function test_FablesHookETH_erc20Pool() public {
        _openBuild(1, false);
        _check();
    }

    function test_FablesHookETH_nativePool() public {
        _openBuild(1, true);
        _check();
    }

    function test_FablesHookExclusive() public {
        _openBuild(2, false);
        _check();
    }

    function test_FablesHookETHExclusive_erc20Pool() public {
        _openBuild(3, false);
        _check();
    }

    function test_FablesHookETHExclusive_nativePool() public {
        _openBuild(3, true);
        _check();
    }

    function test_FablesStableHookLite() public {
        _openStableLite(false);
        _check();
    }

    function test_FablesStableHookLiteExclusive() public {
        _openStableLite(true);
        _check();
    }
}
