// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Test} from "forge-std/Test.sol";
import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {IAccessManaged} from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import {FablesStableFee, StableFeeConfig} from "../../../src/base/FablesStableFee.sol";
import {FablesStableHookLite} from "../../../src/FablesStableHookLite.sol";
import {DiscountLib} from "../../../src/libraries/DiscountLib.sol";
import {StableBuild} from "../../utils/Artifacts.sol";

/// @notice The Stable Lite keeper levers: bounded reference moves (`updateReferencePrice`) and the minimum fee
///         (`setMinimumFee`): bounds, pacing, roles, events, and what each keeps or resets.
abstract contract StableKeeperLeversBase is Test, Deployers {
    using PoolIdLibrary for PoolKey;

    uint24 internal constant K07 = 11_744_051;
    uint256 internal constant UNDEF = 1e12 + 1;
    uint256 internal constant Q96 = 1 << 96;

    FablesStableHookLite internal hook;
    AccessManager internal authority;
    PoolId internal poolId;
    address internal stranger = makeAddr("stranger");

    event FeeConfigUpdated(PoolId indexed poolId, StableFeeConfig feeConfig);
    event MinimumFeeSet(PoolId indexed poolId, uint16 minimumFee);

    /// @notice The build under test: false = FablesStableHookLite, true = FablesStableHookLiteExclusive.
    function _exclusive() internal pure virtual returns (bool) {
        return false;
    }

    function setUp() public {
        vm.warp(1_800_000_000);
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();
        authority = new AccessManager(address(this));
        address at = address(uint160(0x4545 << 144) | StableBuild.flags(_exclusive()));
        deployCodeTo(StableBuild.artifact(_exclusive()), abi.encode(manager, address(authority)), at);
        hook = FablesStableHookLite(at);
        key = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 1, IHooks(at));
        poolId = key.toId();
        MockERC20(Currency.unwrap(currency0)).approve(at, type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(at, type(uint256).max);
    }

    function _cfg(uint160 ref) internal pure returns (StableFeeConfig memory) {
        return StableFeeConfig({k: K07, optimalFeeE6: 50, targetMultiplier: 100, referenceSqrtPriceX96: ref});
    }

    function _configure() internal {
        hook.configureStablePool(key, SQRT_PRICE_1_1, _cfg(SQRT_PRICE_1_1));
    }

    /// @dev sqrt(ref^2 * ppm / 1e6): the reference whose price is `ppm` parts per million of `ref`'s.
    function _scaled(uint160 ref, uint256 ppm) internal pure returns (uint160) {
        return uint160(FixedPointMathLib.sqrt(FixedPointMathLib.fullMulDiv(uint256(ref) * ref, ppm, 1e6)));
    }

    function _fund() internal {
        hook.deposit(key, -600, 600, 1e21, type(uint128).max, type(uint128).max, block.timestamp);
    }

    function _swap(bool zeroForOne) internal {
        swapRouter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -1e18,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    /* --------------------------------------------- reference moves --------------------------------------------- */

    function test_move_storesResetsAndEmits() public {
        _configure();
        hook.updateFeeConfig(key, K07 / 3, 80, 40);
        _fund();
        _swap(true);
        (uint40 d0,, uint40 bn0) = hook.feeState(poolId);
        assertTrue(d0 != UNDEF || bn0 != 0, "swap wrote the state");

        uint160 next = _scaled(SQRT_PRICE_1_1, 999_500);
        vm.roll(block.number + 7);
        vm.expectEmit(true, false, false, true, address(hook));
        emit FeeConfigUpdated(poolId, StableFeeConfig(K07 / 3, 80, 40, next));
        hook.updateReferencePrice(key, next);

        (uint24 k, uint24 opt, uint8 tm, uint160 ref) = hook.feeConfig(poolId);
        assertEq(abi.encode(k, opt, tm, ref), abi.encode(K07 / 3, uint24(80), uint8(40), next), "config");
        (uint40 d, uint160 cached, uint40 bn) = hook.feeState(poolId);
        assertEq(d, UNDEF, "decaying fee reset");
        assertEq(cached, 0, "cached price reset");
        assertEq(bn, block.number, "clock reset");
        assertEq(hook.referenceUpdatedAt(poolId), block.timestamp, "move time");
    }

    function test_move_firstMoveRightAfterCreation() public {
        _configure();
        assertEq(hook.referenceUpdatedAt(poolId), 0);
        hook.updateReferencePrice(key, _scaled(SQRT_PRICE_1_1, 1_000_900));
    }

    function test_move_stepBound_bothDirections() public {
        _configure();
        uint160 r = SQRT_PRICE_1_1;
        vm.expectRevert(FablesStableHookLite.ReferenceStepTooLarge.selector);
        hook.updateReferencePrice(key, _scaled(r, 998_999));
        vm.expectRevert(FablesStableHookLite.ReferenceStepTooLarge.selector);
        hook.updateReferencePrice(key, _scaled(r, 1_001_002));
        hook.updateReferencePrice(key, _scaled(r, 999_001));
        r = _scaled(r, 999_001);
        vm.warp(block.timestamp + 60);
        // up by just under 0.1% of the new price: 1e6 / 0.999 = 1_001_001.0
        hook.updateReferencePrice(key, _scaled(r, 1_001_000));
        (,,, uint160 ref) = hook.feeConfig(poolId);
        assertEq(ref, _scaled(r, 1_001_000));
    }

    function test_move_sameReferenceIsAMoveToo() public {
        _configure();
        hook.updateReferencePrice(key, SQRT_PRICE_1_1);
        vm.expectRevert(FablesStableHookLite.ReferenceUpdateTooSoon.selector);
        hook.updateReferencePrice(key, SQRT_PRICE_1_1);
    }

    function test_move_pacedPerPool() public {
        _configure();
        PoolKey memory other = key;
        other.tickSpacing = 10;
        hook.configureStablePool(other, SQRT_PRICE_1_1, _cfg(SQRT_PRICE_1_1));

        hook.updateReferencePrice(key, _scaled(SQRT_PRICE_1_1, 999_500));
        hook.updateReferencePrice(other, _scaled(SQRT_PRICE_1_1, 1_000_500));
        vm.warp(block.timestamp + 59);
        vm.expectRevert(FablesStableHookLite.ReferenceUpdateTooSoon.selector);
        hook.updateReferencePrice(key, _scaled(SQRT_PRICE_1_1, 999_000));
        vm.warp(block.timestamp + 1);
        hook.updateReferencePrice(key, _scaled(SQRT_PRICE_1_1, 999_000));
        hook.updateReferencePrice(other, _scaled(SQRT_PRICE_1_1, 1_001_000));
    }

    function test_move_refusals() public {
        vm.expectRevert(abi.encodeWithSelector(FablesStableFee.PoolNotInitialized.selector, poolId));
        hook.updateReferencePrice(key, SQRT_PRICE_1_1);
        _configure();
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger));
        hook.updateReferencePrice(key, SQRT_PRICE_1_1);
    }

    function test_move_mustStayInsideV4Range() public {
        uint256 s = 994_987;
        uint160 lo = uint160((uint256(TickMath.MIN_SQRT_PRICE) * 1e6 + s - 1) / s);
        uint160 hi = uint160(uint256(TickMath.MAX_SQRT_PRICE) * s / 1e6);
        hook.configureStablePool(key, lo, _cfg(lo));
        uint160 below = lo - 1;
        vm.expectRevert(abi.encodeWithSelector(FablesStableFee.InvalidReferenceSqrtPriceX96.selector, below));
        hook.updateReferencePrice(key, below);

        PoolKey memory top = key;
        top.tickSpacing = 10;
        hook.configureStablePool(top, hi - 1, _cfg(hi - 1));
        vm.expectRevert(abi.encodeWithSelector(FablesStableFee.InvalidReferenceSqrtPriceX96.selector, hi));
        hook.updateReferencePrice(top, hi);
    }

    function test_move_keepsMinimumFeeAndWhitelist() public {
        _configure();
        hook.setMinimumFee(key, 321);
        PoolId[] memory ids = new PoolId[](1);
        ids[0] = poolId;
        hook.setDiscount(ids, stranger, 1_000, 0, uint8(DiscountLib.DIR_BOTH), uint40(block.timestamp + 1 days));
        (uint8 seed, uint32 bloom) = hook.discountFilter(poolId);
        hook.updateReferencePrice(key, _scaled(SQRT_PRICE_1_1, 1_000_700));
        assertEq(hook.minimumFee(poolId), 321, "minimum fee kept");
        (uint8 seed2, uint32 bloom2) = hook.discountFilter(poolId);
        assertEq(abi.encode(seed2, bloom2), abi.encode(seed, bloom), "whitelist kept");
    }

    /// forge-config: default.fuzz.runs = 512
    function testFuzz_move_acceptsExactlyTheStep(uint256 ppm, uint256 refTick) public {
        int24 t = int24(int256(bound(refTick, 0, 200_000))) - 100_000;
        uint160 r = TickMath.getSqrtPriceAtTick(t);
        hook.configureStablePool(key, r, _cfg(r));
        ppm = bound(ppm, 990_000, 1_010_000);
        uint160 next = _scaled(r, ppm);
        // independent check in 1e18: price ratio min/max >= 0.999, with a guard band for the two roundings
        uint256 a = uint256(next) * next;
        uint256 b = uint256(r) * r;
        uint256 ratioWad = a < b ? FixedPointMathLib.fullMulDiv(a, 1e18, b) : FixedPointMathLib.fullMulDiv(b, 1e18, a);
        if (ratioWad >= 0.999e18 + 1e9) {
            hook.updateReferencePrice(key, next);
            (,,, uint160 ref) = hook.feeConfig(poolId);
            assertEq(ref, next);
        } else if (ratioWad + 1e9 < 0.999e18) {
            vm.expectRevert(FablesStableHookLite.ReferenceStepTooLarge.selector);
            hook.updateReferencePrice(key, next);
        }
    }

    /* ----------------------------------------------- minimum fee ----------------------------------------------- */

    function test_minFee_onlyLoweringResetsState() public {
        _configure();
        _fund();
        hook.setMinimumFee(key, 100);
        _swap(true);
        (uint40 d, uint160 sp, uint40 bn) = hook.feeState(poolId);
        vm.roll(block.number + 2);
        hook.setMinimumFee(key, 100);
        hook.setMinimumFee(key, 300);
        (uint40 d2, uint160 sp2, uint40 bn2) = hook.feeState(poolId);
        assertEq(abi.encode(d2, sp2, bn2), abi.encode(d, sp, bn), "same value or a raise keeps the fee state");
        hook.setMinimumFee(key, 299);
        (d2, sp2, bn2) = hook.feeState(poolId);
        assertEq(
            abi.encode(d2, sp2, bn2), abi.encode(uint40(UNDEF), uint160(0), uint40(block.number)), "lowering resets"
        );
    }

    function test_minFee_setViewEmitResetsState() public {
        _configure();
        _fund();
        _swap(true);
        (uint40 d0,, uint40 bn0) = hook.feeState(poolId);
        assertTrue(d0 != UNDEF || bn0 != 0, "swap wrote the state");
        (uint24 k, uint24 opt, uint8 tm, uint160 ref) = hook.feeConfig(poolId);
        vm.roll(block.number + 3);
        assertEq(hook.minimumFee(poolId), 0, "default 0");

        vm.expectEmit(true, false, false, true, address(hook));
        emit MinimumFeeSet(poolId, type(uint16).max);
        hook.setMinimumFee(key, type(uint16).max);
        assertEq(hook.minimumFee(poolId), type(uint16).max);
        hook.setMinimumFee(key, 9);
        assertEq(hook.minimumFee(poolId), 9, "lowered: the state resets");

        (uint40 d2, uint160 sp2, uint40 bn2) = hook.feeState(poolId);
        assertEq(d2, UNDEF, "decaying fee reset");
        assertEq(sp2, 0, "cached price reset");
        assertEq(bn2, block.number, "clock reset");
        (uint24 k2, uint24 opt2, uint8 tm2, uint160 ref2) = hook.feeConfig(poolId);
        assertEq(abi.encode(k2, opt2, tm2, ref2), abi.encode(k, opt, tm, ref), "config untouched");
    }

    function test_minFee_survivesStateWritesAndConfigResets() public {
        _configure();
        _fund();
        hook.setMinimumFee(key, 77);
        _swap(true);
        vm.roll(block.number + 3);
        _swap(false);
        assertEq(hook.minimumFee(poolId), 77, "swap state writes keep it");
        hook.updateFeeConfig(key, K07, 10, 100);
        assertEq(hook.minimumFee(poolId), 77, "config reset keeps it");
        hook.updateReferencePrice(key, _scaled(SQRT_PRICE_1_1, 1_000_100));
        assertEq(hook.minimumFee(poolId), 77, "reference move keeps it");
        hook.setMinimumFee(key, 0);
        assertEq(hook.minimumFee(poolId), 0);
    }

    function test_minFee_refusals() public {
        vm.expectRevert(abi.encodeWithSelector(FablesStableFee.PoolNotInitialized.selector, poolId));
        hook.setMinimumFee(key, 1);
        _configure();
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger));
        hook.setMinimumFee(key, 1);
    }

    function test_constants() public view {
        assertEq(hook.MAX_REFERENCE_STEP_E6(), 1_000);
        assertEq(hook.REFERENCE_UPDATE_INTERVAL(), 60);
    }
}

/// @notice On FablesStableHookLite.
contract StableKeeperLeversTest is StableKeeperLeversBase {}

/// @notice On FablesStableHookLiteExclusive.
contract StableKeeperLeversExclusiveTest is StableKeeperLeversBase {
    function _exclusive() internal pure override returns (bool) {
        return true;
    }
}
