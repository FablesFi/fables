// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";

/// @notice Per-range share totals and fee accumulators.
/// @dev The four per-share levels wrap mod 2^256 like v4 fee growth: only `level - checkpoint` has a meaning.
struct RangeState {
    uint128 totalShares;
    uint128 totalStaked;
    uint256 accFee0X128; // fee per unstaked share, Q128
    uint256 accFee1X128;
    uint256 accStaked0X128; // fee given up per staked share, Q128
    uint256 accStaked1X128;
    uint128 stakedResidual0; // staked-cut remainder, Q128 fraction of one fee unit
    uint128 stakedResidual1;
    uint64 collectionSeq; // FeesCollected emits
    uint64 resetSeq; // zero-liquidity crossings (re-bases)
}

struct ClaimFeeChange {
    uint64 fromTs;
    uint16 bps;
}

enum Action {
    MODIFY,
    PAYOUT,
    JIT
}

/// @dev A liquidity-modify unlock. The limits are max paid on a deposit, min received on a withdraw.
struct CallbackData {
    PoolKey key;
    int24 tickLower;
    int24 tickUpper;
    int256 liquidityDelta;
    address user;
    uint128 amount0Limit;
    uint128 amount1Limit;
}

struct PayoutData {
    Currency currency0;
    Currency currency1;
    uint256 amount0;
    uint256 amount1;
    address to;
}

/// @notice Staked-share revenue swept to the distributor (FABLES goes to `ffFeeSink`).
event DistributorSwept(Currency indexed currency, address indexed distributor, uint256 amount);

/// @notice Claim-fee revenue swept to the recipient.
event ClaimFeeSwept(Currency indexed currency, address indexed recipient, uint256 amount);

/// @notice Claim-fee cut taken from one range's collection, at the rate that applied.
event ClaimFeeAccrued(uint256 indexed rangeId, PoolId indexed poolId, uint256 cut0, uint256 cut1, uint16 feeBps);

struct PoolClaimFee {
    uint16 bps; // current rate; an upper bound on what any backlog pays
    uint16 allTimeMin; // fallback once a backlog outruns the walk
    ClaimFeeChange[] history; // oldest first
}

struct UserPosition {
    uint128 staked;
    uint128 owed0;
    uint128 owed1;
    uint256 checkpoint0X128;
    uint256 checkpoint1X128;
    uint256 stakedCheckpoint0X128;
    uint256 stakedCheckpoint1X128;
    uint256 forgone0; // running total of `FeesForgone` (rounded down)
    uint256 forgone1;
}

/// @notice Fees a holder's staked shares gave up since their last settle (rounded down per holder).
event FeesForgone(address indexed owner, uint256 indexed rangeId, uint256 amount0, uint256 amount1);

/// @dev Stored on first deposit so paths without a PoolKey (ERC-6909 transfers) can sync fees.
struct RangeKey {
    PoolKey key;
    int24 tickLower;
    int24 tickUpper;
    bool set;
}

/// @notice Emitted on every collection so the staked/unstaked split is reproducible from logs; levels wrap mod 2^256.
/// @dev `collectionSeq` increments on every emit, `resetSeq` on every zero-liquidity crossing (re-base).
event FeesCollected(
    uint256 indexed rangeId,
    uint256 fee0,
    uint256 fee1,
    uint256 stakedCut0,
    uint256 stakedCut1,
    uint256 accStaked0X128,
    uint256 accStaked1X128,
    uint256 feeGrowthInside0X128,
    uint256 feeGrowthInside1X128,
    uint128 totalShares,
    uint128 totalStaked,
    uint64 collectionSeq,
    uint64 resetSeq
);
