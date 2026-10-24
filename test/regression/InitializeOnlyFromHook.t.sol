// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {Pool} from "v4-core/src/libraries/Pool.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {IAccessManaged} from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import {FablesHookCore} from "../../src/base/FablesHookCore.sol";
import {FablesFeeEngine} from "../../src/base/FablesFeeEngine.sol";
import {FablesLedgerV2} from "../../src/base/FablesLedgerV2.sol";
import {BuildsFixture} from "../utils/BuildsFixture.sol";

/// @notice Pools are created only through the restricted `initializePool`; beforeInitialize admits only the hook.
contract InitializeOnlyFromHookTest is BuildsFixture {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint64 constant SEEDER = 15;
    address attacker = makeAddr("attacker");
    address seeder = makeAddr("seeder");

    function setUp() public {
        _setUpStack();
    }

    function _outsideInitRevert(address hook, address caller) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            hook,
            IHooks.beforeInitialize.selector,
            abi.encodeWithSelector(FablesFeeEngine.InvalidInitializer.selector, caller),
            abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        );
    }

    function test_outsideInitializerRefusedOnEveryBuild() public {
        Build[4] memory t = _builds();
        for (uint256 i = 0; i < t.length; i++) {
            address at = _deploy(t[i], uint160(0xF150 + i));
            PoolKey memory k = _erc20Key(at, 60);
            _configureFlat(at, k, 3000);
            vm.prank(attacker);
            vm.expectRevert(_outsideInitRevert(at, attacker));
            manager.initialize(k, SQRT_PRICE_2_1);
            vm.expectRevert(_outsideInitRevert(at, address(this)));
            manager.initialize(k, SQRT_PRICE_1_1);
            (uint160 sp,,,) = manager.getSlot0(k.toId());
            assertEq(sp, 0, string.concat(t[i].name, " initialized from outside"));
        }
    }

    function test_initializePoolBoundToARoleOnEveryBuild() public {
        assertEq(
            FablesFeeEngine.initializePool.selector,
            bytes4(keccak256("initializePool((address,address,uint24,int24,address),uint160)"))
        );
        Build[4] memory t = _builds();
        for (uint256 i = 0; i < t.length; i++) {
            address at = _deploy(t[i], uint160(0xF160 + i));
            bytes4[] memory s = new bytes4[](1);
            s[0] = FablesFeeEngine.initializePool.selector;
            authority.setTargetFunctionRole(at, s, SEEDER);
            authority.grantRole(SEEDER, seeder, 0);
            PoolKey memory k = _erc20Key(at, 60);
            _configureFlat(at, k, 3000);
            PoolId id = k.toId();

            vm.prank(attacker);
            vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, attacker));
            FablesFeeEngine(at).initializePool(k, SQRT_PRICE_1_1);

            vm.prank(seeder);
            FablesFeeEngine(at).initializePool(k, SQRT_PRICE_1_1);
            (uint160 sp,,, uint24 lpFee) = manager.getSlot0(id);
            assertEq(sp, SQRT_PRICE_1_1, t[i].name);
            assertEq(lpFee, 0, string.concat(t[i].name, " slot0 fee"));

            vm.prank(seeder);
            vm.expectRevert(Pool.PoolAlreadyInitialized.selector);
            FablesFeeEngine(at).initializePool(k, SQRT_PRICE_2_1);

            FablesLedgerV2(payable(at))
                .deposit(k, -120, 120, 1e18, type(uint128).max, type(uint128).max, block.timestamp);
            vm.recordLogs();
            swap(k, true, -1e15, ZERO_BYTES);
            assertEq(_lastSwapFee(), 3000, string.concat(t[i].name, " fee zeroForOne"));
            vm.recordLogs();
            swap(k, false, -1e15, ZERO_BYTES);
            assertEq(_lastSwapFee(), 3000, string.concat(t[i].name, " fee oneForZero"));
        }
    }

    function test_initializePoolGates() public {
        Build[4] memory t = _builds();
        for (uint256 i = 0; i < t.length; i++) {
            address at = _deploy(t[i], uint160(0xF170 + i));
            vm.expectRevert(FablesHookCore.PoolNotConfigured.selector);
            FablesFeeEngine(at).initializePool(_erc20Key(at, 60), SQRT_PRICE_1_1);

            PoolKey memory native =
                PoolKey(CurrencyLibrary.ADDRESS_ZERO, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(at));
            _configureFlat(at, native, 3000);
            if (!t[i].eth) vm.expectRevert(FablesHookCore.NativeNotSupported.selector);
            FablesFeeEngine(at).initializePool(native, SQRT_PRICE_1_1);
            (uint160 sp,,,) = manager.getSlot0(native.toId());
            assertEq(sp, t[i].eth ? SQRT_PRICE_1_1 : 0, t[i].name);
        }
    }

    function test_beforeInitializeAdmitsOnlyTheHook() public {
        address at = _deploy(_builds()[0], 0xF180);
        PoolKey memory k = _erc20Key(at, 60);
        vm.expectRevert(FablesHookCore.NotPoolManager.selector);
        FablesFeeEngine(at).beforeInitialize(at, k, SQRT_PRICE_1_1);
        vm.prank(address(manager));
        vm.expectRevert(abi.encodeWithSelector(FablesFeeEngine.InvalidInitializer.selector, attacker));
        FablesFeeEngine(at).beforeInitialize(attacker, k, SQRT_PRICE_1_1);
        vm.prank(address(manager));
        assertEq(FablesFeeEngine(at).beforeInitialize(at, k, SQRT_PRICE_1_1), IHooks.beforeInitialize.selector);
    }
}
