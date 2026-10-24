// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {FablesFeeEngine} from "../../src/base/FablesFeeEngine.sol";

function levelSince(uint256 level, uint256 checkpoint) pure returns (uint256) {
    unchecked {
        return level - checkpoint;
    }
}

/// @notice `currentFee` view.
interface ICurrentFee {
    function currentFee(PoolId poolId, bool zeroForOne) external view returns (uint24);
}

/// @notice Deploys FablesHook at a flag address with a permissive category, for the ledger suites.
abstract contract LedgerFixture is Test, Deployers {
    uint8 internal constant CAT = 1;
    uint160 internal constant FULL_FLAGS = uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG);

    function _deployBuild(uint160 prefix, address authority_) internal returns (address hookAddr) {
        hookAddr = address(uint160(prefix << 144) | FULL_FLAGS);
        deployCodeTo("FablesHook.sol:FablesHook", abi.encode(manager, authority_), hookAddr);
        FablesFeeEngine(hookAddr).setCategory(CAT, 0, 100_000, 100_000, "ANY");
    }

    function _configureFlat(address hookAddr, PoolKey memory key, uint24 base, uint24 floor, uint24 cap) internal {
        FablesFeeEngine(hookAddr).configurePool(key, CAT, base, base, floor, cap);
    }

    function _initPool(PoolKey memory key, uint160 sqrtPriceX96) internal {
        FablesFeeEngine(address(key.hooks)).initializePool(key, sqrtPriceX96);
    }
}
