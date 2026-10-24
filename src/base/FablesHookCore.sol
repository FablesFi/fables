// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {AccessManaged} from "@openzeppelin/contracts/access/manager/AccessManaged.sol";

/// @title FablesHookCore
/// @notice Shared root of the hooks: PoolManager handle, per-pool configured marker and native-currency gate.
/// @dev `maxFee[id] != 0` marks a configured pool and is never reset to 0.
abstract contract FablesHookCore is AccessManaged {
    error NotPoolManager();
    error PoolNotConfigured();
    error NativeNotSupported();

    IPoolManager public immutable poolManager;

    /// @notice Per-pool fee cap in pips; 0 = not configured.
    mapping(PoolId poolId => uint24 cap) public maxFee;

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    constructor(IPoolManager poolManager_, address authority_) AccessManaged(authority_) {
        poolManager = poolManager_;
    }

    function _nativeAllowed() internal pure virtual returns (bool) {
        return false;
    }
}
