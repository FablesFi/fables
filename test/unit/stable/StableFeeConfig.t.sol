// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {FablesStableFee, StableFeeConfig} from "../../../src/base/FablesStableFee.sol";
import {FablesHookCore} from "../../../src/base/FablesHookCore.sol";
import {DiscountLib} from "../../../src/libraries/DiscountLib.sol";
import {Test} from "forge-std/Test.sol";
import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {FablesStableHookLite} from "../../../src/FablesStableHookLite.sol";
import {StableBuild} from "../../utils/Artifacts.sol";

/// @notice FablesStableFee config, view and whitelist-admin refusals on a Stable Lite build.
abstract contract StableFeeConfigBase is Test, Deployers {
    using PoolIdLibrary for PoolKey;

    uint24 internal constant K07 = 11_744_051;

    FablesStableHookLite internal hook;
    PoolId internal poolId;
    address internal lp = makeAddr("lp");
    address internal taker = makeAddr("taker");

    /// @notice The build under test: false = FablesStableHookLite, true = FablesStableHookLiteExclusive.
    function _exclusive() internal pure virtual returns (bool) {
        return false;
    }

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();
        AccessManager authority = new AccessManager(address(this));
        address at = address(uint160(0x4444 << 144) | StableBuild.flags(_exclusive()));
        deployCodeTo(StableBuild.artifact(_exclusive()), abi.encode(manager, address(authority)), at);
        hook = FablesStableHookLite(at);
        key = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 1, IHooks(at));
        poolId = key.toId();
    }

    function _cfg() internal pure returns (StableFeeConfig memory) {
        return StableFeeConfig({k: K07, optimalFeeE6: 50, targetMultiplier: 100, referenceSqrtPriceX96: SQRT_PRICE_1_1});
    }

    function _configure() internal {
        hook.configureStablePool(key, SQRT_PRICE_1_1, _cfg());
    }

    function _bounds() internal pure returns (uint256 lo, uint256 hi) {
        uint256 s = 994_987;
        lo = (uint256(TickMath.MIN_SQRT_PRICE) * 1e6 + s - 1) / s;
        hi = uint256(TickMath.MAX_SQRT_PRICE) * s / 1e6;
    }

    function _cfgWith(uint24 k, uint24 opt, uint8 tm, uint160 ref) internal pure returns (StableFeeConfig memory) {
        return StableFeeConfig({k: k, optimalFeeE6: opt, targetMultiplier: tm, referenceSqrtPriceX96: ref});
    }

    function test_configure_keyChecks() public {
        PoolKey memory k = key;
        k.fee = 3000;
        vm.expectRevert(abi.encodeWithSelector(FablesStableFee.MustUseDynamicFee.selector, uint24(3000)));
        hook.configureStablePool(k, SQRT_PRICE_1_1, _cfg());
        k = key;
        k.hooks = IHooks(address(0xBEEF));
        vm.expectRevert(abi.encodeWithSelector(FablesStableFee.InvalidHookAddress.selector, address(0xBEEF)));
        hook.configureStablePool(k, SQRT_PRICE_1_1, _cfg());
        k = key;
        k.currency0 = CurrencyLibrary.ADDRESS_ZERO;
        vm.expectRevert(FablesHookCore.NativeNotSupported.selector);
        hook.configureStablePool(k, SQRT_PRICE_1_1, _cfg());
        _configure();
        vm.expectRevert(FablesStableFee.PoolAlreadyConfigured.selector);
        _configure();
    }

    function test_configure_validators() public {
        (uint256 lo, uint256 hi) = _bounds();
        vm.expectRevert(abi.encodeWithSelector(FablesStableFee.InvalidK.selector, 0));
        hook.configureStablePool(key, SQRT_PRICE_1_1, _cfgWith(0, 50, 100, SQRT_PRICE_1_1));
        vm.expectRevert(abi.encodeWithSelector(FablesStableFee.InvalidOptimalFeeE6.selector, 10_001));
        hook.configureStablePool(key, SQRT_PRICE_1_1, _cfgWith(K07, 10_001, 100, SQRT_PRICE_1_1));
        vm.expectRevert(abi.encodeWithSelector(FablesStableFee.InvalidTargetMultiplier.selector, 0));
        hook.configureStablePool(key, SQRT_PRICE_1_1, _cfgWith(K07, 50, 0, SQRT_PRICE_1_1));
        vm.expectRevert(abi.encodeWithSelector(FablesStableFee.InvalidTargetMultiplier.selector, 101));
        hook.configureStablePool(key, SQRT_PRICE_1_1, _cfgWith(K07, 50, 101, SQRT_PRICE_1_1));
        vm.expectRevert(abi.encodeWithSelector(FablesStableFee.InvalidReferenceSqrtPriceX96.selector, lo - 1));
        hook.configureStablePool(key, SQRT_PRICE_1_1, _cfgWith(K07, 50, 100, uint160(lo - 1)));
        vm.expectRevert(abi.encodeWithSelector(FablesStableFee.InvalidReferenceSqrtPriceX96.selector, hi));
        hook.configureStablePool(key, SQRT_PRICE_1_1, _cfgWith(K07, 50, 100, uint160(hi)));
        hook.configureStablePool(key, SQRT_PRICE_1_1, _cfgWith(K07, 10_000, 1, uint160(lo)));
        (,,, uint160 ref) = hook.feeConfig(poolId);
        assertEq(ref, lo);
    }

    function test_updateFeeConfig_andViews() public {
        vm.expectRevert(abi.encodeWithSelector(FablesStableFee.PoolNotInitialized.selector, poolId));
        hook.updateFeeConfig(key, K07, 50, 100);
        vm.expectRevert(abi.encodeWithSelector(FablesStableFee.PoolNotInitialized.selector, poolId));
        hook.getFee(key);
        vm.expectRevert(abi.encodeWithSelector(FablesStableFee.PoolNotInitialized.selector, poolId));
        hook.currentFee(poolId, true);
        vm.expectRevert(abi.encodeWithSelector(FablesStableFee.PoolNotInitialized.selector, poolId));
        hook.feeFor(key, true, address(this));

        _configure();
        vm.expectRevert(abi.encodeWithSelector(FablesStableFee.InvalidK.selector, 0));
        hook.updateFeeConfig(key, 0, 50, 100);
        hook.updateFeeConfig(key, K07 / 2, 80, 50);
        (uint24 k, uint24 opt, uint8 tm, uint160 ref) = hook.feeConfig(poolId);
        assertEq(k, K07 / 2);
        assertEq(opt, 80);
        assertEq(tm, 50);
        assertEq(ref, SQRT_PRICE_1_1, "updateFeeConfig keeps the reference");
        (, uint160 cached, uint40 blockNumber) = hook.feeState(poolId);
        assertEq(cached, 0, "a config write resets the cached price");
        assertEq(blockNumber, block.number);
        (uint24 f0, uint24 f1) = hook.getFee(key);
        assertEq(f0, hook.currentFee(poolId, true));
        assertEq(f1, hook.currentFee(poolId, false));
    }

    function test_discountAdmin_refusals() public {
        PoolId[] memory ids = new PoolId[](1);
        ids[0] = poolId;
        uint40 exp = uint40(block.timestamp + 1 days);
        uint8 both = uint8(DiscountLib.DIR_BOTH);
        vm.expectRevert(FablesStableFee.InvalidDiscount.selector);
        hook.setDiscount(ids, address(0), 100, 0, both, exp);
        vm.expectRevert(FablesStableFee.InvalidDiscount.selector);
        hook.setDiscount(ids, taker, 5_001, 0, both, exp);
        vm.expectRevert(FablesStableFee.InvalidDiscount.selector);
        hook.setDiscount(ids, taker, 100, 0, 0, exp);
        vm.expectRevert(FablesStableFee.InvalidDiscount.selector);
        hook.setDiscount(ids, taker, 100, 0, both + 1, exp);
        vm.expectRevert(FablesStableFee.InvalidDiscount.selector);
        hook.setDiscount(ids, taker, 100, 0, both, uint40(block.timestamp));
        vm.expectRevert(FablesStableFee.InvalidDiscount.selector);
        hook.setDiscount(ids, taker, 100, 0, both, uint40(block.timestamp + 90 days + 1));
        vm.expectRevert(abi.encodeWithSelector(FablesStableFee.PoolNotInitialized.selector, poolId));
        hook.setDiscount(ids, taker, 100, 0, both, exp);
        vm.expectRevert(abi.encodeWithSelector(FablesStableFee.PoolNotInitialized.selector, poolId));
        hook.setDiscountFilter(poolId, 1, new address[](0));

        _configure();
        hook.setDiscount(ids, taker, 100, 7, both, exp);
        (uint16 bps, uint24 minFee, uint8 dirs, uint40 expiry) = hook.discountOf(poolId, taker);
        assertEq(abi.encode(bps, minFee, dirs, expiry), abi.encode(uint16(100), uint24(7), both, exp));
        (, uint32 bloom) = hook.discountFilter(poolId);
        assertTrue(bloom != 0);
        hook.setDiscount(ids, taker, 0, 0, both, 0);
        (bps,,,) = hook.discountOf(poolId, taker);
        assertEq(bps, 0);
        address[] memory accts = new address[](2);
        accts[0] = taker;
        accts[1] = lp;
        hook.setDiscountFilter(poolId, 3, accts);
        (uint8 seed, uint32 bloom2) = hook.discountFilter(poolId);
        assertEq(bloom2, 0, "only accounts holding an entry are re-listed");
        assertEq(seed, 3);
        PoolId[] memory ghost = new PoolId[](1);
        ghost[0] = PoolId.wrap(bytes32(uint256(1)));
        hook.revokeDiscount(ghost, accts);
    }
}

/// @notice On FablesStableHookLite.
contract StableFeeConfigTest is StableFeeConfigBase {}

/// @notice On FablesStableHookLiteExclusive.
contract StableFeeConfigExclusiveTest is StableFeeConfigBase {
    function _exclusive() internal pure override returns (bool) {
        return true;
    }
}
