// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {ERC6909} from "v4-core/src/ERC6909.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {FablesHookCore} from "./FablesHookCore.sol";
import {
    RangeState,
    UserPosition,
    RangeKey,
    ClaimFeeChange,
    PoolClaimFee,
    Action,
    CallbackData
} from "./LedgerTypesV2.sol";
import {LedgerLibV2} from "../libraries/LedgerLibV2.sol";

/// @notice The Voter interface the ledger uses.
interface IBallotGate {
    function ve() external view returns (address);
    function ballotBacks(address account, uint256 tokenId, PoolId poolId) external view returns (bool);
    function isGaugeKilled(PoolId poolId) external view returns (bool);
    function isGaugeLive(PoolId poolId) external view returns (bool);
    function isGaugeEarning(PoolId poolId) external view returns (bool);
    function gaugeWeightNow(PoolId poolId) external view returns (uint256);
}

/// @title FablesLedgerV2
/// @notice Per-range LP ledger inside the hook, with ERC-6909 receipts minted 1:1 with liquidity units.
/// @dev One PoolManager position per (pool, tickLower, tickUpper). Withdrawing and unstaking are never pausable or
///      gated. Fees settle as ERC-6909 claims pulled by holders; staked shares' fees go to the distributor.
abstract contract FablesLedgerV2 is FablesHookCore, ERC6909, ReentrancyGuardTransient, IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    error LedgerPaused();
    error GaugeBelowMinWeight();
    error PauseTooLong();
    error ZeroLiquidity();
    error DeadlineExpired();
    error InsufficientUnstakedShares();
    error ZeroShares();
    error ZeroAddress();
    error InvalidSink();
    error InvalidClaimFee();
    error DistributorNotFablesAware();
    error ClaimFeeAboveMax();
    error NothingToClaim();
    error NotAVoterOfThisPool();
    error BallotGateUnset();
    error GaugeNotEarning();
    error InvalidBallotGate();
    error InvalidMsgValue();
    error RefundFailed();
    error NotJitHook();

    event Deposited(address indexed owner, uint256 indexed rangeId, uint128 liquidity);
    event Withdrawn(address indexed owner, uint256 indexed rangeId, uint128 liquidity);
    event FeesClaimed(address indexed owner, uint256 indexed rangeId, uint256 amount0, uint256 amount1);
    event Staked(address indexed owner, uint256 indexed rangeId, uint128 shares);
    event Unstaked(address indexed owner, uint256 indexed rangeId, uint128 shares);
    event ClaimFeeSet(PoolId indexed poolId, uint16 bps, address recipient);
    event DistributorSet(address distributor);
    event FFFeeSinkSet(address sink);
    event PausedSet(uint256 pausedUntil);
    event PoolPausedSet(PoolId indexed poolId, uint256 pausedUntil);
    event BallotGateSet(address gate);

    /// @notice Max claim-fee rate: 2_000 bps (20%).
    uint16 public constant MAX_CLAIM_FEE_BPS = LedgerLibV2.MAX_CLAIM_FEE_BPS;
    uint256 public constant MAX_CLAIM_FEE_WALK = LedgerLibV2.MAX_CLAIM_FEE_WALK;

    /// @notice Hook-wide claim-fee recipient; while zero no claim fee is taken.
    address public claimFeeRecipient;
    address public distributor;
    /// @notice The FABLES token, cached from the distributor; never swept to it.
    address public distributorFF;
    /// @notice Receives FABLES-denominated staked-share fees.
    address public ffFeeSink;

    mapping(PoolId poolId => PoolClaimFee policy) internal _poolClaimFee;

    /// @notice Claim-fee history length when each range last realized fees, i.e. where its current backlog opened.
    mapping(uint256 rangeId => uint64 index) public claimFeeSyncIndex;

    /// @notice Hook-wide pause expiry; never blocks withdrawals or unstaking.
    uint256 public pausedUntil;

    /// @notice Per-pool pause expiry: freezes that pool's deposits, claims, staking and transfers (not sweeps).
    mapping(PoolId poolId => uint256 until) public pausedUntilOf;

    /// @notice The Voter (IBallotGate) that gates `stake` and `syncRanges`.
    address public ballotGate;

    uint256 public constant MAX_PAUSE = 7 days;

    /// @notice True while the ledger is paused for every pool.
    function paused() public view returns (bool) {
        // forge-lint: disable-next-line(block-timestamp)
        return pausedUntil > block.timestamp;
    }

    /// @notice True while `poolId` is frozen, by either the hook-wide or its own pause.
    function pausedFor(PoolId poolId) public view returns (bool) {
        // forge-lint: disable-next-line(block-timestamp)
        return pausedUntil > block.timestamp || pausedUntilOf[poolId] > block.timestamp;
    }

    modifier whenNotPaused() {
        if (paused()) revert LedgerPaused();
        _;
    }

    modifier whenPoolNotPaused(PoolId poolId) {
        if (pausedFor(poolId)) revert LedgerPaused();
        _;
    }

    /// @dev An unknown range resolves to the zero key, so only the hook-wide pause applies.
    modifier whenRangeNotPaused(uint256 id) {
        if (pausedFor(_rangeKeys[id].key.toId())) revert LedgerPaused();
        _;
    }

    mapping(uint256 rangeId => RangeKey descriptor) internal _rangeKeys;
    mapping(uint256 rangeId => RangeState state) internal _ranges;
    mapping(uint256 rangeId => mapping(address owner => UserPosition position)) internal _positions;
    mapping(Currency currency => uint256 owed) public distributorOwed;

    mapping(Currency currency => uint256 owed) public claimFeeOwed;

    /// @notice True mid-operation (visible only from a token callback); receipt pricers should refuse then.
    function isSettling() external view returns (bool) {
        return _reentrancyGuardEntered();
    }

    function rangeId(PoolId poolId, int24 tickLower, int24 tickUpper) public pure returns (uint256) {
        return uint256(keccak256(abi.encode(poolId, tickLower, tickUpper)));
    }

    /// @notice The pool key and ticks a `rangeId` was registered under; `set` is false before its first deposit.
    function rangeKey(uint256 id)
        external
        view
        returns (PoolKey memory key, int24 tickLower, int24 tickUpper, bool set)
    {
        RangeKey storage descriptor = _rangeKeys[id];
        return (descriptor.key, descriptor.tickLower, descriptor.tickUpper, descriptor.set);
    }

    /// @notice The range's v4 fee growth inside (Q128 per liquidity unit), or the JIT extension's own levels in that unit.
    /// @dev Wraps mod 2^256 and re-bases when the range empties and refills (`resetSeq` counts those).
    function rangeGrowth(uint256 id) external view returns (uint256 growth0, uint256 growth1) {
        RangeKey storage descriptor = _rangeKeys[id];
        if (!descriptor.set) return (0, 0);
        if (_isJit()) return _jitRangeGrowth(id);
        return
            StateLibrary.getFeeGrowthInside(
                poolManager, descriptor.key.toId(), descriptor.tickLower, descriptor.tickUpper
            );
    }

    function rangeState(uint256 id) external view returns (RangeState memory) {
        return _ranges[id];
    }

    function userPosition(uint256 id, address owner) external view returns (UserPosition memory) {
        return _positions[id][owner];
    }

    /// @notice Sets a pool's claim-fee rate and the hook-wide recipient, after sweeping the `settleFirst` currencies.
    /// @dev The recipient never returns to zero once set, so each pool's history records every rate.
    function setClaimFee(PoolKey calldata key, Currency[] calldata settleFirst, uint16 bps, address recipient)
        external
        restricted
        nonReentrant
    {
        if (recipient == address(0) && claimFeeRecipient != address(0)) revert InvalidClaimFee();
        _checkKey(key);
        _settleSinks(settleFirst);
        PoolClaimFee storage pcf = _poolClaimFee[key.toId()];
        _checkSinkTarget(recipient);
        pcf.allTimeMin = LedgerLibV2.recordClaimFee(pcf.history, bps, recipient, distributor, ffFeeSink, pcf.allTimeMin);
        pcf.bps = bps;
        claimFeeRecipient = recipient;
        emit ClaimFeeSet(key.toId(), bps, recipient);
    }

    /// @notice Sets a pool's claim-fee rate against the current recipient; never sweeps.
    function setClaimFeeBps(PoolKey calldata key, uint16 bps) external restricted nonReentrant {
        address recipient = claimFeeRecipient;
        if (recipient == address(0)) revert InvalidClaimFee();
        _checkKey(key);
        PoolClaimFee storage pcf = _poolClaimFee[key.toId()];
        _checkSinkTarget(recipient);
        pcf.allTimeMin = LedgerLibV2.recordClaimFee(pcf.history, bps, recipient, distributor, ffFeeSink, pcf.allTimeMin);
        pcf.bps = bps;
        emit ClaimFeeSet(key.toId(), bps, recipient);
    }

    /// @notice Sets the sink for FABLES-denominated staked-share fees, after sweeping the `settleFirst` currencies.
    function setFFFeeSink(Currency[] calldata settleFirst, address sink) external restricted nonReentrant {
        _settleSinks(settleFirst);
        if (sink != address(0) && (sink == distributor || sink == claimFeeRecipient || sink == address(this))) {
            revert InvalidSink();
        }
        _checkSinkTarget(sink);
        ffFeeSink = sink;
        emit FFFeeSinkSet(sink);
    }

    /// @dev Refuses this hook and the PoolManager as payout targets (a `take` to either loses the funds). Another
    ///      native Fables hook as `to` is not detected and would keep the ETH.
    function _checkPayoutTarget(address to) internal view {
        if (to == address(this) || to == address(poolManager)) revert InvalidSink();
    }

    function _checkSinkTarget(address sink) internal view {
        if (sink == address(poolManager)) revert InvalidSink();
    }

    function _settleSinks(Currency[] calldata currencies) internal {
        for (uint256 i = 0; i < currencies.length; i++) {
            _sweepDistributor(currencies[i]);
            _sweepClaimFee(currencies[i]);
        }
    }

    /// @notice Sets the distributor of staked shares' fees (zero clears it), after sweeping `settleFirst` currencies.
    function setDistributor(Currency[] calldata settleFirst, address distributor_) external restricted nonReentrant {
        _settleSinks(settleFirst);
        _checkSinkTarget(distributor_);
        distributorFF = LedgerLibV2.validateDistributor(distributor_, ffFeeSink, claimFeeRecipient);
        distributor = distributor_;
        emit DistributorSet(distributor_);
    }

    /// @notice Pauses for `duration` seconds, or lifts the pause when `duration` is zero.
    function setPaused(uint256 duration) external restricted {
        if (duration > MAX_PAUSE) revert PauseTooLong();
        pausedUntil = duration == 0 ? 0 : block.timestamp + duration;
        emit PausedSet(pausedUntil);
    }

    /// @notice Freezes the ledger for `duration` seconds; can only extend a running pause, never lift or shorten it.
    function pause(uint256 duration) external restricted {
        if (duration == 0 || duration > MAX_PAUSE) revert PauseTooLong();
        uint256 until_ = block.timestamp + duration;
        if (until_ <= pausedUntil) revert PauseTooLong(); // never shortens a running freeze
        pausedUntil = until_;
        emit PausedSet(until_);
    }

    /// @notice Pauses one pool for `duration` seconds, or lifts that pool's own pause when zero.
    function setPoolPaused(PoolKey calldata key, uint256 duration) external restricted {
        if (duration > MAX_PAUSE) revert PauseTooLong();
        _checkKey(key);
        PoolId poolId = key.toId();
        uint256 until_ = duration == 0 ? 0 : block.timestamp + duration;
        pausedUntilOf[poolId] = until_;
        emit PoolPausedSet(poolId, until_);
    }

    /// @notice Freezes one pool; like `pause`, can only extend a running pool pause.
    function pausePool(PoolKey calldata key, uint256 duration) external restricted {
        if (duration == 0 || duration > MAX_PAUSE) revert PauseTooLong();
        _checkKey(key);
        PoolId poolId = key.toId();
        uint256 until_ = block.timestamp + duration;
        if (until_ <= pausedUntilOf[poolId]) revert PauseTooLong(); // never shortens a running freeze
        pausedUntilOf[poolId] = until_;
        emit PoolPausedSet(poolId, until_);
    }

    /// @dev Configured pools of this hook only (so `callerDelta - feesAccrued` is principal); native only if allowed.
    function _checkKey(PoolKey calldata key) internal view {
        if (address(key.hooks) != address(this) || maxFee[key.toId()] == 0) revert PoolNotConfigured();
        if (key.currency0.isAddressZero() && !_nativeAllowed()) revert NativeNotSupported();
    }

    /// @dev Collects v4's accrued fees before any share or stake change; idle ranges only roll the claim-fee index.
    function _syncRange(uint256 id) internal {
        RangeKey memory descriptor = _rangeKeys[id];
        if (!descriptor.set || _ranges[id].totalShares == 0) {
            claimFeeSyncIndex[id] = uint64(_poolClaimFee[descriptor.key.toId()].history.length);
            return;
        }
        if (_isJit()) {
            (uint128 fee0, uint128 fee1, uint256 growth0X128, uint256 growth1X128) = _jitSync(id);
            _creditFees(id, descriptor.key, fee0, fee1, growth0X128, growth1X128);
            return;
        }
        _modifyMem(
            descriptor.key,
            descriptor.tickLower,
            descriptor.tickUpper,
            0,
            address(this),
            type(uint128).max,
            type(uint128).max
        );
    }

    /// @dev JIT extension point: false here, so every `_isJit()` branch compiles away; the `_jit*` defaults revert.
    function _isJit() internal pure virtual returns (bool) {
        return false;
    }

    function _jitSync(uint256) internal virtual returns (uint128, uint128, uint256, uint256) {
        revert NotJitHook();
    }

    function _jitDeposit(PoolKey calldata, uint256, uint128, uint128, uint128) internal virtual {
        revert NotJitHook();
    }

    function _jitWithdraw(PoolKey calldata, uint256, uint128, uint128, uint128, address) internal virtual {
        revert NotJitHook();
    }

    function _jitRangeGrowth(uint256) internal view virtual returns (uint256, uint256) {
        revert NotJitHook();
    }

    function _jitUnlock(bytes calldata) internal virtual returns (bytes memory) {
        revert NotJitHook();
    }

    /// @notice Adds `liquidity` units to the range's position and mints as many receipts to the caller.
    /// @param amount0Max Most currency0 the caller pays; on a native pool `msg.value` must be at least this.
    /// @dev On native pools the unspent `msg.value` is refunded by a call that reverts on failure.
    // slither-disable-next-line reentrancy-no-eth
    function deposit(
        PoolKey calldata key,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        uint128 amount0Max,
        uint128 amount1Max,
        uint256 deadline
    ) external payable nonReentrant whenPoolNotPaused(key.toId()) {
        if (liquidity == 0) revert ZeroLiquidity();
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp > deadline) revert DeadlineExpired();
        _checkKey(key);
        if (key.currency0.isAddressZero()) {
            if (msg.value < amount0Max) revert InvalidMsgValue();
            _setForeignNative(address(this).balance - msg.value);
        } else if (msg.value != 0) {
            revert InvalidMsgValue();
        }

        uint256 id = rangeId(key.toId(), tickLower, tickUpper);
        if (!_rangeKeys[id].set) {
            _rangeKeys[id] = RangeKey({key: key, tickLower: tickLower, tickUpper: tickUpper, set: true});
        }
        // sync and book before the pool touch, the only step that can reach a token
        _syncRange(id);
        _settleUser(id, msg.sender);
        bool recreated = _ranges[id].totalShares == 0;
        if (recreated) _ranges[id].resetSeq += 1;
        _ranges[id].totalShares += liquidity;
        _mint(msg.sender, id, liquidity);
        if (_isJit()) _jitDeposit(key, id, liquidity, amount0Max, amount1Max);
        else _modify(key, tickLower, tickUpper, int256(uint256(liquidity)), msg.sender, amount0Max, amount1Max);
        if (recreated) _emitRebaseBaseline(id);
        emit Deposited(msg.sender, id, liquidity);
        // last: the refund hands control to the caller
        if (key.currency0.isAddressZero()) _refundNative();
    }

    function _emitRebaseBaseline(uint256 id) internal {
        if (_isJit()) {
            (uint256 growth0X128, uint256 growth1X128) = _jitRangeGrowth(id);
            LedgerLibV2.emitRebaseBaseline(_ranges, _rangeKeys, poolManager, id, true, growth0X128, growth1X128);
        } else {
            LedgerLibV2.emitRebaseBaseline(_ranges, _rangeKeys, poolManager, id, false, 0, 0);
        }
    }

    /// @dev Pays `msg.sender` this call's unspent `msg.value` (the balance delta); force-sent ETH strands.
    // slither-disable-next-line arbitrary-send-eth
    function _refundNative() internal {
        uint256 pre = _foreignNative();
        uint256 balance = address(this).balance;
        uint256 refund = balance > pre ? balance - pre : 0;
        if (refund == 0) return;
        (bool success,) = msg.sender.call{value: refund}("");
        if (!success) revert RefundFailed();
    }

    /// @dev Transient slot: the hook's native balance before the current `deposit`.
    bytes32 private constant _FOREIGN_NATIVE_SLOT = keccak256("fables.ledger.foreignNative");

    function _setForeignNative(uint256 value) private {
        bytes32 slot = _FOREIGN_NATIVE_SLOT;
        assembly ("memory-safe") {
            tstore(slot, value)
        }
    }

    function _foreignNative() private view returns (uint256 value) {
        bytes32 slot = _FOREIGN_NATIVE_SLOT;
        assembly ("memory-safe") {
            value := tload(slot)
        }
    }

    /// @notice Burns `liquidity` receipts and pays the principal to `to`, auto-unstaking if needed.
    /// @dev Never pausable. Fees are synced and credited, not paid.
    // slither-disable-next-line reentrancy-no-eth
    function withdraw(
        PoolKey calldata key,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        address to,
        uint128 amount0Min,
        uint128 amount1Min,
        uint256 deadline
    ) external nonReentrant {
        _withdrawTo(key, tickLower, tickUpper, liquidity, to, amount0Min, amount1Min, deadline);
    }

    /// @notice `withdraw` plus payout of the caller's accrued fees to `to`, in one call.
    /// @param maxFeeBps Highest claim-fee rate the caller accepts (10_000 = no bound).
    /// @dev Unlike `withdraw`, pausable, and reverts on the bound or a failed fee transfer.
    function withdrawAndClaim(
        PoolKey calldata key,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        address to,
        uint128 amount0Min,
        uint128 amount1Min,
        uint256 deadline,
        uint16 maxFeeBps
    ) external nonReentrant whenPoolNotPaused(key.toId()) {
        uint256 id = rangeId(key.toId(), tickLower, tickUpper);
        if (_effectiveClaimFee(id) > maxFeeBps) revert ClaimFeeAboveMax();

        _withdrawTo(key, tickLower, tickUpper, liquidity, to, amount0Min, amount1Min, deadline);

        UserPosition storage position = _positions[id][msg.sender];
        (uint256 amount0, uint256 amount1) = (position.owed0, position.owed1);
        if (amount0 == 0 && amount1 == 0) return; // fully staked, or nothing accrued: not an error
        (position.owed0, position.owed1) = (0, 0);
        _payout(key.currency0, key.currency1, amount0, amount1, to);
        emit FeesClaimed(msg.sender, id, amount0, amount1);
    }

    function _withdrawTo(
        PoolKey calldata key,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        address to,
        uint128 amount0Min,
        uint128 amount1Min,
        uint256 deadline
    ) internal {
        if (liquidity == 0) revert ZeroLiquidity();
        if (to == address(0)) revert ZeroAddress();
        _checkPayoutTarget(to);
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp > deadline) revert DeadlineExpired();
        _checkKey(key);
        uint256 id = rangeId(key.toId(), tickLower, tickUpper);

        _syncRange(id);
        _settleUser(id, msg.sender);

        UserPosition storage position = _positions[id][msg.sender];
        // balances are sums of uint128 liquidity mints, bounded by pool max liquidity
        // forge-lint: disable-next-line(unsafe-typecast)
        uint128 unstaked = uint128(balanceOf[msg.sender][id]) - position.staked;
        if (unstaked < liquidity) {
            uint128 fromStaked = liquidity - unstaked;
            position.staked -= fromStaked; // reverts on underflow: not enough total shares
            _ranges[id].totalStaked -= fromStaked;
            emit Unstaked(msg.sender, id, fromStaked);
        }
        _burn(msg.sender, id, liquidity);
        _ranges[id].totalShares -= liquidity;
        if (_ranges[id].totalShares == 0) _ranges[id].resetSeq += 1;
        if (_isJit()) _jitWithdraw(key, id, liquidity, amount0Min, amount1Min, to);
        else _modify(key, tickLower, tickUpper, -int256(uint256(liquidity)), to, amount0Min, amount1Min);
        emit Withdrawn(msg.sender, id, liquidity);
    }

    /// @notice Syncs the range and pays the caller's accrued fees (net of the claim fee) to `to`.
    /// @param maxFeeBps Highest claim-fee rate the caller accepts (10_000 = no bound).
    // slither-disable-next-line reentrancy-no-eth
    function claimFees(PoolKey calldata key, int24 tickLower, int24 tickUpper, address to, uint16 maxFeeBps)
        external
        nonReentrant
        whenPoolNotPaused(key.toId())
    {
        // a native `take` to address(0) succeeds and burns the fees
        if (to == address(0)) revert ZeroAddress();
        _checkPayoutTarget(to);
        _checkKey(key);
        uint256 id = rangeId(key.toId(), tickLower, tickUpper);
        if (_effectiveClaimFee(id) > maxFeeBps) revert ClaimFeeAboveMax();
        // no free sync for strangers; a holder who withdrew can still claim what is owed
        UserPosition storage claimant = _positions[id][msg.sender];
        if (balanceOf[msg.sender][id] == 0 && claimant.owed0 == 0 && claimant.owed1 == 0) {
            revert NothingToClaim();
        }
        _syncRange(id);
        _settleUser(id, msg.sender);

        UserPosition storage position = _positions[id][msg.sender];
        (uint256 amount0, uint256 amount1) = (position.owed0, position.owed1);
        if (amount0 == 0 && amount1 == 0) return;
        (position.owed0, position.owed1) = (0, 0);

        _payout(key.currency0, key.currency1, amount0, amount1, to);
        emit FeesClaimed(msg.sender, id, amount0, amount1);
    }

    /// @notice Stakes unstaked receipts: their future fees route to the distributor (voters) instead of the holder.
    /// @param minGaugeWeight Least gauge weight the caller accepts; 0 = no bound.
    /// @dev Requires a ballot gate reporting the pool's gauge as earning; both checks run at entry only.
    // slither-disable-next-line reentrancy-no-eth
    function stake(PoolKey calldata key, int24 tickLower, int24 tickUpper, uint128 shares, uint256 minGaugeWeight)
        external
        nonReentrant
        whenPoolNotPaused(key.toId())
    {
        if (shares == 0) revert ZeroShares();
        _checkKey(key);
        // fails closed: with no gate, or a gauge that earns nothing, the forgone fees would strand
        address gate = ballotGate;
        if (gate == address(0) || !IBallotGate(gate).isGaugeEarning(key.toId())) revert GaugeNotEarning();
        if (minGaugeWeight != 0 && IBallotGate(gate).gaugeWeightNow(key.toId()) < minGaugeWeight) {
            revert GaugeBelowMinWeight();
        }
        uint256 id = rangeId(key.toId(), tickLower, tickUpper);
        _syncRange(id); // fees earned before this stake stay with their earner
        _settleUser(id, msg.sender);
        UserPosition storage position = _positions[id][msg.sender];
        if (uint128(balanceOf[msg.sender][id]) - position.staked < shares) revert InsufficientUnstakedShares();
        position.staked += shares;
        _ranges[id].totalStaked += shares;
        emit Staked(msg.sender, id, shares);
    }

    /// @notice Unstakes receipts; never pausable, so a holder can always stop routing fees to the distributor.
    // slither-disable-next-line reentrancy-no-eth
    function unstake(PoolKey calldata key, int24 tickLower, int24 tickUpper, uint128 shares) external nonReentrant {
        // zero shares would be a free, unpausable fee sync
        if (shares == 0) revert ZeroShares();
        _checkKey(key);
        uint256 id = rangeId(key.toId(), tickLower, tickUpper);
        _syncRange(id); // fees owed to the distributor are banked before the stake shrinks
        _settleUser(id, msg.sender);
        UserPosition storage position = _positions[id][msg.sender];
        position.staked -= shares; // reverts on underflow
        _ranges[id].totalStaked -= shares;
        emit Unstaked(msg.sender, id, shares);
    }

    /// @notice Pushes accumulated staked-share fees to the distributor. Callable by anyone.
    function sweepDistributor(Currency currency) external nonReentrant whenNotPaused {
        _sweepDistributor(currency);
    }

    function _sweepDistributor(Currency currency) internal virtual {
        LedgerLibV2.sweepDistributor(distributorOwed, poolManager, currency, distributor, distributorFF, ffFeeSink);
    }

    /// @dev Staked shares are locked: only the unstaked balance is transferable.
    function transfer(address receiver, uint256 id, uint256 amount)
        public
        override
        nonReentrant
        whenRangeNotPaused(id)
        returns (bool)
    {
        // a zero-amount transfer would be a free fee sync
        if (amount == 0) revert ZeroShares();
        _checkTransferable(msg.sender, id, amount);
        _syncRange(id); // the sender keeps the fees their shares already earned
        _settleUser(id, msg.sender);
        _settleUser(id, receiver);
        return super.transfer(receiver, id, amount);
    }

    function transferFrom(address sender, address receiver, uint256 id, uint256 amount)
        public
        override
        nonReentrant
        whenRangeNotPaused(id)
        returns (bool)
    {
        // a zero-amount transfer would be a free fee sync
        if (amount == 0) revert ZeroShares();
        _checkTransferable(sender, id, amount);
        _syncRange(id); // the sender keeps the fees their shares already earned
        _settleUser(id, sender);
        _settleUser(id, receiver);
        // authorization (owner, operator or allowance) is enforced by ERC6909.transferFrom
        // nosemgrep: solidity.security.arbitrary-send-erc20.arbitrary-send-erc20
        return super.transferFrom(sender, receiver, id, amount);
    }

    function _checkTransferable(address owner, uint256 id, uint256 amount) internal view {
        if (balanceOf[owner][id] - _positions[id][owner].staked < amount) revert InsufficientUnstakedShares();
    }

    function _modify(
        PoolKey calldata key,
        int24 tickLower,
        int24 tickUpper,
        int256 liquidityDelta,
        address user,
        uint128 amount0Limit,
        uint128 amount1Limit
    ) internal {
        _modifyMem(key, tickLower, tickUpper, liquidityDelta, user, amount0Limit, amount1Limit);
    }

    function _modifyMem(
        PoolKey memory key,
        int24 tickLower,
        int24 tickUpper,
        int256 liquidityDelta,
        address user,
        uint128 amount0Limit,
        uint128 amount1Limit
    ) internal {
        poolManager.unlock(
            abi.encode(
                Action.MODIFY,
                abi.encode(CallbackData(key, tickLower, tickUpper, liquidityDelta, user, amount0Limit, amount1Limit))
            )
        );
    }

    function _payout(Currency currency0, Currency currency1, uint256 amount0, uint256 amount1, address to) internal {
        LedgerLibV2.payout(poolManager, currency0, currency1, amount0, amount1, to);
    }

    /// @inheritdoc IUnlockCallback
    /// @dev PoolManager only. Runs `_jitUnlock` for a JIT action, else `LedgerLibV2.onUnlock` (modify or payout).
    function unlockCallback(bytes calldata rawData) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        // only this contract opens unlocks that call back here, so the envelope is self-produced
        if (_isJit()) {
            (bool isJitAction, bytes calldata payload) = _jitEnvelope(rawData);
            if (isJitAction) return _jitUnlock(payload);
        }
        return LedgerLibV2.onUnlock(
            _ranges,
            _rangeKeys,
            distributorOwed,
            claimFeeOwed,
            claimFeeSyncIndex,
            _poolClaimFee,
            poolManager,
            LedgerLibV2.ClaimFeeState({recipient: claimFeeRecipient}),
            rawData
        );
    }

    function _jitEnvelope(bytes calldata rawData) private pure returns (bool, bytes calldata) {
        if (uint256(bytes32(rawData[:32])) != uint256(Action.JIT)) return (false, rawData[:0]);
        uint256 offset = uint256(bytes32(rawData[32:64]));
        uint256 length = uint256(bytes32(rawData[offset:offset + 32]));
        return (true, rawData[offset + 32:offset + 32 + length]);
    }

    function _creditFees(
        uint256 id,
        PoolKey memory key,
        uint128 fee0,
        uint128 fee1,
        uint256 growth0X128,
        uint256 growth1X128
    ) internal {
        LedgerLibV2.creditFees(
            _ranges,
            _rangeKeys,
            distributorOwed,
            claimFeeOwed,
            claimFeeSyncIndex,
            _poolClaimFee,
            poolManager,
            LedgerLibV2.CreditParams({id: id, key: key, fee0: fee0, fee1: fee1, claimFeeRecipient: claimFeeRecipient}),
            true,
            growth0X128,
            growth1X128
        );
    }

    /// @notice Syncs staked ranges of pools the ballot gate admits the caller for with `tokenId`; never pausable.
    function syncRanges(uint256 tokenId, uint256[] calldata ids) external nonReentrant {
        address gate = ballotGate;
        if (gate == address(0)) revert BallotGateUnset();
        for (uint256 i = 0; i < ids.length; i++) {
            uint256 id = ids[i];
            if (_ranges[id].totalStaked == 0) continue;
            if (!IBallotGate(gate).ballotBacks(msg.sender, tokenId, _rangeKeys[id].key.toId())) {
                revert NotAVoterOfThisPool();
            }
            _syncRange(id);
        }
    }

    /// @notice Sets the Voter gate for `stake` and `syncRanges`; zero closes both.
    /// @dev A non-zero gate must answer `ballotBacks`, `isGaugeEarning` and `gaugeWeightNow`, and its `ve()` escrow
    ///      must name it as `voter()`.
    function setBallotGate(address gate) external restricted {
        if (gate != address(0)) {
            // code checks first: try/catch cannot catch the decode revert on an EOA
            if (gate.code.length == 0) revert InvalidBallotGate();
            try IBallotGate(gate).ballotBacks(address(this), 0, PoolId.wrap(bytes32(0))) returns (bool) {}
            catch {
                revert InvalidBallotGate();
            }
            try IBallotGate(gate).isGaugeEarning(PoolId.wrap(bytes32(0))) returns (bool) {}
            catch {
                revert InvalidBallotGate();
            }
            try IBallotGate(gate).gaugeWeightNow(PoolId.wrap(bytes32(0))) returns (uint256) {}
            catch {
                revert InvalidBallotGate();
            }
            try IBallotGate(gate).ve() returns (address escrow) {
                if (escrow == address(0) || escrow.code.length == 0) revert InvalidBallotGate();
                // raw staticcall: an empty return would revert in the decode, past the catch
                (bool ok, bytes memory ret) = escrow.staticcall(abi.encodeWithSignature("voter()"));
                if (!ok || ret.length < 32 || abi.decode(ret, (address)) != gate) revert InvalidBallotGate();
            } catch {
                revert InvalidBallotGate();
            }
        }
        ballotGate = gate;
        emit BallotGateSet(gate);
    }

    function _effectiveClaimFee(uint256 id) internal view returns (uint16) {
        RangeState storage range = _ranges[id];
        if (range.totalStaked == range.totalShares) return 0;
        return claimFeeFor(_rangeKeys[id].key.toId(), claimFeeSyncIndex[id]);
    }

    /// @notice The rate charged on a backlog that opened at history index `sinceIndex`: the lowest rate in force
    ///         since then (zero while no recipient). A cut applies to the whole backlog; a raise only to later ones.
    /// @dev Walks at most MAX_CLAIM_FEE_WALK entries, then uses the all-time minimum. Anyone can force a sync, so a
    ///      backlog can be priced just before a public cut.
    function claimFeeFor(PoolId poolId, uint64 sinceIndex) public view returns (uint16) {
        PoolClaimFee storage pcf = _poolClaimFee[poolId];
        return LedgerLibV2.claimFeeFor(pcf.history, sinceIndex, claimFeeRecipient, pcf.bps, pcf.allTimeMin);
    }

    /// @notice This pool's current claim-fee rate.
    function claimFeeBps(PoolId poolId) external view returns (uint16) {
        return _poolClaimFee[poolId].bps;
    }

    /// @notice The lowest rate this pool has ever stood at (the bounded walk's fallback).
    function claimFeeAllTimeMin(PoolId poolId) external view returns (uint16) {
        return _poolClaimFee[poolId].allTimeMin;
    }

    /// @notice Number of recorded claim-fee changes for a pool.
    function claimFeeHistoryLength(PoolId poolId) external view returns (uint256) {
        return _poolClaimFee[poolId].history.length;
    }

    /// @notice One recorded claim-fee change.
    function claimFeeChangeAt(PoolId poolId, uint256 index) external view returns (ClaimFeeChange memory) {
        return _poolClaimFee[poolId].history[index];
    }

    /// @notice The rate a range's current backlog will be charged if it is synced now.
    /// @dev Can rise between blocks (e.g. another holder unstakes); read it in the same transaction.
    function effectiveClaimFee(uint256 id) external view returns (uint16) {
        return _effectiveClaimFee(id);
    }

    function _settleUser(uint256 id, address owner) internal {
        LedgerLibV2.settleUser(_ranges[id], _positions[id][owner], balanceOf[owner][id], owner, id);
    }

    /// @notice Pushes accrued claim-fee revenue to the recipient. Callable by anyone.
    function sweepClaimFee(Currency currency) external nonReentrant whenNotPaused {
        _sweepClaimFee(currency);
    }

    function _sweepClaimFee(Currency currency) internal virtual {
        LedgerLibV2.sweepClaimFee(claimFeeOwed, poolManager, currency, claimFeeRecipient);
    }
}
