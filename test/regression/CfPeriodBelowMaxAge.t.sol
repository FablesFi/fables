// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {FablesHook} from "../../src/FablesHook.sol";
import {FablesFeeEngine} from "../../src/base/FablesFeeEngine.sol";
import {FeeRef} from "../../src/libraries/FeeRef.sol";

/// @notice `configureCF` requires period < maxAge (otherwise every anchor write is a full snap).
contract CfPeriodBelowMaxAgeTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;

    FablesHook hook;
    PoolId id;

    function setUp() public {
        deployFreshManagerAndRouters();
        AccessManager authority = new AccessManager(address(this));
        address at = address(uint160(0x2323 << 144) | uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG));
        deployCodeTo("FablesHook.sol:FablesHook", abi.encode(manager, address(authority)), at);
        hook = FablesHook(payable(at));
        PoolKey memory k = PoolKey(
            Currency.wrap(address(0x1111)),
            Currency.wrap(address(0x2222)),
            LPFeeLibrary.DYNAMIC_FEE_FLAG,
            60,
            IHooks(at)
        );
        id = k.toId();
        hook.setCategory(1, 0, 100_000, 1_000, "c");
        hook.configurePool(k, 1, 3_000, 3_000, 0, 10_000);
    }

    function test_periodAtOrAboveMaxAgeReverts() public {
        vm.expectRevert(FablesFeeEngine.InvalidCF.selector);
        hook.configureCF(id, 0, 256, 1_000, 0, 5, 60);
        vm.expectRevert(FablesFeeEngine.InvalidCF.selector);
        hook.configureCF(id, 0, 256, 1_000, 0, 5, 25);
        vm.expectRevert(FablesFeeEngine.InvalidCF.selector);
        hook.configureCF(id, 0, 256, 1_000, 0, 12, 60);
    }

    function test_periodBelowMaxAgeAccepted() public {
        hook.configureCF(id, 0, 256, 1_000, 0, 5, 24);
        hook.configureCF(id, 0, 256, 1_000, 0, 13, 60);
        FeeRef.CFWord memory c = FeeRef.unpackCF(hook.cfWord(id));
        assertEq(c.maxAge, 65);
        assertEq(c.period, 60);
    }

    function testFuzz_landsIffPeriodBelowMaxAge(uint16 tau, uint8 period) public {
        tau = uint16(bound(tau, 5, 300));
        period = uint8(bound(period, 1, 60));
        uint256 maxAge = 5 * uint256(tau) > 255 ? 255 : 5 * uint256(tau);
        if (period >= maxAge) vm.expectRevert(FablesFeeEngine.InvalidCF.selector);
        hook.configureCF(id, 0, 256, 1_000, 0, tau, period);
        if (period < maxAge) {
            assertLt(FeeRef.unpackCF(hook.cfWord(id)).period, FeeRef.unpackCF(hook.cfWord(id)).maxAge);
        }
    }
}
