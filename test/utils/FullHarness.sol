// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {FablesFeeFull} from "../../src/base/FablesFeeFull.sol";
import {FablesLedgerV2} from "../../src/base/FablesLedgerV2.sol";

/// @notice FablesFeeFull + FablesLedgerV2 (as FablesHook) with raw storage writers and the Solidity twin exposed.
contract FullHarness is FablesFeeFull, FablesLedgerV2 {
    constructor(IPoolManager poolManager_, address authority_) FablesFeeFull(poolManager_, authority_) {}

    function __setWord(PoolId poolId, uint256 w) external {
        _word[poolId] = w;
    }

    function __setCF(PoolId poolId, uint256 cf) external {
        _cf[poolId] = cf;
    }

    function __setEntry(PoolId poolId, address account, uint256 e) external {
        _entry[poolId][account] = e;
    }

    function entryWord(PoolId poolId, address account) external view returns (uint256) {
        return _entry[poolId][account];
    }

    function resolveFeeRef(PoolId poolId, bool zeroForOne, address sender)
        external
        view
        returns (uint256 fee, uint256 cfNew)
    {
        return _resolveFeeRef(poolId, zeroForOne, sender);
    }
}
