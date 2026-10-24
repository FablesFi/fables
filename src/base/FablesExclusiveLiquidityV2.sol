// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {FablesHookCore} from "./FablesHookCore.sol";

/// @title FablesExclusiveLiquidityV2
/// @notice Makes the ledger the only way to add liquidity; removes and donates stay open.
/// @dev The ledger's own adds skip this callback (v4 `noSelfCall`); the sender check is defense in depth.
abstract contract FablesExclusiveLiquidityV2 is FablesHookCore {
    error LiquidityOnlyViaLedger();

    function beforeAddLiquidity(
        address sender,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external view onlyPoolManager returns (bytes4) {
        if (sender != address(this)) revert LiquidityOnlyViaLedger();
        return IHooks.beforeAddLiquidity.selector;
    }
}
