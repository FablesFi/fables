// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {BaseTestHooks} from "v4-core/src/test/BaseTestHooks.sol";

/// @notice Minimal dynamic-fee hook (constant beforeSwap override), used as a gas reference.
contract FixedFeeHook is BaseTestHooks {
    IPoolManager public immutable poolManager;
    uint24 public fee;

    error NotPoolManager();

    constructor(IPoolManager pm, uint24 fee_) {
        poolManager = pm;
        fee = fee_;
    }

    function setFee(uint24 fee_) external {
        fee = fee_;
    }

    function beforeInitialize(address, PoolKey calldata, uint160) external view override returns (bytes4) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        return IHooks.beforeInitialize.selector;
    }

    function beforeSwap(address, PoolKey calldata, IPoolManager.SwapParams calldata, bytes calldata)
        external
        view
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, fee | LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }
}
