// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {
    RangeState,
    UserPosition,
    RangeKey,
    ClaimFeeChange,
    PoolClaimFee,
    Action,
    CallbackData,
    PayoutData,
    FeesForgone,
    FeesCollected,
    DistributorSwept,
    ClaimFeeSwept,
    ClaimFeeAccrued
} from "../base/LedgerTypesV2.sol";

interface IDistributorFables {
    /// @notice The FABLES token.
    function ff() external view returns (address);
}

/// @title LedgerLibV2
/// @notice Fee collection, holder settlement and unlock-callback logic for FablesLedgerV2.
/// @dev Internal functions only (`address(this)` is the hook). Fees are held as PoolManager ERC-6909 claims, so collecting
///      them never calls a token.
library LedgerLibV2 {
    /// @notice Deposit principal above the caller's max for that currency.
    error PrincipalAboveMax(uint256 paid, uint256 max);
    /// @notice Withdrawal principal below the caller's min for that currency.
    error PrincipalBelowMin(uint256 received, uint256 min);

    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using SafeERC20 for IERC20;

    struct ClaimFeeState {
        address recipient;
    }

    /// @dev Max history entries a sync walks; beyond it the all-time minimum rate applies (can only charge less).
    uint256 internal constant MAX_CLAIM_FEE_WALK = 32;
    uint16 internal constant MAX_CLAIM_FEE_BPS = 2000;
    /// @dev Cap of a holder's owed fees, so a claim fits one v4 `burn` / `take`.
    uint128 private constant MAX_OWED = uint128(type(int128).max);

    error InvalidClaimFee();
    error InvalidSink();
    error DistributorNotFablesAware();

    struct CreditParams {
        uint256 id;
        PoolKey key;
        uint128 fee0;
        uint128 fee1;
        address claimFeeRecipient;
    }

    /// @notice Collects one range's fees: mints claims, splits staked/unstaked, skims the claim fee, logs the split.
    /// @dev With `jit` the claims already exist and the given growth levels are logged instead of v4's.
    function creditFees(
        mapping(uint256 => RangeState) storage ranges,
        mapping(uint256 => RangeKey) storage rangeKeys,
        mapping(Currency => uint256) storage distributorOwed,
        mapping(Currency => uint256) storage claimFeeOwed,
        mapping(uint256 => uint64) storage claimFeeSyncIndex,
        mapping(PoolId => PoolClaimFee) storage poolClaimFee,
        IPoolManager poolManager,
        CreditParams memory p,
        bool jit,
        uint256 growth0X128,
        uint256 growth1X128
    ) internal {
        // price the backlog from the old index, then move the index to the head (before any early return)
        PoolClaimFee storage pcf = poolClaimFee[p.key.toId()];
        uint16 feeBps = claimFeeFor(pcf.history, claimFeeSyncIndex[p.id], p.claimFeeRecipient, pcf.bps, pcf.allTimeMin);
        claimFeeSyncIndex[p.id] = uint64(pcf.history.length);
        if (p.fee0 == 0 && p.fee1 == 0) return;
        RangeState storage range = ranges[p.id];
        if (!jit) {
            if (p.fee0 > 0) poolManager.mint(address(this), p.key.currency0.toId(), p.fee0);
            if (p.fee1 > 0) poolManager.mint(address(this), p.key.currency1.toId(), p.fee1);
            (growth0X128, growth1X128) = _growthOf(rangeKeys[p.id], poolManager);
        }
        (uint256 cut0, uint256 cut1) = _split(range, distributorOwed, claimFeeOwed, p, feeBps);
        _emitCollected(range, EmitArgs(p.id, p.fee0, p.fee1, cut0, cut1), growth0X128, growth1X128);
    }

    function _split(
        RangeState storage range,
        mapping(Currency => uint256) storage distributorOwed,
        mapping(Currency => uint256) storage claimFeeOwed,
        CreditParams memory p,
        uint16 feeBps
    ) private returns (uint256, uint256) {
        uint256 total = range.totalShares;
        if (total == 0) {
            distributorOwed[p.key.currency0] += p.fee0;
            distributorOwed[p.key.currency1] += p.fee1;
            return (p.fee0, p.fee1);
        }

        // The staked cut carries its remainder, since a forced sync could otherwise floor it to zero. The unstaked
        // side floors twice; that dust (under one unit per collection or settle) stays as hook-held claims.
        uint256 stakedCut0 = _takeStakedCut(range, p.fee0, total, true);
        uint256 stakedCut1 = _takeStakedCut(range, p.fee1, total, false);
        if (stakedCut0 > 0) distributorOwed[p.key.currency0] += stakedCut0;
        if (stakedCut1 > 0) distributorOwed[p.key.currency1] += stakedCut1;
        _creditStaked(range, stakedCut0, stakedCut1);

        uint256 unstakedTotal = total - range.totalStaked;
        if (unstakedTotal == 0) {
            distributorOwed[p.key.currency0] += p.fee0 - stakedCut0;
            distributorOwed[p.key.currency1] += p.fee1 - stakedCut1;
            _creditStaked(range, p.fee0 - stakedCut0, p.fee1 - stakedCut1);
            return (p.fee0, p.fee1);
        }

        // claim fee: at the rate in force while the fees accrued, on the unstaked residue only, floored
        uint256 net0 = p.fee0 - stakedCut0;
        uint256 net1 = p.fee1 - stakedCut1;
        if (feeBps != 0 && p.claimFeeRecipient != address(0)) {
            uint256 c0 = (net0 * feeBps) / 10_000;
            uint256 c1 = (net1 * feeBps) / 10_000;
            if (c0 > 0) claimFeeOwed[p.key.currency0] += c0;
            if (c1 > 0) claimFeeOwed[p.key.currency1] += c1;
            net0 -= c0;
            net1 -= c1;
            if (c0 > 0 || c1 > 0) emit ClaimFeeAccrued(p.id, p.key.toId(), c0, c1, feeBps);
        }
        // wraps mod 2^256 like v4 fee growth (only `level - checkpoint` is read); a checked add could lock the range
        unchecked {
            range.accFee0X128 += FullMath.mulDiv(net0, 1 << 128, unstakedTotal);
            range.accFee1X128 += FullMath.mulDiv(net1, 1 << 128, unstakedTotal);
        }
        return (stakedCut0, stakedCut1);
    }

    /// @notice Claim-fee rate (bps) for a backlog opened at history index `sinceIndex`: the lowest rate in force since
    ///         then, capped by the current one (0 without a recipient).
    function claimFeeFor(
        ClaimFeeChange[] storage claimFeeHistory,
        uint64 sinceIndex,
        address claimFeeRecipient,
        uint16 claimFeeBps,
        uint16 claimFeeAllTimeMin
    ) internal view returns (uint16) {
        if (sinceIndex == 0) return 0; // opened before any claim fee was set

        uint16 rate = claimFeeRecipient == address(0) ? 0 : claimFeeBps;
        uint256 start = uint256(sinceIndex) - 1; // the entry in force when the backlog opened
        uint256 i = claimFeeHistory.length;
        uint256 walked = 0;
        while (i > start && walked < MAX_CLAIM_FEE_WALK) {
            ClaimFeeChange storage change = claimFeeHistory[i - 1];
            if (change.bps < rate) rate = change.bps;
            i--;
            walked++;
        }
        if (i == start) return rate; // the whole window was covered exactly

        uint16 floor_ = claimFeeAllTimeMin;
        return floor_ < rate ? floor_ : rate;
    }

    function recordClaimFee(
        ClaimFeeChange[] storage claimFeeHistory,
        uint16 bps,
        address recipient,
        address distributor,
        address ffFeeSink,
        uint16 currentAllTimeMin
    ) internal returns (uint16 newAllTimeMin) {
        if (bps > MAX_CLAIM_FEE_BPS) revert InvalidClaimFee();
        if (bps != 0 && recipient == address(0)) revert InvalidClaimFee();
        if (recipient == address(this)) revert InvalidClaimFee();
        if (recipient != address(0) && recipient == distributor) revert InvalidClaimFee();
        if (recipient != address(0) && recipient == ffFeeSink) revert InvalidClaimFee();

        uint256 length = claimFeeHistory.length;
        uint16 effective = recipient == address(0) ? 0 : bps;
        // forge-lint: disable-next-line(block-timestamp)
        claimFeeHistory.push(ClaimFeeChange({fromTs: uint64(block.timestamp), bps: effective}));
        newAllTimeMin = (length == 0 || effective < currentAllTimeMin) ? effective : currentAllTimeMin;
    }

    /// @notice Validates a new distributor (zero clears it) and returns its non-zero FABLES token (`ff()`) to cache.
    function validateDistributor(address distributor_, address ffFeeSink, address claimFeeRecipient)
        internal
        view
        returns (address distributorFF)
    {
        if (distributor_ == address(0)) return address(0);
        if (distributor_ == ffFeeSink) revert InvalidSink();
        if (distributor_ == claimFeeRecipient) revert InvalidSink();
        if (distributor_ == address(this)) revert InvalidSink();
        // code check first: try/catch cannot catch the decode revert on an EOA
        if (distributor_.code.length == 0) revert DistributorNotFablesAware();
        try IDistributorFables(distributor_).ff() returns (address fablesToken) {
            if (fablesToken == address(0)) revert DistributorNotFablesAware();
            return fablesToken;
        } catch {
            revert DistributorNotFablesAware();
        }
    }

    struct EmitArgs {
        uint256 id;
        uint256 fee0;
        uint256 fee1;
        uint256 cut0;
        uint256 cut1;
    }

    /// @notice Emits the zero-value collection that anchors a (re)created position's fresh `feeGrowthInside` base.
    function emitRebaseBaseline(
        mapping(uint256 => RangeState) storage ranges,
        mapping(uint256 => RangeKey) storage rangeKeys,
        IPoolManager poolManager,
        uint256 id,
        bool jit,
        uint256 growth0X128,
        uint256 growth1X128
    ) internal {
        if (!jit) (growth0X128, growth1X128) = _growthOf(rangeKeys[id], poolManager);
        _emitCollected(ranges[id], EmitArgs(id, 0, 0, 0, 0), growth0X128, growth1X128);
    }

    function _emitCollected(RangeState storage range, EmitArgs memory e, uint256 growth0, uint256 growth1) private {
        range.collectionSeq += 1;
        _log(e.id, e.fee0, e.fee1, e.cut0, e.cut1, growth0, growth1, range);
    }

    function _growthOf(RangeKey storage descriptor, IPoolManager poolManager) private view returns (uint256, uint256) {
        return
            StateLibrary.getFeeGrowthInside(
                poolManager, descriptor.key.toId(), descriptor.tickLower, descriptor.tickUpper
            );
    }

    function _log(
        uint256 id,
        uint256 fee0,
        uint256 fee1,
        uint256 cut0,
        uint256 cut1,
        uint256 growth0,
        uint256 growth1,
        RangeState storage range
    ) private {
        emit FeesCollected(
            id,
            fee0,
            fee1,
            cut0,
            cut1,
            range.accStaked0X128,
            range.accStaked1X128,
            growth0,
            growth1,
            range.totalShares,
            range.totalStaked,
            range.collectionSeq,
            range.resetSeq
        );
    }

    /// `fee * staked / total` (floored) plus any whole unit of the carried Q128 remainder; `cut <= fee`.
    function _takeStakedCut(RangeState storage range, uint128 fee, uint256 total, bool isToken0)
        private
        returns (uint256 cut)
    {
        uint128 staked = range.totalStaked;
        uint256 carried = uint256(isToken0 ? range.stakedResidual0 : range.stakedResidual1)
            + FullMath.mulDiv(mulmod(fee, staked, total), 1 << 128, total);
        cut = FullMath.mulDiv(fee, staked, total) + (carried >> 128);
        // safe: carried < 2^129 and any whole unit was just flushed into cut
        // forge-lint: disable-next-line(unsafe-typecast)
        uint128 keep = uint128(carried);
        if (isToken0) range.stakedResidual0 = keep;
        else range.stakedResidual1 = keep;
    }

    function _creditStaked(RangeState storage range, uint256 cut0, uint256 cut1) private {
        uint128 staked = range.totalStaked;
        if (staked == 0) return;
        // cut <= fee < 2^128, so each term is < 2^256; the levels wrap like accFee
        unchecked {
            if (cut0 > 0) range.accStaked0X128 += FullMath.mulDiv(cut0, 1 << 128, staked);
            if (cut1 > 0) range.accStaked1X128 += FullMath.mulDiv(cut1, 1 << 128, staked);
        }
    }

    /// @notice Checkpoints a holder's accrued fees and emission weight (`FeesForgone`) at the range's current levels.
    /// @dev Called before every change to the holder's share count.
    function settleUser(
        RangeState storage range,
        UserPosition storage position,
        uint256 balance,
        address owner,
        uint256 id
    ) internal {
        uint256 unstaked = balance - position.staked;
        if (unstaked != 0) {
            // saturating (tokens above 2^127 units are unsupported): a revert would block the holder's withdraw
            position.owed0 = _accrue(
                position.owed0, FullMath.mulDiv(unstaked, _since(range.accFee0X128, position.checkpoint0X128), 1 << 128)
            );
            position.owed1 = _accrue(
                position.owed1, FullMath.mulDiv(unstaked, _since(range.accFee1X128, position.checkpoint1X128), 1 << 128)
            );
        }
        position.checkpoint0X128 = range.accFee0X128;
        position.checkpoint1X128 = range.accFee1X128;

        uint128 staked = position.staked;
        if (staked != 0) {
            uint256 d0 = FullMath.mulDiv(staked, _since(range.accStaked0X128, position.stakedCheckpoint0X128), 1 << 128);
            uint256 d1 = FullMath.mulDiv(staked, _since(range.accStaked1X128, position.stakedCheckpoint1X128), 1 << 128);
            if (d0 != 0 || d1 != 0) {
                // running total; a revert here would block the holder's withdraw
                unchecked {
                    position.forgone0 += d0;
                    position.forgone1 += d1;
                }
                emit FeesForgone(owner, id, d0, d1);
            }
        }
        position.stakedCheckpoint0X128 = range.accStaked0X128;
        position.stakedCheckpoint1X128 = range.accStaked1X128;
    }

    function _since(uint256 level, uint256 checkpoint) private pure returns (uint256) {
        unchecked {
            return level - checkpoint;
        }
    }

    function _accrue(uint128 owed, uint256 inc) private pure returns (uint128) {
        // owed <= MAX_OWED, and the sum is formed only when inc < MAX_OWED - owed
        unchecked {
            uint256 room = MAX_OWED - owed;
            // forge-lint: disable-next-line(unsafe-typecast)
            return inc < room ? owed + uint128(inc) : MAX_OWED;
        }
    }

    /// @notice Unlock body: PAYOUT redeems held claims; MODIFY applies the delta, credits fees and settles principal.
    function onUnlock(
        mapping(uint256 => RangeState) storage ranges,
        mapping(uint256 => RangeKey) storage rangeKeys,
        mapping(Currency => uint256) storage distributorOwed,
        mapping(Currency => uint256) storage claimFeeOwed,
        mapping(uint256 => uint64) storage claimFeeSyncIndex,
        mapping(PoolId => PoolClaimFee) storage poolClaimFee,
        IPoolManager poolManager,
        ClaimFeeState memory cf,
        bytes calldata rawData
    ) internal returns (bytes memory) {
        (Action action, bytes memory payload) = abi.decode(rawData, (Action, bytes));
        if (action == Action.PAYOUT) {
            PayoutData memory pd = abi.decode(payload, (PayoutData));
            _redeem(poolManager, pd.currency0, pd.amount0, pd.to);
            _redeem(poolManager, pd.currency1, pd.amount1, pd.to);
            return "";
        }
        _onModify(
            ranges, rangeKeys, distributorOwed, claimFeeOwed, claimFeeSyncIndex, poolClaimFee, poolManager, cf, payload
        );
        return "";
    }

    function _onModify(
        mapping(uint256 => RangeState) storage ranges,
        mapping(uint256 => RangeKey) storage rangeKeys,
        mapping(Currency => uint256) storage distributorOwed,
        mapping(Currency => uint256) storage claimFeeOwed,
        mapping(uint256 => uint64) storage claimFeeSyncIndex,
        mapping(PoolId => PoolClaimFee) storage poolClaimFee,
        IPoolManager poolManager,
        ClaimFeeState memory cf,
        bytes memory payload
    ) private {
        CallbackData memory data = abi.decode(payload, (CallbackData));
        (BalanceDelta callerDelta, BalanceDelta feesAccrued) = poolManager.modifyLiquidity(
            data.key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: data.tickLower,
                tickUpper: data.tickUpper,
                liquidityDelta: data.liquidityDelta,
                salt: bytes32(0)
            }),
            ""
        );

        // credited at post-mutation totals: safe only because each caller's earlier `_syncRange` drained the fees
        creditFees(
            ranges,
            rangeKeys,
            distributorOwed,
            claimFeeOwed,
            claimFeeSyncIndex,
            poolClaimFee,
            poolManager,
            CreditParams({
                id: uint256(keccak256(abi.encode(data.key.toId(), data.tickLower, data.tickUpper))),
                key: data.key,
                // fee deltas are non-negative
                // forge-lint: disable-next-line(unsafe-typecast)
                fee0: uint128(uint256(int256(feesAccrued.amount0()))),
                // forge-lint: disable-next-line(unsafe-typecast)
                fee1: uint128(uint256(int256(feesAccrued.amount1()))),
                claimFeeRecipient: cf.recipient
            }),
            false,
            0,
            0
        );

        _settlePrincipal(
            poolManager,
            data.key,
            callerDelta,
            feesAccrued,
            data.user,
            data.liquidityDelta,
            data.amount0Limit,
            data.amount1Limit
        );
    }

    function _settlePrincipal(
        IPoolManager poolManager,
        PoolKey memory key,
        BalanceDelta callerDelta,
        BalanceDelta feesAccrued,
        address user,
        int256 liquidityDelta,
        uint128 amount0Limit,
        uint128 amount1Limit
    ) private {
        int128 principal0 = callerDelta.amount0() - feesAccrued.amount0();
        int128 principal1 = callerDelta.amount1() - feesAccrued.amount1();
        _checkBound(principal0, liquidityDelta, amount0Limit);
        _checkBound(principal1, liquidityDelta, amount1Limit);
        _resolvePrincipal(poolManager, key.currency0, principal0, user);
        _resolvePrincipal(poolManager, key.currency1, principal1, user);
    }

    /// Slippage bound: a ceiling on paid principal for an add, a floor on received principal for a remove.
    function _checkBound(int128 principal, int256 liquidityDelta, uint128 limit) private pure {
        if (liquidityDelta > 0) {
            // widened before negating (-int128 panics on type(int128).min), so the uint256 cast is exact
            // forge-lint: disable-next-line(unsafe-typecast)
            uint256 paid = principal < 0 ? uint256(-int256(principal)) : 0;
            if (paid > limit) revert PrincipalAboveMax(paid, limit);
        } else if (liquidityDelta < 0) {
            // guarded positive, so the cast is exact
            // forge-lint: disable-next-line(unsafe-typecast)
            uint256 received = principal > 0 ? uint256(int256(principal)) : 0;
            if (received < limit) revert PrincipalBelowMin(received, limit);
        }
    }

    function _redeem(IPoolManager poolManager, Currency currency, uint256 amount, address to) private {
        if (amount == 0) return;
        poolManager.burn(address(this), currency.toId(), amount);
        poolManager.take(currency, to, amount);
    }

    /// @notice Burns the hook's claims and pays `to` in tokens via a PAYOUT unlock; a failure affects only this payout.
    function payout(
        IPoolManager poolManager,
        Currency currency0,
        Currency currency1,
        uint256 amount0,
        uint256 amount1,
        address to
    ) internal {
        if (amount0 == 0 && amount1 == 0) return;
        poolManager.unlock(
            abi.encode(Action.PAYOUT, abi.encode(PayoutData(currency0, currency1, amount0, amount1, to)))
        );
    }

    /// @notice Pays a currency's staked-share revenue to the distributor, or FABLES to `ffFeeSink`; waits while unset.
    function sweepDistributor(
        mapping(Currency => uint256) storage distributorOwed,
        IPoolManager poolManager,
        Currency currency,
        address distributor,
        address distributorFF,
        address ffFeeSink
    ) internal {
        uint256 amount = distributorOwed[currency];
        if (amount == 0) return;
        // `distributorFF != 0`: native unwraps to address(0), as does a cleared distributor's cached token
        address to =
            (distributorFF != address(0) && Currency.unwrap(currency) == distributorFF) ? ffFeeSink : distributor;
        if (to == address(0)) return;
        distributorOwed[currency] = 0;
        payout(poolManager, currency, currency, amount, 0, to);
        emit DistributorSwept(currency, to, amount);
    }

    /// @notice Pays a currency's claim-fee revenue to the recipient; a no-op while the recipient is unset.
    function sweepClaimFee(
        mapping(Currency => uint256) storage claimFeeOwed,
        IPoolManager poolManager,
        Currency currency,
        address claimFeeRecipient
    ) internal {
        uint256 amount = claimFeeOwed[currency];
        if (claimFeeRecipient == address(0) || amount == 0) return;
        claimFeeOwed[currency] = 0;
        payout(poolManager, currency, currency, amount, 0, claimFeeRecipient);
        emit ClaimFeeSwept(currency, claimFeeRecipient, amount);
    }

    /// Settles one currency's principal: negative is pulled from `user` (prepaid ETH for native), positive is paid.
    // a removal's principal is never negative, so `transferFrom` only ever pulls from the depositor
    // slither-disable-next-line arbitrary-send-erc20
    function _resolvePrincipal(IPoolManager poolManager, Currency currency, int128 amount, address user) private {
        if (amount < 0) {
            // widened before negating (-int128 panics on type(int128).min), so the uint256 cast is exact
            // forge-lint: disable-next-line(unsafe-typecast)
            uint256 owed = uint256(-int256(amount));
            poolManager.sync(currency);
            if (currency.isAddressZero()) {
                // prepaid: msg.value >= amount0Max >= owed (`_checkBound`)
                poolManager.settle{value: owed}();
            } else {
                IERC20(Currency.unwrap(currency)).safeTransferFrom(user, address(poolManager), owed);
                poolManager.settle();
            }
        } else if (amount > 0) {
            // forge-lint: disable-next-line(unsafe-typecast)
            poolManager.take(currency, user, uint256(uint128(amount)));
        }
    }
}
