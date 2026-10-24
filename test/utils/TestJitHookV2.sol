// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {FablesHookCore} from "../../src/base/FablesHookCore.sol";
import {FablesLedgerV2} from "../../src/base/FablesLedgerV2.sol";
import {Action} from "../../src/base/LedgerTypesV2.sol";
import {TestHookV2} from "./TestHookV2.sol";

/// @notice Test-only concrete with `_isJit()` true and an in-memory book behind the five JIT seam entries.
contract TestJitHookV2 is FablesHookCore, FablesLedgerV2 {
    using PoolIdLibrary for PoolKey;

    int24 public constant OUTER_LOWER = -887_220;
    int24 public constant OUTER_UPPER = 887_220;

    error NotTheBooksRange();

    struct Book {
        uint128 pot0;
        uint128 pot1;
        uint256 growth0X128;
        uint256 growth1X128;
    }

    struct DepositCall {
        uint256 id;
        uint128 shares;
        uint128 max0;
        uint128 max1;
        uint128 totalSharesSeen;
        address payer;
    }

    struct WithdrawCall {
        uint256 id;
        uint128 shares;
        uint128 min0;
        uint128 min1;
        address to;
        uint128 totalSharesSeen;
    }

    mapping(uint256 id => Book) public book;
    DepositCall public lastDeposit;
    WithdrawCall public lastWithdraw;
    uint256 public syncCalls;
    uint256 public depositCalls;
    uint256 public withdrawCalls;
    bytes public lastUnlockPayload;

    constructor(IPoolManager poolManager_, address authority_) FablesHookCore(poolManager_, authority_) {}

    function configure(PoolId poolId, uint24 cap) external {
        maxFee[poolId] = cap;
    }

    function fundPot(uint256 id, uint128 fee0, uint128 fee1) external {
        book[id].pot0 += fee0;
        book[id].pot1 += fee1;
    }

    function setGrowth(uint256 id, uint256 growth0X128, uint256 growth1X128) external {
        book[id].growth0X128 = growth0X128;
        book[id].growth1X128 = growth1X128;
    }

    function syncRange(uint256 id) external {
        _syncRange(id);
    }

    function unlockJit(bytes calldata payload) external returns (bytes memory) {
        return poolManager.unlock(abi.encode(Action.JIT, payload));
    }

    function unlockRaw(bytes calldata data) external returns (bytes memory) {
        return poolManager.unlock(data);
    }

    function isJit() external pure returns (bool) {
        return _isJit();
    }

    function _isJit() internal pure override returns (bool) {
        return true;
    }

    function _jitSync(uint256 id)
        internal
        override
        returns (uint128 fee0, uint128 fee1, uint256 growth0X128, uint256 growth1X128)
    {
        Book storage b = book[id];
        (fee0, fee1) = (b.pot0, b.pot1);
        (b.pot0, b.pot1) = (0, 0);
        uint128 total = _ranges[id].totalShares;
        b.growth0X128 += FullMath.mulDiv(fee0, 1 << 128, total);
        b.growth1X128 += FullMath.mulDiv(fee1, 1 << 128, total);
        syncCalls++;
        return (fee0, fee1, b.growth0X128, b.growth1X128);
    }

    function _jitDeposit(PoolKey calldata key, uint256 id, uint128 shares, uint128 max0, uint128 max1)
        internal
        override
    {
        if (id != rangeId(key.toId(), OUTER_LOWER, OUTER_UPPER)) revert NotTheBooksRange();
        lastDeposit = DepositCall(id, shares, max0, max1, _ranges[id].totalShares, msg.sender);
        depositCalls++;
    }

    function _jitWithdraw(PoolKey calldata, uint256 id, uint128 shares, uint128 min0, uint128 min1, address to)
        internal
        override
    {
        lastWithdraw = WithdrawCall(id, shares, min0, min1, to, _ranges[id].totalShares);
        withdrawCalls++;
    }

    function _jitRangeGrowth(uint256 id) internal view override returns (uint256, uint256) {
        return (book[id].growth0X128, book[id].growth1X128);
    }

    function _jitUnlock(bytes calldata payload) internal override returns (bytes memory) {
        lastUnlockPayload = payload;
        return abi.encode(keccak256(payload), payload.length);
    }
}

/// @notice `TestHookV2` with the seam entries exposed, to show the defaults revert.
contract TestHookV2SeamProbe is TestHookV2 {
    constructor(IPoolManager poolManager_, address authority_) TestHookV2(poolManager_, authority_) {}

    function isJit() external pure returns (bool) {
        return _isJit();
    }

    function jitSync(uint256 id) external returns (uint128, uint128, uint256, uint256) {
        return _jitSync(id);
    }

    function jitDeposit(PoolKey calldata key, uint256 id, uint128 shares, uint128 max0, uint128 max1) external {
        _jitDeposit(key, id, shares, max0, max1);
    }

    function jitWithdraw(PoolKey calldata key, uint256 id, uint128 shares, uint128 min0, uint128 min1, address to)
        external
    {
        _jitWithdraw(key, id, shares, min0, min1, to);
    }

    function jitRangeGrowth(uint256 id) external view returns (uint256, uint256) {
        return _jitRangeGrowth(id);
    }

    function jitUnlock(bytes calldata payload) external returns (bytes memory) {
        return _jitUnlock(payload);
    }

    function unlockRaw(bytes calldata data) external returns (bytes memory) {
        return poolManager.unlock(data);
    }
}
