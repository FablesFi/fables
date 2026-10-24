// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {FablesFeeFull} from "./base/FablesFeeFull.sol";
import {FablesLedgerV2} from "./base/FablesLedgerV2.sol";

/// @title FablesHook
/// @notice Dynamic-fee hook (per-side fees, pokes, discounts, continuation fee) with the LP ledger. ERC20 pools only.
/// @dev Flags 0x2080 (beforeInitialize | beforeSwap), validated in the constructor.
contract FablesHook is FablesFeeFull, FablesLedgerV2 {
    constructor(IPoolManager poolManager_, address authority_) FablesFeeFull(poolManager_, authority_) {}
}
