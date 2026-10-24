// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {IAccessManaged} from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";

import {FablesHookCore} from "../../../src/base/FablesHookCore.sol";
import {FablesLedgerV2} from "../../../src/base/FablesLedgerV2.sol";
import {FablesExclusiveLiquidityV2} from "../../../src/base/FablesExclusiveLiquidityV2.sol";
import {IWETH9} from "../../../src/base/FablesNativeETHV2.sol";
import {TestHookV2, TestHookV2Exclusive, TestHookV2ETH} from "../../utils/TestHookV2.sol";
import {MockWETH9} from "../../utils/mocks/MockWETH9.sol";

/// @notice FablesHookCore + the ledger and its mixins instantiate against a real PoolManager; core gates and markers
///         behave as the ledger expects.
contract CoreCompileTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;

    AccessManager authority;
    TestHookV2 hook;
    TestHookV2Exclusive exclusive;
    TestHookV2ETH ethHook;

    address stranger = makeAddr("stranger");

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();
        authority = new AccessManager(address(this));
        hook = new TestHookV2(manager, address(authority));
        exclusive = new TestHookV2Exclusive(manager, address(authority));
        ethHook = new TestHookV2ETH(manager, address(authority), IWETH9(address(new MockWETH9())));
    }

    function _key(address hooks, Currency c0) internal view returns (PoolKey memory) {
        return PoolKey(c0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(hooks));
    }

    function test_coreWiring() public view {
        assertEq(address(hook.poolManager()), address(manager), "poolManager");
        assertEq(hook.authority(), address(authority), "authority");
        assertEq(hook.maxFee(PoolId.wrap(bytes32(0))), 0, "unconfigured by default");
        assertEq(address(exclusive.poolManager()), address(manager));
        assertEq(address(ethHook.poolManager()), address(manager));
        assertEq(hook.MAX_CLAIM_FEE_BPS(), 2000);
        assertEq(hook.MAX_CLAIM_FEE_WALK(), 32);
    }

    function test_configureMarksPool() public {
        PoolKey memory key = _key(address(hook), currency0);
        hook.configure(key.toId(), 3000);
        assertEq(hook.maxFee(key.toId()), 3000);
    }

    function test_unlockCallback_rejectsNonPoolManager() public {
        vm.prank(stranger);
        vm.expectRevert(FablesHookCore.NotPoolManager.selector);
        hook.unlockCallback("");
    }

    function test_exclusive_beforeAddLiquidity_gates() public {
        PoolKey memory key = _key(address(exclusive), currency0);
        IPoolManager.ModifyLiquidityParams memory params;

        vm.prank(stranger);
        vm.expectRevert(FablesHookCore.NotPoolManager.selector);
        exclusive.beforeAddLiquidity(stranger, key, params, "");

        vm.prank(address(manager));
        vm.expectRevert(FablesExclusiveLiquidityV2.LiquidityOnlyViaLedger.selector);
        exclusive.beforeAddLiquidity(stranger, key, params, "");

        vm.prank(address(manager));
        bytes4 sel = exclusive.beforeAddLiquidity(address(exclusive), key, params, "");
        assertEq(sel, IHooks.beforeAddLiquidity.selector);
    }

    function test_deposit_unconfiguredPoolReverts() public {
        PoolKey memory key = _key(address(hook), currency0);
        vm.expectRevert(FablesHookCore.PoolNotConfigured.selector);
        hook.deposit(key, -60, 60, 1, type(uint128).max, type(uint128).max, block.timestamp);
    }

    function test_deposit_foreignHookReverts() public {
        PoolKey memory key = _key(address(exclusive), currency0);
        hook.configure(key.toId(), 3000);
        vm.expectRevert(FablesHookCore.PoolNotConfigured.selector);
        hook.deposit(key, -60, 60, 1, type(uint128).max, type(uint128).max, block.timestamp);
    }

    function test_deposit_nativeRefusedOnErc20OnlyHook() public {
        PoolKey memory key = _key(address(hook), CurrencyLibrary.ADDRESS_ZERO);
        hook.configure(key.toId(), 3000);
        vm.expectRevert(FablesHookCore.NativeNotSupported.selector);
        hook.deposit(key, -60, 60, 1, 1, 1, block.timestamp);
    }

    function test_deposit_nativePassesGateOnEthHook() public {
        PoolKey memory key = _key(address(ethHook), CurrencyLibrary.ADDRESS_ZERO);
        ethHook.configure(key.toId(), 3000);
        vm.expectRevert(FablesLedgerV2.InvalidMsgValue.selector);
        ethHook.deposit(key, -60, 60, 1, 1, 1, block.timestamp);
    }

    function test_restrictedSettersGoThroughTheAuthority() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger));
        hook.pause(1 hours);

        hook.pause(1 hours);
        assertTrue(hook.paused());
    }
}
