// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";

import {FablesFeeEngine} from "../../../src/base/FablesFeeEngine.sol";
import {FablesHookCore} from "../../../src/base/FablesHookCore.sol";
import {FablesLedgerV2} from "../../../src/base/FablesLedgerV2.sol";
import {FablesNativeETHV2} from "../../../src/base/FablesNativeETHV2.sol";
import {MockWETH9} from "../../utils/mocks/MockWETH9.sol";

/// @notice WETH-shaped token whose supply exceeds its ETH balance.
contract InflatedWETH {
    function balanceOf(address) external pure returns (uint256) {
        return 0;
    }

    function totalSupply() external pure returns (uint256) {
        return 1;
    }
}

/// @notice Module admin on unconfigured pools and the native mixin's constructor refusals.
contract EngineEdgesTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;

    AccessManager internal am;
    FablesFeeEngine internal hook;

    function setUp() public {
        deployFreshManagerAndRouters();
        am = new AccessManager(address(this));
        address at = address(uint160(0x5EED << 144) | uint160(0x2080));
        deployCodeTo("FablesHook.sol:FablesHook", abi.encode(manager, address(am)), at);
        hook = FablesFeeEngine(at);
    }

    function test_moduleAdmin_unconfiguredPool() public {
        PoolId ghost = PoolId.wrap(bytes32(uint256(42)));
        vm.expectRevert(FablesHookCore.PoolNotConfigured.selector);
        hook.killCF(ghost);
        vm.expectRevert(FablesHookCore.PoolNotConfigured.selector);
        hook.setCFActive(ghost, false, 0, 0, 0);
        vm.expectRevert(FablesHookCore.PoolNotConfigured.selector);
        hook.configureCF(ghost, 0, 1, 1, 0, 5, 1);
        vm.expectRevert(FablesHookCore.PoolNotConfigured.selector);
        hook.setDiscountFilter(ghost, 0, new address[](0));
        vm.expectRevert(FablesHookCore.PoolNotConfigured.selector);
        hook.clearPoke(ghost);
        PoolId[] memory ids = new PoolId[](1);
        ids[0] = ghost;
        vm.expectRevert(FablesHookCore.PoolNotConfigured.selector);
        hook.revokeDiscount(ids, new address[](0));
        vm.expectRevert(FablesHookCore.PoolNotConfigured.selector);
        hook.setDiscount(ids, address(1), 0, 0, 0, 0);
    }

    function test_nativeConstructor_refusals() public {
        address at = address(uint160(0x5EEE << 144) | uint160(0x2080));
        bytes memory code = vm.getCode("FablesHookETH.sol:FablesHookETH");
        vm.etch(at, abi.encodePacked(code, abi.encode(manager, address(am), makeAddr("codeless weth"))));
        (bool ok, bytes memory ret) = at.call("");
        assertFalse(ok);
        assertEq(bytes4(ret), FablesLedgerV2.ZeroAddress.selector);
        InflatedWETH bad = new InflatedWETH();
        vm.etch(at, abi.encodePacked(code, abi.encode(manager, address(am), address(bad))));
        (ok, ret) = at.call("");
        assertFalse(ok);
        assertEq(bytes4(ret), FablesNativeETHV2.NotWrappedEther.selector);
        vm.etch(at, abi.encodePacked(code, abi.encode(manager, address(am), address(new MockWETH9()))));
        (ok,) = at.call("");
        assertTrue(ok);
    }
}
