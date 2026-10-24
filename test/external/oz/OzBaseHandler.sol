// SPDX-License-Identifier: MIT
// Adapted from OpenZeppelin Uniswap Hooks v1.3.0 (MIT, Copyright (c) 2016-2026 Zeppelin Group Ltd).
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IERC6909Claims} from "v4-core/src/interfaces/external/IERC6909Claims.sol";
import {IERC20Minimal} from "v4-core/src/interfaces/external/IERC20Minimal.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {FixedPoint128} from "v4-core/src/libraries/FixedPoint128.sol";
import {Position} from "v4-core/src/libraries/Position.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";

/// @notice Enumerable address set for actor management (OpenZeppelin `test/invariant/helpers/AddressSet.sol`).
struct AddressSet {
    address[] addrs;
    mapping(address => bool) saved;
}

library LibAddressSet {
    function add(AddressSet storage s, address addr) internal {
        if (!s.saved[addr]) {
            s.addrs.push(addr);
            s.saved[addr] = true;
        }
    }

    function rand(AddressSet storage s, uint256 seed) internal view returns (address) {
        return s.addrs[seed % s.addrs.length];
    }
}

/// @notice Handler base from OpenZeppelin's `BaseHandler` and `HookTest`: actors, call counts, PoolManager claims,
///         position fees and the hook-rejection test on wrapped reverts.
abstract contract OzBaseHandler is Test {
    using StateLibrary for IPoolManager;
    using CurrencyLibrary for Currency;
    using LibAddressSet for AddressSet;

    /// @dev `CustomRevert.WrappedError(address,bytes4,bytes,bytes)`.
    bytes4 internal constant WRAPPED_ERROR_SELECTOR = 0x90bfb865;

    IPoolManager public manager;
    AddressSet internal _actors;

    /// @notice Action name => calls that reached the target.
    mapping(bytes32 => uint256) public calls;

    modifier recordCall(bytes32 name) {
        _;
        calls[name]++;
    }

    function _createActor(address actor) internal {
        _actors.add(actor);
    }

    function _actorFromSeed(uint256 seed) internal view returns (address) {
        return _actors.rand(seed);
    }

    function actors() public view returns (address[] memory) {
        return _actors.addrs;
    }

    /// @dev Token or native balance.
    function _balanceOf(Currency currency, address who) internal view returns (uint256) {
        return currency.isAddressZero() ? who.balance : IERC20Minimal(Currency.unwrap(currency)).balanceOf(who);
    }

    /// @notice ERC-6909 claim balance `who` holds in the PoolManager for `currency`.
    function claimsOf(Currency currency, address who) public view returns (uint256) {
        return IERC6909Claims(address(manager)).balanceOf(who, currency.toId());
    }

    /// @dev Fees a position has accrued in the PoolManager and not yet collected (`HookTest.calculateFees`).
    function _calculateFees(PoolId poolId, address owner, int24 tickLower, int24 tickUpper, bytes32 salt)
        internal
        view
        returns (uint256 fees0, uint256 fees1)
    {
        bytes32 positionKey = Position.calculatePositionKey(owner, tickLower, tickUpper, salt);
        (uint128 liquidity, uint256 last0, uint256 last1) = manager.getPositionInfo(poolId, positionKey);
        (uint256 inside0, uint256 inside1) = manager.getFeeGrowthInside(poolId, tickLower, tickUpper);
        unchecked {
            fees0 = FullMath.mulDiv(inside0 - last0, liquidity, FixedPoint128.Q128);
            fees1 = FullMath.mulDiv(inside1 - last1, liquidity, FixedPoint128.Q128);
        }
    }

    /// @dev Whether a revert came from `hook` rather than from the pool: the PoolManager wraps a hook revert in
    ///      `WrappedError` naming the hook.
    function _isHookRejection(bytes memory reason, address hook) internal pure returns (bool) {
        if (reason.length < 36) return false;
        bytes4 selector;
        address target;
        assembly ("memory-safe") {
            selector := mload(add(reason, 0x20))
            target := mload(add(reason, 0x24))
        }
        return selector == WRAPPED_ERROR_SELECTOR && target == hook;
    }
}
