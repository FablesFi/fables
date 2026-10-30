// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {IAccessManaged} from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";

import {FablesHookCore} from "../../../src/base/FablesHookCore.sol";
import {FablesFeeEngine} from "../../../src/base/FablesFeeEngine.sol";
import {PoolWordLib} from "../../../src/libraries/PoolWordLib.sol";
import {DiscountLib} from "../../../src/libraries/DiscountLib.sol";
import {FeeRef} from "../../../src/libraries/FeeRef.sol";
import {EngineHarness, EngineSymmetricHarness} from "../../utils/EngineHarness.sol";

/// @notice FablesFeeEngine: constants, categories, configurePool, the creation gate, pokes and the raise step, discount
///         and CF admin, views, role gates, and setter field isolation.
contract FablesFeeEngineTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using PoolWordLib for uint256;
    using StateLibrary for IPoolManager;

    uint64 constant FEE_POKER = 1;
    uint64 constant PAUSER = 4;
    uint64 constant DISCOUNT_ADMIN = 14;
    uint256 constant SOME_TS = 1_785_859_200;

    uint8 constant STOCK = 1;
    uint8 constant MEME = 2;
    uint8 constant FREE = 3;

    AccessManager authority;
    EngineHarness hook;
    EngineSymmetricHarness sym;
    address poker = makeAddr("poker");
    address pauser = makeAddr("pauser");
    address discountAdmin = makeAddr("discountAdmin");
    address stranger = makeAddr("stranger");
    address desk = makeAddr("desk");

    PoolId poolId;
    PoolKey symKey;
    PoolId symPoolId;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();
        authority = new AccessManager(address(this));

        address hookAddr = address(uint160(0x4444 << 144) | uint160(Hooks.BEFORE_INITIALIZE_FLAG));
        deployCodeTo("EngineHarness.sol:EngineHarness", abi.encode(manager, address(authority)), hookAddr);
        hook = EngineHarness(hookAddr);
        address symAddr = address(uint160(0x5555 << 144) | uint160(Hooks.BEFORE_INITIALIZE_FLAG));
        deployCodeTo("EngineHarness.sol:EngineSymmetricHarness", abi.encode(manager, address(authority)), symAddr);
        sym = EngineSymmetricHarness(symAddr);

        _bindRoles(hookAddr);
        _bindRoles(symAddr);
        authority.grantRole(FEE_POKER, poker, 0);
        authority.grantRole(PAUSER, pauser, 0);
        authority.grantRole(DISCOUNT_ADMIN, discountAdmin, 0);

        _seedCategories(hook);
        _seedCategories(sym);

        vm.warp(SOME_TS);
        key = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(hookAddr));
        hook.configurePool(key, STOCK, 700, 900, 300, 8000);
        poolId = key.toId();
        hook.initializePool(key, SQRT_PRICE_1_1);

        symKey = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(symAddr));
        sym.configurePool(symKey, STOCK, 700, 700, 300, 8000);
        symPoolId = symKey.toId();
        sym.initializePool(symKey, SQRT_PRICE_1_1);
    }

    function _bindRoles(address target) internal {
        bytes4[] memory s = new bytes4[](2);
        s[0] = FablesFeeEngine.pokeFee.selector;
        s[1] = FablesFeeEngine.setCFActive.selector;
        authority.setTargetFunctionRole(target, s, FEE_POKER);
        bytes4[] memory p = new bytes4[](3);
        p[0] = FablesFeeEngine.clearPoke.selector;
        p[1] = FablesFeeEngine.killCF.selector;
        p[2] = FablesFeeEngine.revokeDiscount.selector;
        authority.setTargetFunctionRole(target, p, PAUSER);
        bytes4[] memory d = new bytes4[](2);
        d[0] = FablesFeeEngine.setDiscount.selector;
        d[1] = FablesFeeEngine.setDiscountFilter.selector;
        authority.setTargetFunctionRole(target, d, DISCOUNT_ADMIN);
    }

    function _seedCategories(FablesFeeEngine e) internal {
        e.setCategory(STOCK, 0, 50_000, 2500, "STOCK");
        e.setCategory(MEME, 2500, 100_000, 10_000, "MEME");
        e.setCategory(FREE, 0, 100_000, 100_000, "FREE");
    }

    function _key(int24 spacing) internal view returns (PoolKey memory) {
        return PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, spacing, IHooks(address(hook)));
    }

    function _ids(PoolId id) internal pure returns (PoolId[] memory ids) {
        ids = new PoolId[](1);
        ids[0] = id;
    }

    function _accounts(address a) internal pure returns (address[] memory as_) {
        as_ = new address[](1);
        as_[0] = a;
    }

    function _unauthorized(address who) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, who);
    }

    function test_constants() public view {
        assertEq(hook.ABSOLUTE_MAX_FEE(), 100_000);
        assertEq(hook.MIN_POOL_FEE(), 0);
        assertEq(hook.MAX_POKE_TTL(), 72 hours);
        assertEq(hook.MAX_POKE_DISCOUNT_BPS(), 5_000);
        assertEq(hook.RAISE_INTERVAL(), 60);
        assertEq(hook.MAX_DISCOUNT_BPS(), 5_000);
        assertEq(hook.MAX_DISCOUNT_TERM(), 90 days);
        assertEq(hook.MAX_CF_K_Q8(), 256);
        assertEq(hook.MAX_CF_CAP(), 2_500);
        assertEq(hook.MAX_CF_BAND16(), 800);
        assertEq(hook.MIN_CF_TAU(), 5);
        assertEq(hook.MAX_CF_TAU(), 300);
        assertEq(hook.MAX_CF_PERIOD(), 60);
        assertEq(address(hook.poolManager()), address(manager));
        assertEq(hook.authority(), address(authority));
    }

    function test_pokeSurfaceSelectors() public pure {
        assertEq(FablesFeeEngine.pokeFee.selector, bytes4(keccak256("pokeFee(bytes32,uint24,uint24,uint40)")));
        assertEq(FablesFeeEngine.clearPoke.selector, bytes4(keccak256("clearPoke(bytes32)")));
        assertEq(FablesFeeEngine.pokeOf.selector, bytes4(keccak256("pokeOf(bytes32)")));
        assertEq(FablesFeeEngine.FeePoked.selector, keccak256("FeePoked(bytes32,uint24,uint24,uint40)"));
        assertEq(FablesFeeEngine.PokeCleared.selector, keccak256("PokeCleared(bytes32)"));
    }

    function test_setCategory_validation() public {
        vm.expectRevert(FablesFeeEngine.InvalidCategory.selector);
        hook.setCategory(9, 0, 100_001, 1, "too high");
        vm.expectRevert(FablesFeeEngine.InvalidCategory.selector);
        hook.setCategory(9, 501, 500, 1, "floorMin > capMax");
        vm.expectRevert(FablesFeeEngine.InvalidCategory.selector);
        hook.setCategory(9, 0, 500, 0, "raiseStep 0");
        hook.setCategory(9, 100_000, 100_000, 100_000, "edge");
        hook.setCategory(8, 0, 0, 1, "retired: no pool can be configured in it");
    }

    function test_setCategory_writesAndEmits() public {
        vm.expectEmit(address(hook));
        emit FablesFeeEngine.CategorySet(7, 100, 2000, 50, "LABEL");
        hook.setCategory(7, 100, 2000, 50, "LABEL");
        FablesFeeEngine.Category memory c = hook.category(7);
        assertEq(c.floorMin, 100);
        assertEq(c.capMax, 2000);
        assertEq(c.raiseStep, 50);
        assertTrue(c.exists);
        assertFalse(hook.category(200).exists, "unset category does not exist");
    }

    function test_configurePool_refusesForeignHookAndStaticFee() public {
        PoolKey memory foreign = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(address(sym)));
        vm.expectRevert(FablesHookCore.PoolNotConfigured.selector);
        hook.configurePool(foreign, STOCK, 700, 700, 300, 8000);
        PoolKey memory statik = PoolKey(currency0, currency1, 3000, 60, IHooks(address(hook)));
        vm.expectRevert(FablesFeeEngine.NotDynamicFeePool.selector);
        hook.configurePool(statik, STOCK, 700, 700, 300, 8000);
        vm.expectRevert(FablesFeeEngine.InvalidCategory.selector);
        hook.configurePool(_key(120), 42, 700, 700, 300, 8000);
    }

    function test_configurePool_validationChain() public {
        PoolKey memory k = _key(120);
        vm.expectRevert(FablesFeeEngine.InvalidConfig.selector);
        hook.configurePool(k, STOCK, 700, 700, 300, 0);
        vm.expectRevert(FablesFeeEngine.InvalidConfig.selector);
        hook.configurePool(k, STOCK, 700, 700, 300, 50_001);
        vm.expectRevert(FablesFeeEngine.InvalidConfig.selector);
        hook.configurePool(k, STOCK, 700, 8001, 300, 8000);
        vm.expectRevert(FablesFeeEngine.InvalidConfig.selector);
        hook.configurePool(k, STOCK, 8001, 700, 300, 8000);
        vm.expectRevert(FablesFeeEngine.InvalidConfig.selector);
        hook.configurePool(k, STOCK, 700, 900, 701, 8000);
        vm.expectRevert(FablesFeeEngine.InvalidConfig.selector);
        hook.configurePool(k, MEME, 5000, 5000, 2499, 50_000);
        hook.configurePool(k, STOCK, 1, 1, 1, 1);
        hook.configurePool(k, STOCK, 0, 0, 0, 1);
        hook.configurePool(k, STOCK, 50_000, 50_000, 50_000, 50_000);
    }

    function test_configurePool_writesWordMetaAndMaxFee() public {
        PoolKey memory k = _key(120);
        PoolId id = k.toId();
        assertEq(hook.maxFee(id), 0);
        vm.expectEmit(address(hook));
        emit FablesFeeEngine.PoolFeeConfigured(id, MEME, 3000, 4000, 2500, 60_000);
        hook.configurePool(k, MEME, 3000, 4000, 2500, 60_000);
        PoolWordLib.PoolWord memory p = hook.poolFee(id);
        assertEq(p.base0, 3000);
        assertEq(p.base1, 4000);
        assertEq(p.floor, 2500);
        assertEq(p.cap, 60_000);
        assertEq(p.poke0, 0);
        assertEq(p.expiry, 0);
        assertEq(p.bloom, 0);
        assertFalse(p.cfOn);
        assertEq(hook.maxFee(id), 60_000, "core marker mirrors the cap");
        assertEq(hook.categoryOf(id), MEME);
        assertEq(hook.autonomousFee(id, true), 3000);
        assertEq(hook.autonomousFee(id, false), 4000);
    }

    function test_configurePool_reconfigurePreservesOtherRolesFields() public {
        vm.prank(poker);
        hook.pokeFee(poolId, 2000, 0, 1 hours);
        vm.prank(discountAdmin);
        hook.setDiscount(_ids(poolId), desk, 1000, 0, 3, uint40(block.timestamp + 1 days));
        vm.prank(discountAdmin);
        hook.setDiscountFilter(poolId, 77, _accounts(desk));
        hook.configureCF(poolId, 0, 256, 1000, 80, 60, 15);
        vm.prank(poker);
        hook.setCFActive(poolId, true, TickMath.MIN_TICK, TickMath.MAX_TICK, type(uint256).max);
        uint256 before = hook.poolWord(poolId);

        hook.configurePool(key, MEME, 3000, 3000, 2500, 20_000);
        uint256 after_ = hook.poolWord(poolId);
        assertEq(after_.base0(), 3000);
        assertEq(after_.base1(), 3000);
        assertEq(after_.floor(), 2500);
        assertEq(after_.cap(), 20_000);
        assertEq(
            after_ & ~(PoolWordLib.BASES_MASK | PoolWordLib.BOUNDS_MASK),
            before & ~(PoolWordLib.BASES_MASK | PoolWordLib.BOUNDS_MASK),
            "other roles' fields moved"
        );
        assertEq(after_.poke0(), 2000);
        assertEq(after_.seed(), 77);
        assertTrue(after_.cfOn());
        assertEq(hook.categoryOf(poolId), MEME);
        assertEq(hook.maxFee(poolId), 20_000);
        assertEq(FeeRef.keeperFee(after_, true, block.timestamp), 2500);
        vm.expectRevert(FablesFeeEngine.InvalidConfig.selector);
        hook.configurePool(key, MEME, 0, 0, 0, 0);
        assertEq(hook.maxFee(poolId), 20_000);
    }

    function test_configurePool_symmetricModeRequiresEqualBases() public {
        vm.expectRevert(FablesFeeEngine.SymmetricRequired.selector);
        sym.configurePool(symKey, STOCK, 700, 900, 300, 8000);
        uint256 writes = sym.feeWrites();
        sym.configurePool(symKey, STOCK, 800, 800, 300, 8000);
        assertEq(sym.feeWrites(), writes + 1, "_onFeeWrite called once per configurePool");
        assertEq(PoolId.unwrap(sym.lastFeeWrite()), PoolId.unwrap(symPoolId));
    }

    function test_beforeInitialize_gate() public {
        PoolKey memory k = _key(120);
        hook.configurePool(k, STOCK, 700, 700, 300, 8000);
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeInitialize.selector,
                abi.encodeWithSelector(FablesFeeEngine.InvalidInitializer.selector, address(this)),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        manager.initialize(k, SQRT_PRICE_1_1);

        vm.expectRevert(FablesHookCore.PoolNotConfigured.selector);
        hook.initializePool(_key(30), SQRT_PRICE_1_1);

        PoolKey memory statik = PoolKey(currency0, currency1, 3000, 60, IHooks(address(hook)));
        vm.expectRevert(FablesFeeEngine.NotDynamicFeePool.selector);
        hook.configurePool(statik, STOCK, 700, 700, 300, 8000);
        vm.expectRevert(FablesHookCore.PoolNotConfigured.selector);
        hook.initializePool(statik, SQRT_PRICE_1_1);

        PoolKey memory native =
            PoolKey(CurrencyLibrary.ADDRESS_ZERO, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(address(hook)));
        hook.configurePool(native, STOCK, 700, 700, 300, 8000);
        vm.expectRevert(FablesHookCore.NativeNotSupported.selector);
        hook.initializePool(native, SQRT_PRICE_1_1);

        hook.initializePool(k, SQRT_PRICE_1_1);
        (uint160 sp,,,) = manager.getSlot0(k.toId());
        assertEq(sp, SQRT_PRICE_1_1);

        vm.expectRevert(FablesHookCore.NotPoolManager.selector);
        hook.beforeInitialize(address(hook), k, SQRT_PRICE_1_1);
    }

    function test_pokeFee_bounds() public {
        vm.startPrank(poker);
        vm.expectRevert(FablesHookCore.PoolNotConfigured.selector);
        hook.pokeFee(_key(120).toId(), 1000, 1000, 1 hours);
        vm.expectRevert(FablesFeeEngine.EmptyPoke.selector);
        hook.pokeFee(poolId, 0, 0, 1 hours);
        vm.expectRevert(FablesFeeEngine.InvalidTtl.selector);
        hook.pokeFee(poolId, 1000, 1000, 0);
        vm.expectRevert(FablesFeeEngine.InvalidTtl.selector);
        hook.pokeFee(poolId, 1000, 1000, 72 hours + 1);
        vm.expectRevert(FablesFeeEngine.FeeAboveCap.selector);
        hook.pokeFee(poolId, 8001, 0, 1 hours);
        vm.expectRevert(FablesFeeEngine.FeeAboveCap.selector);
        hook.pokeFee(poolId, 0, 8001, 1 hours);
        vm.expectRevert(FablesFeeEngine.FeeBelowFloor.selector);
        hook.pokeFee(poolId, 299, 0, 1 hours);
        vm.expectRevert(FablesFeeEngine.FeeBelowFloor.selector);
        hook.pokeFee(poolId, 0, 299, 1 hours);
        vm.stopPrank();
    }

    function test_pokeFee_writesAndEmits() public {
        uint40 expiry = uint40(block.timestamp + 2 hours);
        vm.expectEmit(address(hook));
        emit FablesFeeEngine.FeePoked(poolId, 2000, 0, expiry);
        vm.prank(poker);
        hook.pokeFee(poolId, 2000, 0, 2 hours);
        (uint24 f0, uint24 f1, uint40 e) = hook.pokeOf(poolId);
        assertEq(f0, 2000);
        assertEq(f1, 0, "sentinel side");
        assertEq(e, expiry);
        assertEq(FeeRef.keeperFee(hook.poolWord(poolId), true, block.timestamp), 2000);
        assertEq(FeeRef.keeperFee(hook.poolWord(poolId), false, block.timestamp), 900, "sentinel keeps base1");
        assertEq(hook.lastRaiseAt(poolId), uint40(block.timestamp), "a raise stamps lastRaiseAt");
    }

    function test_pokeFee_categoryCapBindsAtOnce() public {
        hook.setCategory(STOCK, 0, 5000, 2500, "STOCK tightened");
        vm.prank(poker);
        vm.expectRevert(FablesFeeEngine.FeeAboveCap.selector);
        hook.pokeFee(poolId, 5001, 0, 1 hours);
        vm.prank(poker);
        hook.pokeFee(poolId, 3000, 0, 1 hours);
        assertEq(hook.poolFee(poolId).cap, 8000, "the pool cap is untouched");
    }

    function test_pokeFee_raiseStep() public {
        vm.startPrank(poker);
        vm.expectRevert(FablesFeeEngine.RaiseTooLarge.selector);
        hook.pokeFee(poolId, 3201, 0, 1 hours);
        hook.pokeFee(poolId, 3200, 0, 1 hours);
        assertEq(hook.lastRaiseAt(poolId), uint40(block.timestamp));
        vm.expectRevert(FablesFeeEngine.RaiseTooSoon.selector);
        hook.pokeFee(poolId, 3201, 0, 1 hours);
        hook.pokeFee(poolId, 3200, 0, 3 hours);
        hook.pokeFee(poolId, 400, 0, 1 hours);
        assertEq(hook.lastRaiseAt(poolId), uint40(block.timestamp), "cuts do not stamp lastRaiseAt");
        vm.warp(block.timestamp + 59);
        vm.expectRevert(FablesFeeEngine.RaiseTooSoon.selector);
        hook.pokeFee(poolId, 2900, 0, 1 hours);
        vm.warp(block.timestamp + 1);
        vm.expectRevert(FablesFeeEngine.RaiseTooLarge.selector);
        hook.pokeFee(poolId, 2901, 0, 1 hours);
        hook.pokeFee(poolId, 2900, 0, 1 hours);
        vm.stopPrank();
    }

    function test_pokeFee_raiseStepChecksBothSides() public {
        vm.startPrank(poker);
        vm.expectRevert(FablesFeeEngine.RaiseTooLarge.selector);
        hook.pokeFee(poolId, 400, 3401, 1 hours);
        vm.expectRevert(FablesFeeEngine.RaiseTooLarge.selector);
        hook.pokeFee(poolId, 3201, 400, 1 hours);
        hook.pokeFee(poolId, 3200, 3400, 1 hours);
        vm.stopPrank();
    }

    function test_pokeFee_raiseStepUsesTheResolvedFee() public {
        hook.configurePool(key, STOCK, 4000, 4000, 300, 8000);
        vm.startPrank(poker);
        hook.pokeFee(poolId, 300, 300, 1 hours);
        assertEq(FeeRef.keeperFee(hook.poolWord(poolId), true, block.timestamp), 2000);
        hook.pokeFee(poolId, 4500, 4500, 1 hours);
        vm.warp(block.timestamp + 2 hours);
        assertEq(FeeRef.keeperFee(hook.poolWord(poolId), true, block.timestamp), 4000);
        hook.pokeFee(poolId, 6500, 6500, 1 hours);
        vm.stopPrank();
    }

    function test_pokeFee_symmetricModeRequiresEqualSidesAndSyncs() public {
        vm.startPrank(poker);
        vm.expectRevert(FablesFeeEngine.SymmetricRequired.selector);
        sym.pokeFee(symPoolId, 2000, 2100, 1 hours);
        vm.expectRevert(FablesFeeEngine.SymmetricRequired.selector);
        sym.pokeFee(symPoolId, 2000, 0, 1 hours);
        uint256 writes = sym.feeWrites();
        sym.pokeFee(symPoolId, 2000, 2000, 1 hours);
        assertEq(sym.feeWrites(), writes + 1, "_onFeeWrite called once per pokeFee");
        vm.stopPrank();
    }

    function test_clearPoke() public {
        vm.prank(poker);
        hook.pokeFee(poolId, 2000, 3000, 1 hours);
        vm.prank(pauser);
        vm.expectRevert(FablesHookCore.PoolNotConfigured.selector);
        hook.clearPoke(_key(120).toId());
        uint256 before = hook.poolWord(poolId);
        vm.expectEmit(address(hook));
        emit FablesFeeEngine.PokeCleared(poolId);
        vm.prank(pauser);
        hook.clearPoke(poolId);
        uint256 after_ = hook.poolWord(poolId);
        (uint24 f0, uint24 f1, uint40 e) = hook.pokeOf(poolId);
        assertEq(f0, 0);
        assertEq(f1, 0);
        assertEq(e, 0);
        assertEq(after_ & ~PoolWordLib.POKES_MASK, before & ~PoolWordLib.POKES_MASK, "clearPoke touched other fields");
        vm.prank(poker);
        vm.expectRevert(FablesFeeEngine.RaiseTooSoon.selector);
        hook.pokeFee(poolId, 3000, 0, 1 hours);
        vm.prank(poker);
        sym.pokeFee(symPoolId, 2000, 2000, 1 hours);
        uint256 writes = sym.feeWrites();
        vm.prank(pauser);
        sym.clearPoke(symPoolId);
        assertEq(sym.feeWrites(), writes + 1);
    }

    function test_setDiscount_validation() public {
        uint40 ok = uint40(block.timestamp + 1 days);
        vm.startPrank(discountAdmin);
        vm.expectRevert(FablesFeeEngine.InvalidDiscount.selector);
        hook.setDiscount(_ids(poolId), address(0), 1000, 0, 3, ok);
        vm.expectRevert(FablesFeeEngine.InvalidDiscount.selector);
        hook.setDiscount(_ids(poolId), desk, 5001, 0, 3, ok);
        vm.expectRevert(FablesFeeEngine.InvalidDiscount.selector);
        hook.setDiscount(_ids(poolId), desk, 1000, 0, 0, ok);
        vm.expectRevert(FablesFeeEngine.InvalidDiscount.selector);
        hook.setDiscount(_ids(poolId), desk, 1000, 0, 4, ok);
        vm.expectRevert(FablesFeeEngine.InvalidDiscount.selector);
        hook.setDiscount(_ids(poolId), desk, 1000, 0, 3, uint40(block.timestamp));
        vm.expectRevert(FablesFeeEngine.InvalidDiscount.selector);
        hook.setDiscount(_ids(poolId), desk, 1000, 0, 3, uint40(block.timestamp + 90 days + 1));
        vm.expectRevert(FablesHookCore.PoolNotConfigured.selector);
        hook.setDiscount(_ids(_key(120).toId()), desk, 1000, 0, 3, ok);
        hook.setDiscount(_ids(poolId), desk, 5000, 0, 3, uint40(block.timestamp + 90 days));
        hook.setDiscount(_ids(poolId), desk, 1, 0, 1, uint40(block.timestamp + 1));
        vm.stopPrank();
    }

    function test_setDiscount_writesEntryAndBloomAcrossPools() public {
        PoolKey memory k2 = _key(120);
        hook.configurePool(k2, STOCK, 700, 700, 300, 8000);
        PoolId[] memory ids = new PoolId[](2);
        ids[0] = poolId;
        ids[1] = k2.toId();
        uint40 expiry = uint40(block.timestamp + 1 days);
        vm.expectEmit(address(hook));
        emit FablesFeeEngine.DiscountSet(poolId, desk, 2500, 500, 3, expiry);
        vm.expectEmit(address(hook));
        emit FablesFeeEngine.DiscountSet(ids[1], desk, 2500, 500, 3, expiry);
        vm.prank(discountAdmin);
        hook.setDiscount(ids, desk, 2500, 500, 3, expiry);
        for (uint256 i = 0; i < 2; ++i) {
            DiscountLib.Entry memory e = hook.discountOf(ids[i], desk);
            assertEq(e.bps, 2500);
            assertEq(e.minFee, 500);
            assertEq(e.dirs, 3);
            assertEq(e.expiry, expiry);
            (uint8 seed, uint64 bloom) = hook.discountFilter(ids[i]);
            assertTrue(DiscountLib.hit64(bloom, desk, seed), "bloom does not contain the account");
            assertEq(bloom, DiscountLib.mask64(desk, seed), "exactly the account's mask was ORed in");
            (uint256 fee,) =
                FeeRef.resolve(hook.poolWord(ids[i]), true, desk, hook.entryWord(ids[i], desk), 0, 0, block.timestamp);
            assertEq(fee, i == 0 ? 525 : 525);
            (fee,) = FeeRef.resolve(hook.poolWord(ids[i]), true, stranger, 0, 0, 0, block.timestamp);
            assertEq(fee, 700);
        }
    }

    function test_setDiscount_bpsZeroDeletesAndKeepsTheFilter() public {
        uint40 expiry = uint40(block.timestamp + 1 days);
        vm.prank(discountAdmin);
        hook.setDiscount(_ids(poolId), desk, 2500, 0, 3, expiry);
        (, uint64 bloomBefore) = hook.discountFilter(poolId);
        vm.expectEmit(address(hook));
        emit FablesFeeEngine.DiscountSet(poolId, desk, 0, 0, 0, 0);
        vm.prank(discountAdmin);
        hook.setDiscount(_ids(poolId), desk, 0, 123, 7, 0);
        assertEq(hook.entryWord(poolId, desk), 0);
        (, uint64 bloomAfter) = hook.discountFilter(poolId);
        assertEq(bloomAfter, bloomBefore, "a delete does not rebuild the filter (setDiscountFilter does)");
    }

    function test_revokeDiscount_isCartesianAndGuarded() public {
        PoolKey memory k2 = _key(120);
        hook.configurePool(k2, STOCK, 700, 700, 300, 8000);
        PoolId[] memory ids = new PoolId[](2);
        ids[0] = poolId;
        ids[1] = k2.toId();
        address desk2 = makeAddr("desk2");
        address[] memory accounts = new address[](2);
        accounts[0] = desk;
        accounts[1] = desk2;
        uint40 expiry = uint40(block.timestamp + 1 days);
        vm.startPrank(discountAdmin);
        hook.setDiscount(ids, desk, 2500, 0, 3, expiry);
        hook.setDiscount(ids, desk2, 1000, 0, 1, expiry);
        vm.stopPrank();

        PoolId[] memory bad = new PoolId[](1);
        bad[0] = _key(180).toId();
        vm.prank(pauser);
        vm.expectRevert(FablesHookCore.PoolNotConfigured.selector);
        hook.revokeDiscount(bad, accounts);

        vm.expectEmit(address(hook));
        emit FablesFeeEngine.DiscountRevoked(poolId, desk);
        vm.expectEmit(address(hook));
        emit FablesFeeEngine.DiscountRevoked(poolId, desk2);
        vm.expectEmit(address(hook));
        emit FablesFeeEngine.DiscountRevoked(ids[1], desk);
        vm.expectEmit(address(hook));
        emit FablesFeeEngine.DiscountRevoked(ids[1], desk2);
        vm.prank(pauser);
        hook.revokeDiscount(ids, accounts);
        for (uint256 i = 0; i < 2; ++i) {
            assertEq(hook.entryWord(ids[i], desk), 0);
            assertEq(hook.entryWord(ids[i], desk2), 0);
        }
    }

    function test_setDiscountFilter_rebuildsFromHoldersOnly() public {
        address desk2 = makeAddr("desk2");
        uint40 expiry = uint40(block.timestamp + 1 days);
        vm.startPrank(discountAdmin);
        hook.setDiscount(_ids(poolId), desk, 2500, 0, 3, expiry);
        hook.setDiscount(_ids(poolId), desk2, 2500, 0, 3, expiry);
        vm.expectRevert(FablesFeeEngine.InvalidSeed.selector);
        hook.setDiscountFilter(poolId, 128, _accounts(desk));
        vm.expectRevert(FablesHookCore.PoolNotConfigured.selector);
        hook.setDiscountFilter(_key(120).toId(), 1, _accounts(desk));
        address[] memory listed = new address[](2);
        listed[0] = desk;
        listed[1] = stranger;
        vm.expectEmit(address(hook));
        emit FablesFeeEngine.DiscountFilterSet(poolId, 42, DiscountLib.mask64(desk, 42));
        hook.setDiscountFilter(poolId, 42, listed);
        vm.stopPrank();
        (uint8 seed, uint64 bloom) = hook.discountFilter(poolId);
        assertEq(seed, 42);
        assertEq(bloom, DiscountLib.mask64(desk, 42));
        assertTrue(hook.entryWord(poolId, desk2) != 0, "desk2 keeps its entry");
        (uint256 fee,) =
            FeeRef.resolve(hook.poolWord(poolId), true, desk2, hook.entryWord(poolId, desk2), 0, 0, block.timestamp);
        if (!DiscountLib.hit64(bloom, desk2, 42)) assertEq(fee, 700, "a hidden account pays the full fee");
        vm.prank(discountAdmin);
        hook.setDiscountFilter(poolId, 42, new address[](0));
        (, bloom) = hook.discountFilter(poolId);
        assertEq(bloom, 0);
    }

    function test_discountAdminIsNotAvailableInSymmetricMode() public {
        vm.startPrank(discountAdmin);
        vm.expectRevert(FablesFeeEngine.ModuleNotAvailable.selector);
        sym.setDiscount(_ids(symPoolId), desk, 1000, 0, 3, uint40(block.timestamp + 1 days));
        vm.expectRevert(FablesFeeEngine.ModuleNotAvailable.selector);
        sym.setDiscountFilter(symPoolId, 1, _accounts(desk));
        vm.stopPrank();
        vm.prank(pauser);
        vm.expectRevert(FablesFeeEngine.ModuleNotAvailable.selector);
        sym.revokeDiscount(_ids(symPoolId), _accounts(desk));
        assertEq(sym.poolFee(symPoolId).bloom, 0, "symmetric mode: bloom stays 0");
    }

    function test_configureCF_bounds() public {
        vm.expectRevert(FablesHookCore.PoolNotConfigured.selector);
        hook.configureCF(_key(120).toId(), 0, 256, 1000, 80, 60, 15);
        vm.expectRevert(FablesFeeEngine.InvalidCF.selector);
        hook.configureCF(poolId, 2, 256, 1000, 80, 60, 15);
        vm.expectRevert(FablesFeeEngine.InvalidCF.selector);
        hook.configureCF(poolId, 0, 0, 1000, 80, 60, 15);
        vm.expectRevert(FablesFeeEngine.InvalidCF.selector);
        hook.configureCF(poolId, 0, 257, 1000, 80, 60, 15);
        vm.expectRevert(FablesFeeEngine.InvalidCF.selector);
        hook.configureCF(poolId, 0, 256, 0, 80, 60, 15);
        vm.expectRevert(FablesFeeEngine.InvalidCF.selector);
        hook.configureCF(poolId, 0, 256, 2501, 80, 60, 15);
        vm.expectRevert(FablesFeeEngine.InvalidCF.selector);
        hook.configureCF(poolId, 0, 256, 1000, 801, 60, 15);
        vm.expectRevert(FablesFeeEngine.InvalidCF.selector);
        hook.configureCF(poolId, 0, 256, 1000, 80, 4, 15);
        vm.expectRevert(FablesFeeEngine.InvalidCF.selector);
        hook.configureCF(poolId, 0, 256, 1000, 80, 301, 15);
        vm.expectRevert(FablesFeeEngine.InvalidCF.selector);
        hook.configureCF(poolId, 0, 256, 1000, 80, 60, 0);
        vm.expectRevert(FablesFeeEngine.InvalidCF.selector);
        hook.configureCF(poolId, 0, 256, 1000, 80, 60, 61);
        hook.configureCF(poolId, 1, 256, 2500, 800, 300, 60);
        hook.configureCF(poolId, 0, 1, 1, 0, 5, 1);
    }

    function test_configureCF_armsWithoutSwitchingOn() public {
        vm.expectEmit(address(hook));
        emit FablesFeeEngine.CFConfigured(poolId, 1, 200, 1000, 80, 60, 15);
        hook.configureCF(poolId, 1, 200, 1000, 80, 60, 15);
        (FeeRef.CFWord memory c, bool on) = hook.cfOf(poolId);
        assertFalse(on, "configureCF never switches on");
        assertFalse(hook.poolFee(poolId).cfOn);
        assertEq(c.tLast, block.timestamp);
        assertEq(c.anchor, 0, "pool at tick 0");
        assertEq(c.decay1, FeeRef.decay1Q32(60));
        assertEq(c.kQ8, 200);
        assertEq(c.cfCap, 1000);
        assertEq(c.band16, 80);
        assertEq(c.maxAge, 255, "min(255, 5 * 60)");
        assertEq(c.period, 15);
        assertEq(c.tau, 60);
        assertEq(c.mode, 1);
        hook.configureCF(poolId, 0, 200, 1000, 80, 20, 15);
        (c,) = hook.cfOf(poolId);
        assertEq(c.maxAge, 100, "5 * tau under 255");
        assertEq(hook.cfWord(poolId), FeeRef.packCF(c), "raw word == packed decoded word");
    }

    function test_setCFActive_requiresConfigAndInitialization() public {
        vm.prank(poker);
        vm.expectRevert(FablesFeeEngine.CFNotConfigured.selector);
        hook.setCFActive(poolId, true, TickMath.MIN_TICK, TickMath.MAX_TICK, type(uint256).max);
        vm.prank(poker);
        hook.setCFActive(poolId, false, 0, 0, 0);

        PoolKey memory k = _key(120);
        hook.configurePool(k, STOCK, 700, 700, 300, 8000);
        hook.configureCF(k.toId(), 0, 256, 1000, 80, 60, 15);
        vm.prank(poker);
        vm.expectRevert(FablesFeeEngine.PoolNotInitialized.selector);
        hook.setCFActive(k.toId(), true, TickMath.MIN_TICK, TickMath.MAX_TICK, type(uint256).max);
        hook.initializePool(k, SQRT_PRICE_1_1);
        vm.prank(poker);
        hook.setCFActive(k.toId(), true, TickMath.MIN_TICK, TickMath.MAX_TICK, type(uint256).max);
        assertTrue(hook.poolFee(k.toId()).cfOn);
    }

    function test_setCFActive_rearmsTheAnchorOnSwitchOn() public {
        hook.configureCF(poolId, 0, 256, 1000, 80, 60, 15);
        FeeRef.CFWord memory c = FeeRef.unpackCF(hook.cfWord(poolId));
        c.anchor = 50_000;
        c.tLast = uint40(block.timestamp - 1 hours);
        hook.__setCF(poolId, FeeRef.packCF(c));
        vm.warp(block.timestamp + 100);
        vm.expectEmit(address(hook));
        emit FablesFeeEngine.CFActiveSet(poolId, true);
        vm.prank(poker);
        hook.setCFActive(poolId, true, TickMath.MIN_TICK, TickMath.MAX_TICK, type(uint256).max);
        (FeeRef.CFWord memory d, bool on) = hook.cfOf(poolId);
        assertTrue(on);
        assertEq(d.tLast, block.timestamp);
        assertEq(d.anchor, 0, "anchor == current tick * 256");
        assertEq(d.kQ8, 256, "parameters untouched");
        (uint256 s,) = FeeRef.cfStep(hook.cfWord(poolId), 0, true, block.timestamp);
        assertEq(s, 0);
        vm.expectEmit(address(hook));
        emit FablesFeeEngine.CFActiveSet(poolId, false);
        vm.prank(poker);
        hook.setCFActive(poolId, false, 0, 0, 0);
        assertFalse(hook.poolFee(poolId).cfOn);
    }

    function test_killCF_zeroesTheSlopeUntilAdminReconfigures() public {
        hook.configureCF(poolId, 0, 256, 1000, 80, 60, 15);
        vm.prank(poker);
        hook.setCFActive(poolId, true, TickMath.MIN_TICK, TickMath.MAX_TICK, type(uint256).max);
        vm.expectEmit(address(hook));
        emit FablesFeeEngine.CFKilled(poolId);
        vm.prank(pauser);
        hook.killCF(poolId);
        (FeeRef.CFWord memory c, bool on) = hook.cfOf(poolId);
        assertFalse(on);
        assertEq(c.kQ8, 0);
        assertEq(c.cfCap, 1000, "only the slope is zeroed");
        vm.prank(poker);
        vm.expectRevert(FablesFeeEngine.CFNotConfigured.selector);
        hook.setCFActive(poolId, true, TickMath.MIN_TICK, TickMath.MAX_TICK, type(uint256).max);
        hook.configureCF(poolId, 0, 128, 1000, 80, 60, 15);
        vm.prank(poker);
        hook.setCFActive(poolId, true, TickMath.MIN_TICK, TickMath.MAX_TICK, type(uint256).max);
        assertTrue(hook.poolFee(poolId).cfOn);
        vm.prank(pauser);
        vm.expectRevert(FablesHookCore.PoolNotConfigured.selector);
        hook.killCF(_key(120).toId());
    }

    function test_cfAdminIsNotAvailableInSymmetricMode() public {
        vm.expectRevert(FablesFeeEngine.ModuleNotAvailable.selector);
        sym.configureCF(symPoolId, 0, 256, 1000, 80, 60, 15);
        vm.prank(poker);
        vm.expectRevert(FablesFeeEngine.ModuleNotAvailable.selector);
        sym.setCFActive(symPoolId, true, TickMath.MIN_TICK, TickMath.MAX_TICK, type(uint256).max);
        vm.prank(pauser);
        vm.expectRevert(FablesFeeEngine.ModuleNotAvailable.selector);
        sym.killCF(symPoolId);
        assertFalse(sym.poolFee(symPoolId).cfOn, "symmetric mode: cfOn stays 0");
    }

    function test_views() public {
        (uint24 premium, bool zeroForOne) = hook.poolAsymmetry(poolId);
        assertEq(premium, 200);
        assertFalse(zeroForOne, "base1 (900) > base0 (700): oneForZero is the dearer side");
        hook.configurePool(key, STOCK, 900, 700, 300, 8000);
        (premium, zeroForOne) = hook.poolAsymmetry(poolId);
        assertEq(premium, 200);
        assertTrue(zeroForOne);
        hook.configurePool(key, STOCK, 700, 700, 300, 8000);
        (premium,) = hook.poolAsymmetry(poolId);
        assertEq(premium, 0);
        assertEq(hook.pokeFloor(poolId), 300);
        assertEq(hook.autonomousFee(poolId, true), 700);
        assertEq(hook.lastRaiseAt(poolId), 0);
        assertEq(hook.poolWord(poolId), PoolWordLib.pack(hook.poolFee(poolId)));
        DiscountLib.Entry memory e = hook.discountOf(poolId, desk);
        assertEq(e.bps, 0);
        (uint8 seed, uint64 bloom) = hook.discountFilter(poolId);
        assertEq(seed, 0);
        assertEq(bloom, 0);
        assertEq(hook.cfWord(poolId), 0);
        assertEq(hook.categoryOf(_key(120).toId()), 0, "unconfigured pool reads category 0");
    }

    function test_everyRestrictedFunctionIsGated() public {
        vm.startPrank(stranger);
        vm.expectRevert(_unauthorized(stranger));
        hook.setCategory(5, 0, 1000, 1, "x");
        vm.expectRevert(_unauthorized(stranger));
        hook.configurePool(key, STOCK, 700, 700, 300, 8000);
        vm.expectRevert(_unauthorized(stranger));
        hook.pokeFee(poolId, 1000, 1000, 1 hours);
        vm.expectRevert(_unauthorized(stranger));
        hook.clearPoke(poolId);
        vm.expectRevert(_unauthorized(stranger));
        hook.setDiscount(_ids(poolId), desk, 1000, 0, 3, uint40(block.timestamp + 1 days));
        vm.expectRevert(_unauthorized(stranger));
        hook.revokeDiscount(_ids(poolId), _accounts(desk));
        vm.expectRevert(_unauthorized(stranger));
        hook.setDiscountFilter(poolId, 1, _accounts(desk));
        vm.expectRevert(_unauthorized(stranger));
        hook.configureCF(poolId, 0, 256, 1000, 80, 60, 15);
        vm.expectRevert(_unauthorized(stranger));
        hook.setCFActive(poolId, true, TickMath.MIN_TICK, TickMath.MAX_TICK, type(uint256).max);
        vm.expectRevert(_unauthorized(stranger));
        hook.killCF(poolId);
        vm.expectRevert(_unauthorized(stranger));
        hook.initializePool(_key(120), SQRT_PRICE_1_1);
        vm.stopPrank();
        vm.prank(poker);
        vm.expectRevert(_unauthorized(poker));
        hook.clearPoke(poolId);
        vm.prank(pauser);
        vm.expectRevert(_unauthorized(pauser));
        hook.pokeFee(poolId, 1000, 1000, 1 hours);
        vm.prank(poker);
        vm.expectRevert(_unauthorized(poker));
        hook.configureCF(poolId, 0, 256, 1000, 80, 60, 15);
    }

    function _anyConfiguredWord(uint256 raw, uint24 floor_, uint24 cap, uint24 base0, uint24 base1)
        internal
        returns (PoolId id)
    {
        PoolKey memory k = _key(240);
        id = k.toId();
        cap = uint24(bound(cap, 1, 100_000));
        floor_ = uint24(bound(floor_, 0, cap));
        base0 = uint24(bound(base0, floor_, cap));
        base1 = uint24(bound(base1, floor_, cap));
        hook.configurePool(k, FREE, base0, base1, floor_, cap);
        hook.__setWord(id, raw.withBases(base0, base1).withBounds(floor_, cap));
    }

    function testFuzz_configurePoolTouchesOnlyBasesAndBounds(
        uint256 raw,
        uint24 f,
        uint24 c,
        uint24 b0,
        uint24 b1,
        uint24 nf,
        uint24 nc
    ) public {
        PoolId id = _anyConfiguredWord(raw, f, c, b0, b1);
        uint256 before = hook.poolWord(id);
        nc = uint24(bound(nc, 1, 100_000));
        nf = uint24(bound(nf, 0, nc));
        hook.configurePool(_key(240), FREE, nf, nc, nf, nc);
        uint256 after_ = hook.poolWord(id);
        uint256 mask = PoolWordLib.BASES_MASK | PoolWordLib.BOUNDS_MASK;
        assertEq(after_ & ~mask, before & ~mask);
        assertEq(after_.base0(), nf);
        assertEq(after_.cap(), nc);
    }

    function testFuzz_pokeFeeTouchesOnlyPokes(
        uint256 raw,
        uint24 f,
        uint24 c,
        uint24 b0,
        uint24 b1,
        uint24 p0,
        uint24 p1,
        uint40 ttl
    ) public {
        PoolId id = _anyConfiguredWord(raw, f, c, b0, b1);
        uint256 before = hook.poolWord(id);
        p0 = uint24(bound(p0, before.floor() == 0 ? 1 : before.floor(), before.cap()));
        p1 = uint24(bound(p1, before.floor() == 0 ? 1 : before.floor(), before.cap()));
        ttl = uint40(bound(ttl, 1, 72 hours));
        vm.prank(poker);
        hook.pokeFee(id, p0, p1, ttl);
        uint256 after_ = hook.poolWord(id);
        assertEq(after_ & ~PoolWordLib.POKES_MASK, before & ~PoolWordLib.POKES_MASK);
        assertEq(after_.poke0(), p0);
        assertEq(after_.poke1(), p1);
        assertEq(after_.expiry(), block.timestamp + ttl);
    }

    function testFuzz_clearPokeTouchesOnlyPokes(uint256 raw, uint24 f, uint24 c, uint24 b0, uint24 b1) public {
        PoolId id = _anyConfiguredWord(raw, f, c, b0, b1);
        uint256 before = hook.poolWord(id);
        vm.prank(pauser);
        hook.clearPoke(id);
        uint256 after_ = hook.poolWord(id);
        assertEq(after_ & ~PoolWordLib.POKES_MASK, before & ~PoolWordLib.POKES_MASK);
        assertEq(after_ & PoolWordLib.POKES_MASK, 0);
    }

    function testFuzz_setDiscountTouchesOnlyBloom(
        uint256 raw,
        uint24 f,
        uint24 c,
        uint24 b0,
        uint24 b1,
        address account
    ) public {
        vm.assume(account != address(0));
        PoolId id = _anyConfiguredWord(raw, f, c, b0, b1);
        uint256 before = hook.poolWord(id);
        vm.prank(discountAdmin);
        hook.setDiscount(_ids(id), account, 1000, 0, 3, uint40(block.timestamp + 1 days));
        uint256 after_ = hook.poolWord(id);
        assertEq(after_ & ~PoolWordLib.BLOOM_MASK, before & ~PoolWordLib.BLOOM_MASK);
        assertEq(after_.bloom(), before.bloom() | DiscountLib.mask64(account, before.seed()));
    }

    function testFuzz_setDiscountFilterTouchesOnlyBloomAndSeed(
        uint256 raw,
        uint24 f,
        uint24 c,
        uint24 b0,
        uint24 b1,
        uint8 seed
    ) public {
        seed &= 0x7f;
        PoolId id = _anyConfiguredWord(raw, f, c, b0, b1);
        uint256 before = hook.poolWord(id);
        vm.prank(discountAdmin);
        hook.setDiscountFilter(id, seed, new address[](0));
        uint256 after_ = hook.poolWord(id);
        uint256 mask = PoolWordLib.BLOOM_MASK | PoolWordLib.SEED_MASK;
        assertEq(after_ & ~mask, before & ~mask);
        assertEq(after_.bloom(), 0);
        assertEq(after_.seed(), seed);
    }

    function testFuzz_cfSwitchesTouchOnlyCfOn(uint256 raw, uint24 f, uint24 c, uint24 b0, uint24 b1, bool on) public {
        PoolId id = _anyConfiguredWord(raw, f, c, b0, b1);
        hook.initializePool(_key(240), SQRT_PRICE_1_1);
        uint256 w = hook.poolWord(id);
        if (w.cfOn()) {
            vm.expectRevert(FablesFeeEngine.CFActive.selector);
            hook.configureCF(id, 0, 256, 1000, 80, 60, 15);
            assertEq(hook.poolWord(id), w);
            hook.__setWord(id, w & ~PoolWordLib.CF_ON_MASK);
        }
        hook.configureCF(id, 0, 256, 1000, 80, 60, 15);
        uint256 before = hook.poolWord(id);
        vm.prank(poker);
        hook.setCFActive(id, on, TickMath.MIN_TICK, TickMath.MAX_TICK, type(uint256).max);
        uint256 after_ = hook.poolWord(id);
        assertEq(after_ & ~PoolWordLib.CF_ON_MASK, before & ~PoolWordLib.CF_ON_MASK);
        assertEq(after_.cfOn(), on);
        vm.prank(pauser);
        hook.killCF(id);
        uint256 killed = hook.poolWord(id);
        assertEq(killed & ~PoolWordLib.CF_ON_MASK, before & ~PoolWordLib.CF_ON_MASK);
        assertFalse(killed.cfOn());
    }
}
