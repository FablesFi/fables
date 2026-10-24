// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {FablesHook} from "./FablesHook.sol";
import {FablesHookCore} from "./base/FablesHookCore.sol";
import {FablesLedgerV2} from "./base/FablesLedgerV2.sol";
import {FablesNativeETHV2, IWETH9} from "./base/FablesNativeETHV2.sol";

/// @title FablesHookETH
/// @notice FablesHook that also serves native-ETH currency0 pools; native revenue sweeps are paid in WETH.
contract FablesHookETH is FablesHook, FablesNativeETHV2 {
    constructor(IPoolManager poolManager_, address authority_, IWETH9 weth_)
        FablesHook(poolManager_, authority_)
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
