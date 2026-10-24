// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {FablesHookETH, IWETH9} from "./FablesHookETH.sol";
import {FablesHookCore} from "./base/FablesHookCore.sol";
import {FablesExclusiveLiquidityV2} from "./base/FablesExclusiveLiquidityV2.sol";

/// @title FablesHookETHExclusive
/// @notice FablesHookETH where liquidity enters only through the ledger. Flags 0x2880.
contract FablesHookETHExclusive is FablesHookETH, FablesExclusiveLiquidityV2 {
    constructor(IPoolManager poolManager_, address authority_, IWETH9 weth_)
        FablesHookETH(poolManager_, authority_, weth_)
    {}

    function _hookPermissions() internal pure override returns (Hooks.Permissions memory permissions) {
        permissions = super._hookPermissions();
        permissions.beforeAddLiquidity = true;
    }

    function _nativeAllowed() internal pure override(FablesHookCore, FablesHookETH) returns (bool) {
        return FablesHookETH._nativeAllowed();
    }
}
