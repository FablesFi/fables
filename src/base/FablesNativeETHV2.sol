// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {FablesLedgerV2} from "./FablesLedgerV2.sol";
import {LedgerLibV2} from "../libraries/LedgerLibV2.sol";
import {DistributorSwept, ClaimFeeSwept} from "./LedgerTypesV2.sol";

/// @notice The WETH surface the hook uses: wrap, plus the constructor's probes.
interface IWETH9 {
    function deposit() external payable;
    function totalSupply() external view returns (uint256);
    function balanceOf(address) external view returns (uint256);
}

/// @title FablesNativeETHV2
/// @notice Native-ETH currency0 support for the ledger; ERC20 pools keep working on the same hook.
/// @dev Native revenue sweeps are paid in WETH; LP withdrawals and claims in native ETH. ETH forced in (selfdestruct,
///      coinbase) is never refunded or rescued.
abstract contract FablesNativeETHV2 is FablesLedgerV2 {
    using CurrencyLibrary for Currency;
    using SafeERC20 for IERC20;

    error UnauthorizedETHSender();
    error NotWrappedEther();

    /// @notice A native distributor sweep was paid as WETH.
    /// @dev Emitted with `DistributorSwept(address(0), ...)`; credit the distributor in WETH from this event.
    event NativeRevenueWrappedToWeth(address indexed distributor, address indexed weth, uint256 amount);

    /// @notice A native claim-fee sweep was paid as WETH.
    /// @dev Emitted with `ClaimFeeSwept(address(0), ...)`; credit the recipient in WETH from this event.
    event NativeClaimFeeWrappedToWeth(address indexed recipient, address indexed weth, uint256 amount);

    /// @notice Wrapped-ETH contract native revenue is wrapped into.
    IWETH9 public immutable weth;

    constructor(IWETH9 weth_) {
        // anti-mistake probe, not a canonicality check: a payable non-WETH would silently swallow native sweeps
        if (address(weth_).code.length == 0) revert ZeroAddress();
        // decode probe (a payable catch-all returns no data, so this reverts); then WETH9's supply <= ether balance
        weth_.balanceOf(address(this));
        if (weth_.totalSupply() > address(weth_).balance) revert NotWrappedEther();
        weth = weth_;
    }

    function _nativeAllowed() internal pure virtual override returns (bool) {
        return true;
    }

    /// @notice Accepts ETH only from the PoolManager (`take` in a native sweep); depositors pay via `msg.value`.
    receive() external payable {
        if (msg.sender != address(poolManager)) revert UnauthorizedETHSender();
    }

    function _sweepDistributor(Currency currency) internal virtual override {
        if (!currency.isAddressZero()) {
            super._sweepDistributor(currency);
            return;
        }
        uint256 amount = distributorOwed[currency];
        if (amount == 0) return;
        address to = distributor;
        if (to == address(0)) return; // unset sink: the accrual waits
        distributorOwed[currency] = 0;
        LedgerLibV2.payout(poolManager, currency, currency, amount, 0, address(this));
        weth.deposit{value: amount}();
        IERC20(address(weth)).safeTransfer(to, amount);
        emit DistributorSwept(currency, to, amount);
        emit NativeRevenueWrappedToWeth(to, address(weth), amount);
    }

    function _sweepClaimFee(Currency currency) internal virtual override {
        if (!currency.isAddressZero()) {
            super._sweepClaimFee(currency);
            return;
        }
        uint256 amount = claimFeeOwed[currency];
        if (amount == 0) return;
        address to = claimFeeRecipient;
        if (to == address(0)) return; // unset sink: the accrual waits
        claimFeeOwed[currency] = 0;
        LedgerLibV2.payout(poolManager, currency, currency, amount, 0, address(this));
        weth.deposit{value: amount}();
        IERC20(address(weth)).safeTransfer(to, amount);
        emit ClaimFeeSwept(currency, to, amount);
        emit NativeClaimFeeWrappedToWeth(to, address(weth), amount);
    }
}
