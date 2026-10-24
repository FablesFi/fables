// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";

import {FablesLedgerV2} from "../../../src/base/FablesLedgerV2.sol";
import {FablesHookCore} from "../../../src/base/FablesHookCore.sol";
import {FablesExclusiveLiquidityV2} from "../../../src/base/FablesExclusiveLiquidityV2.sol";
import {BuildsFixture} from "../../utils/BuildsFixture.sol";

/// @notice Exclusive builds refuse external liquidity and serve the ledger; open builds accept it.
contract BuildsExclusiveTest is BuildsFixture {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint128 constant DEPOSIT_LIQ = 1e18;

    function setUp() public {
        _setUpStack();
    }

    function _expectGateRevert(address hook) internal {
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                hook,
                IHooks.beforeAddLiquidity.selector,
                abi.encodeWithSelector(FablesExclusiveLiquidityV2.LiquidityOnlyViaLedger.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
    }

    function test_exclusiveBuildsRefuseExternalLiquidityAndServeTheLedger() public {
        Build[4] memory t = _builds();
        uint256 covered;
        for (uint256 i = 0; i < t.length; i++) {
            if (!t[i].exclusive) continue;
            address at = _deploy(t[i], uint160(0xEC00 + i));
            FablesLedgerV2 hook = FablesLedgerV2(payable(at));
            PoolKey memory k = _erc20Key(at, 60);
            _configureFlat(at, k, 3000);
            _initPool(k, SQRT_PRICE_1_1);
            PoolId id = k.toId();

            _expectGateRevert(at);
            modifyLiquidityRouter.modifyLiquidity(k, LIQUIDITY_PARAMS, ZERO_BYTES);

            hook.deposit(k, -120, 120, DEPOSIT_LIQ, type(uint128).max, type(uint128).max, block.timestamp);
            assertEq(manager.getLiquidity(id), DEPOSIT_LIQ, string.concat(t[i].name, ": not all ledger liquidity"));
            swap(k, true, -1e15, ZERO_BYTES);
            hook.withdraw(k, -120, 120, DEPOSIT_LIQ, address(this), 0, 0, block.timestamp);
            assertEq(manager.getLiquidity(id), 0, t[i].name);
            covered++;
        }
        assertEq(covered, 2, "two Exclusive builds");
    }

    function test_openBuildsAcceptExternalLiquidity() public {
        Build[4] memory t = _builds();
        uint256 covered;
        for (uint256 i = 0; i < t.length; i++) {
            if (t[i].exclusive) continue;
            address at = _deploy(t[i], uint160(0xED00 + i));
            PoolKey memory k = _erc20Key(at, 60);
            _configureFlat(at, k, 3000);
            _initPool(k, SQRT_PRICE_1_1);
            modifyLiquidityRouter.modifyLiquidity(k, LIQUIDITY_PARAMS, ZERO_BYTES);
            assertEq(manager.getLiquidity(k.toId()), uint128(uint256(LIQUIDITY_PARAMS.liquidityDelta)), t[i].name);
            covered++;
        }
        assertEq(covered, 2, "two open builds");
    }

    function test_exclusiveGateDirectCalls() public {
        Build[4] memory t = _builds();
        IPoolManager.ModifyLiquidityParams memory params;
        address stranger = makeAddr("stranger");
        for (uint256 i = 0; i < t.length; i++) {
            if (!t[i].exclusive) continue;
            address at = _deploy(t[i], uint160(0xEE00 + i));
            FablesExclusiveLiquidityV2 gate = FablesExclusiveLiquidityV2(at);
            PoolKey memory k = _erc20Key(at, 60);

            vm.prank(stranger);
            vm.expectRevert(FablesHookCore.NotPoolManager.selector);
            gate.beforeAddLiquidity(stranger, k, params, "");

            vm.prank(address(manager));
            vm.expectRevert(FablesExclusiveLiquidityV2.LiquidityOnlyViaLedger.selector);
            gate.beforeAddLiquidity(stranger, k, params, "");

            vm.prank(address(manager));
            assertEq(gate.beforeAddLiquidity(at, k, params, ""), IHooks.beforeAddLiquidity.selector, t[i].name);
        }
    }
}
