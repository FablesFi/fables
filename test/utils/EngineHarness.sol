// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {FablesFeeEngine} from "../../src/base/FablesFeeEngine.sol";

/// @notice FablesFeeEngine as a hook with only the creation gate, plus raw storage writers.
contract EngineHarness is FablesFeeEngine {
    constructor(IPoolManager poolManager_, address authority_) FablesFeeEngine(poolManager_, authority_) {}

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
}

/// @notice FablesFeeEngine with its symmetric-mode hooks overridden: equal sides required, swap modules off, fee writes
///         counted.
contract EngineSymmetricHarness is FablesFeeEngine {
    uint256 public feeWrites;
    PoolId public lastFeeWrite;

    constructor(IPoolManager poolManager_, address authority_) FablesFeeEngine(poolManager_, authority_) {}

    function _requireSymmetric(uint24 side0, uint24 side1) internal pure override {
        if (side0 != side1) revert SymmetricRequired();
    }

    function _swapModulesEnabled() internal pure override returns (bool) {
        return false;
    }

    function _onFeeWrite(PoolId poolId) internal override {
        feeWrites++;
        lastFeeWrite = poolId;
    }
}
