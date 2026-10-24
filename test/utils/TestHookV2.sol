// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {FablesHookCore} from "../../src/base/FablesHookCore.sol";
import {FablesLedgerV2} from "../../src/base/FablesLedgerV2.sol";
import {FablesExclusiveLiquidityV2} from "../../src/base/FablesExclusiveLiquidityV2.sol";
import {FablesNativeETHV2, IWETH9} from "../../src/base/FablesNativeETHV2.sol";

/// @notice Test-only concrete: the ledger on FablesHookCore with no fee engine. `configure` stands in for the engine's
///         config write.
contract TestHookV2 is FablesHookCore, FablesLedgerV2 {
    constructor(IPoolManager poolManager_, address authority_) FablesHookCore(poolManager_, authority_) {}

    function configure(PoolId poolId, uint24 cap) external {
        maxFee[poolId] = cap;
    }
}

/// @notice `TestHookV2` plus the ledger-only liquidity gate.
contract TestHookV2Exclusive is TestHookV2, FablesExclusiveLiquidityV2 {
    constructor(IPoolManager poolManager_, address authority_) TestHookV2(poolManager_, authority_) {}
}

/// @notice `TestHookV2` plus the native-ETH mixin.
contract TestHookV2ETH is TestHookV2, FablesNativeETHV2 {
    constructor(IPoolManager poolManager_, address authority_, IWETH9 weth_)
        TestHookV2(poolManager_, authority_)
        FablesNativeETHV2(weth_)
    {}

    function _nativeAllowed() internal pure virtual override(FablesHookCore, FablesNativeETHV2) returns (bool) {
        return FablesNativeETHV2._nativeAllowed();
    }

    function _sweepDistributor(Currency currency) internal virtual override(FablesLedgerV2, FablesNativeETHV2) {
        FablesNativeETHV2._sweepDistributor(currency);
    }

    function _sweepClaimFee(Currency currency) internal virtual override(FablesLedgerV2, FablesNativeETHV2) {
        FablesNativeETHV2._sweepClaimFee(currency);
    }
}
