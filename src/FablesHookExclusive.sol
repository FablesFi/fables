// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {FablesHook} from "./FablesHook.sol";
import {FablesExclusiveLiquidityV2} from "./base/FablesExclusiveLiquidityV2.sol";

/// @title FablesHookExclusive
/// @notice FablesHook where liquidity enters only through the ledger. Flags 0x2880.
contract FablesHookExclusive is FablesHook, FablesExclusiveLiquidityV2 {
    constructor(IPoolManager poolManager_, address authority_) FablesHook(poolManager_, authority_) {}

    function _hookPermissions() internal pure virtual override returns (Hooks.Permissions memory permissions) {
        permissions = super._hookPermissions();
        permissions.beforeAddLiquidity = true;
    }
}
