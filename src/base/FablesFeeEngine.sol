// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {FablesHookCore} from "./FablesHookCore.sol";
import {PoolWordLib} from "../libraries/PoolWordLib.sol";
import {DiscountLib} from "../libraries/DiscountLib.sol";
import {FeeRef} from "../libraries/FeeRef.sol";

/// @title FablesFeeEngine
/// @notice Per-pool fee configuration: categories, pools, pokes, whitelist discounts and the continuation fee (CF).
/// @dev Fees in pips. Each pool's fee config sits in one word (PoolWordLib); bounds are validated at write and clamped
///      at read (FeeRef). `maxFee` mirrors the pool cap and never returns to 0.
abstract contract FablesFeeEngine is FablesHookCore {
    using PoolWordLib for uint256;
    using PoolIdLibrary for PoolKey;
    using LPFeeLibrary for uint24;
    using StateLibrary for IPoolManager;

    error NotDynamicFeePool();
    error InvalidCategory();
    error InvalidConfig();
    error EmptyPoke();
    error FeeAboveCap();
    error FeeBelowFloor();
    error InvalidTtl();
    error RaiseTooLarge();
    error RaiseTooSoon();
    error InvalidDiscount();
    error InvalidSeed();
    error InvalidCF();
    error CFNotConfigured();
    /// @notice `configureCF` while the CF is on: switch it off first.
    error CFActive();
    error PoolNotInitialized();
    error SymmetricRequired();
    error ModuleNotAvailable();
    /// @notice Pools are created only through `initializePool`.
    error InvalidInitializer(address caller);

    event CategorySet(uint8 indexed id, uint24 floorMin, uint24 capMax, uint24 raiseStep, string label);
    event PoolFeeConfigured(
        PoolId indexed poolId, uint8 category, uint24 base0, uint24 base1, uint24 floor, uint24 cap
    );
    event FeePoked(PoolId indexed poolId, uint24 fee0For1, uint24 fee1For0, uint40 expiry);
    event PokeCleared(PoolId indexed poolId);
    event DiscountSet(
        PoolId indexed poolId, address indexed account, uint16 bps, uint24 minFee, uint8 dirs, uint40 expiry
    );
    event DiscountRevoked(PoolId indexed poolId, address indexed account);
    event DiscountFilterSet(PoolId indexed poolId, uint8 seed, uint64 bloom);
    event CFConfigured(
        PoolId indexed poolId, uint8 mode, uint16 kQ8, uint24 cfCap, uint16 band16, uint16 tau, uint8 period
    );
    event CFActiveSet(PoolId indexed poolId, bool on);
    event CFKilled(PoolId indexed poolId);

    struct Category {
        uint24 floorMin;
        uint24 capMax;
        uint24 raiseStep;
        bool exists;
    }

    struct Meta {
        uint8 category;
        uint40 lastRaiseAt;
    }

    /// @notice Hard ceiling on any pool cap: 10%.
    uint24 public constant ABSOLUTE_MAX_FEE = 100_000;
    uint24 public constant MIN_POOL_FEE = 0;
    uint40 public constant MAX_POKE_TTL = 72 hours;
    /// @notice Max cut a poke may apply to min(base, cap), in bps.
    uint16 public constant MAX_POKE_DISCOUNT_BPS = 5_000;
    /// @notice Min seconds between two raising pokes on a pool.
    uint40 public constant RAISE_INTERVAL = 60;
    uint16 public constant MAX_DISCOUNT_BPS = 5_000;
    uint40 public constant MAX_DISCOUNT_TERM = 90 days;
    /// @notice CF bounds: slope <= 1.0 (Q8), surcharge <= 25 bp, dead band <= 50 bp (1/16 tick), tau 5..300 s,
    ///         update period 1..60 s and below maxAge = min(255, 5 * tau) seconds.
    uint16 public constant MAX_CF_K_Q8 = 256;
    uint24 public constant MAX_CF_CAP = 2_500;
    uint16 public constant MAX_CF_BAND16 = 800;
    uint16 public constant MIN_CF_TAU = 5;
    uint16 public constant MAX_CF_TAU = 300;
    uint8 public constant MAX_CF_PERIOD = 60;
    uint8 public constant MAX_CF_AGE = 255;

    /// @dev Pool word (PoolWordLib layout); read on every swap.
    mapping(PoolId poolId => uint256 word) internal _word;
    mapping(PoolId poolId => uint256 cf) internal _cf;
    mapping(PoolId poolId => mapping(address account => uint256 entry)) internal _entry;
    mapping(uint8 id => Category category) internal _categories;
    mapping(PoolId poolId => Meta meta) internal _meta;

    constructor(IPoolManager poolManager_, address authority_) FablesHookCore(poolManager_, authority_) {
        Hooks.validateHookPermissions(IHooks(address(this)), _hookPermissions());
    }

    function _hookPermissions() internal pure virtual returns (Hooks.Permissions memory permissions) {
        permissions.beforeInitialize = true;
    }

    // override points: no-ops here, with discounts and the CF enabled
    function _onFeeWrite(PoolId poolId) internal virtual {}

    function _beforeKeeperWrite(PoolId poolId) internal virtual {}

    function _onInitialize(PoolId poolId, PoolKey calldata key) internal virtual {}

    function _requireSymmetric(uint24 side0, uint24 side1) internal pure virtual {}

    function _swapModulesEnabled() internal pure virtual returns (bool) {
        return true;
    }

    function _requireSwapModules() internal pure {
        if (!_swapModulesEnabled()) revert ModuleNotAvailable();
    }

    /// @notice Admits only the hook itself; v4 skips the hook on its own call, so every outside initializer reverts.
    function beforeInitialize(address sender, PoolKey calldata, uint160)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        if (sender != address(this)) revert InvalidInitializer(sender);
        return IHooks.beforeInitialize.selector;
    }

    /// @notice Initializes a configured pool at `sqrtPriceX96`; native currency0 only on native-capable builds.
    /// @dev `configurePool` admits only this hook's dynamic-fee keys, so a configured id implies both.
    function initializePool(PoolKey calldata key, uint160 sqrtPriceX96) external restricted {
        PoolId id = key.toId();
        if (maxFee[id] == 0) revert PoolNotConfigured();
        if (key.currency0.isAddressZero() && !_nativeAllowed()) revert NativeNotSupported();
        poolManager.initialize(key, sqrtPriceX96);
        _onInitialize(id, key);
    }

    /// @notice Creates or updates a fee category.
    /// @dev Pools already in the category keep their stored bounds until reconfigured.
    function setCategory(uint8 id, uint24 floorMin, uint24 capMax, uint24 raiseStep, string calldata label)
        external
        restricted
    {
        if (capMax > ABSOLUTE_MAX_FEE || floorMin > capMax || raiseStep == 0) revert InvalidCategory();
        _categories[id] = Category({floorMin: floorMin, capMax: capMax, raiseStep: raiseStep, exists: true});
        emit CategorySet(id, floorMin, capMax, raiseStep, label);
    }

    /// @notice Configures a pool's category, per-direction base fees, floor and cap.
    /// @dev Requires floorMin <= floor <= min(bases), max(bases) <= cap <= capMax and cap >= 1; pokes, filter and CF
    ///      state are kept.
    function configurePool(PoolKey calldata key, uint8 categoryId, uint24 base0, uint24 base1, uint24 floor, uint24 cap)
        external
        restricted
    {
        if (address(key.hooks) != address(this)) revert PoolNotConfigured();
        if (!key.fee.isDynamicFee()) revert NotDynamicFeePool();
        Category storage c = _categories[categoryId];
        if (!c.exists) revert InvalidCategory();
        _requireSymmetric(base0, base1);
        uint24 lo = base0 < base1 ? base0 : base1;
        uint24 hi = base0 < base1 ? base1 : base0;
        if (cap == 0 || cap > c.capMax || hi > cap) revert InvalidConfig();
        if (floor < c.floorMin || floor > lo) revert InvalidConfig();
        PoolId id = key.toId();
        _word[id] = _word[id].withBases(base0, base1).withBounds(floor, cap);
        _meta[id].category = categoryId;
        maxFee[id] = cap;
        emit PoolFeeConfigured(id, categoryId, base0, base1, floor, cap);
        _onFeeWrite(id);
    }

    /// @notice Pokes both directions' fees for `ttl` seconds; a zero side stays on its base.
    /// @dev Each non-zero side must lie in [floor, min(cap, capMax)], 1 <= ttl <= 72 h. A resolved fee may rise by at
    ///      most the category's raiseStep, once per RAISE_INTERVAL per pool; cuts are unlimited.
    function pokeFee(PoolId poolId, uint24 fee0For1, uint24 fee1For0, uint40 ttl) external restricted {
        _beforeKeeperWrite(poolId);
        uint256 w = _word[poolId];
        uint256 cap = w.cap();
        if (cap == 0) revert PoolNotConfigured();
        if (fee0For1 == 0 && fee1For0 == 0) revert EmptyPoke();
        _requireSymmetric(fee0For1, fee1For0);
        if (ttl == 0 || ttl > MAX_POKE_TTL) revert InvalidTtl();
        Meta memory meta = _meta[poolId];
        Category storage c = _categories[meta.category];
        {
            uint256 ceiling = cap < c.capMax ? cap : c.capMax;
            uint256 floor = w.floor();
            if (fee0For1 != 0) {
                if (fee0For1 > ceiling) revert FeeAboveCap();
                if (fee0For1 < floor) revert FeeBelowFloor();
            }
            if (fee1For0 != 0) {
                if (fee1For0 > ceiling) revert FeeAboveCap();
                if (fee1For0 < floor) revert FeeBelowFloor();
            }
        }
        // safe: ttl <= 72 h and block.timestamp < 2^40
        // forge-lint: disable-next-line(unsafe-typecast)
        uint40 expiry = uint40(block.timestamp) + ttl;
        uint256 wNew = w.withPokes(fee0For1, fee1For0, expiry);
        // no short-circuit: each side must pass the step check
        bool raises0 = _raises(w, wNew, true, c.raiseStep);
        bool raises1 = _raises(w, wNew, false, c.raiseStep);
        if (raises0 || raises1) {
            // forge-lint: disable-next-line(block-timestamp)
            if (block.timestamp < uint256(meta.lastRaiseAt) + RAISE_INTERVAL) revert RaiseTooSoon();
            // forge-lint: disable-next-line(unsafe-typecast)
            _meta[poolId].lastRaiseAt = uint40(block.timestamp);
        }
        _word[poolId] = wNew;
        emit FeePoked(poolId, fee0For1, fee1For0, expiry);
        _onFeeWrite(poolId);
    }

    function _raises(uint256 wOld, uint256 wNew, bool zeroForOne, uint24 raiseStep) internal view returns (bool) {
        uint256 before = FeeRef.keeperFee(wOld, zeroForOne, block.timestamp);
        uint256 after_ = FeeRef.keeperFee(wNew, zeroForOne, block.timestamp);
        if (after_ <= before) return false;
        if (after_ - before > raiseStep) revert RaiseTooLarge();
        return true;
    }

    /// @notice Clears both pokes; the pool returns to its bases.
    function clearPoke(PoolId poolId) external restricted {
        _beforeKeeperWrite(poolId);
        uint256 w = _word[poolId];
        if (w.cap() == 0) revert PoolNotConfigured();
        _word[poolId] = w.withPokesCleared();
        emit PokeCleared(poolId);
        _onFeeWrite(poolId);
    }

    /// @notice Sets (bps > 0) or deletes (bps == 0) `account`'s swap discount on each listed pool.
    /// @param dirs Discounted directions: 1 zeroForOne, 2 oneForZero, 3 both.
    function setDiscount(PoolId[] calldata ids, address account, uint16 bps, uint24 minFee, uint8 dirs, uint40 expiry)
        external
        restricted
    {
        _requireSwapModules();
        if (account == address(0) || bps > MAX_DISCOUNT_BPS) revert InvalidDiscount();
        if (bps != 0) {
            if (dirs == 0 || dirs > DiscountLib.DIR_BOTH) revert InvalidDiscount();
            // forge-lint: disable-next-line(block-timestamp)
            if (expiry <= block.timestamp || expiry > block.timestamp + MAX_DISCOUNT_TERM) revert InvalidDiscount();
        }
        for (uint256 i = 0; i < ids.length; ++i) {
            PoolId id = ids[i];
            uint256 w = _word[id];
            if (w.cap() == 0) revert PoolNotConfigured();
            if (bps == 0) {
                delete _entry[id][account];
                emit DiscountSet(id, account, 0, 0, 0, 0);
            } else {
                _entry[id][account] = DiscountLib.pack(bps, minFee, dirs, expiry);
                _word[id] = w.withBloom(w.bloom() | DiscountLib.mask64(account, w.seed()));
                emit DiscountSet(id, account, bps, minFee, dirs, expiry);
            }
        }
    }

    /// @notice Deletes the listed accounts' discounts on the listed pools.
    /// @dev The Bloom filter is left as is: a stale bit costs one SLOAD, never a discount.
    function revokeDiscount(PoolId[] calldata ids, address[] calldata accounts) external restricted {
        _requireSwapModules();
        for (uint256 i = 0; i < ids.length; ++i) {
            PoolId id = ids[i];
            if (_word[id].cap() == 0) revert PoolNotConfigured();
            for (uint256 j = 0; j < accounts.length; ++j) {
                delete _entry[id][accounts[j]];
                emit DiscountRevoked(id, accounts[j]);
            }
        }
    }

    /// @notice Re-seeds a pool's Bloom filter and rebuilds it from the listed accounts that hold an entry.
    /// @dev Pre-filter only: an omitted account keeps its entry (and may still hit); `revokeDiscount` removes it.
    function setDiscountFilter(PoolId poolId, uint8 seed, address[] calldata accounts) external restricted {
        _requireSwapModules();
        if (seed > PoolWordLib.MASK7) revert InvalidSeed();
        uint256 w = _word[poolId];
        if (w.cap() == 0) revert PoolNotConfigured();
        uint64 bloom;
        for (uint256 i = 0; i < accounts.length; ++i) {
            if (_entry[poolId][accounts[i]] != 0) bloom |= DiscountLib.mask64(accounts[i], seed);
        }
        _word[poolId] = w.withBloom(bloom).withSeed(seed);
        emit DiscountFilterSet(poolId, seed, bloom);
    }

    /// @notice Sets a pool's CF parameters and anchors it at the current tick; does not switch it on.
    /// @param mode 0 = continuation, 1 = reverse.
    /// @dev kQ8 and cfCap must be non-zero (kQ8 == 0 is the killed state). Reverts `CFActive` while on, so the anchor
    ///      cannot be picked by moving the price first; `setCFActive(true)` re-anchors at its own tick.
    function configureCF(PoolId poolId, uint8 mode, uint16 kQ8, uint24 cfCap, uint16 band16, uint16 tau, uint8 period)
        external
        restricted
    {
        _requireSwapModules();
        uint256 w = _word[poolId];
        if (w.cap() == 0) revert PoolNotConfigured();
        if (w.cfOn()) revert CFActive();
        uint256 maxAge = 5 * uint256(tau);
        if (maxAge > MAX_CF_AGE) maxAge = MAX_CF_AGE;
        // period >= maxAge would make every anchor write a full snap
        if (
            mode > FeeRef.CF_MODE_REVERSE || kQ8 == 0 || kQ8 > MAX_CF_K_Q8 || cfCap == 0 || cfCap > MAX_CF_CAP
                || band16 > MAX_CF_BAND16 || tau < MIN_CF_TAU || tau > MAX_CF_TAU || period == 0
                || period > MAX_CF_PERIOD || period >= maxAge
        ) revert InvalidCF();
        (, int24 tick,,) = poolManager.getSlot0(poolId);
        _cf[poolId] = FeeRef.packCF(
            FeeRef.CFWord({
                // forge-lint: disable-next-line(unsafe-typecast)
                tLast: uint40(block.timestamp),
                // |tick| <= 887_272, so tick * 256 fits int32
                // forge-lint: disable-next-line(unsafe-typecast)
                anchor: int32(int256(tick) * 256),
                decay1: FeeRef.decay1Q32(tau),
                kQ8: kQ8,
                cfCap: cfCap,
                band16: band16,
                // forge-lint: disable-next-line(unsafe-typecast)
                maxAge: uint8(maxAge),
                period: period,
                tau: tau,
                mode: mode
            })
        );
        emit CFConfigured(poolId, mode, kQ8, cfCap, band16, tau, period);
    }

    /// @notice Switches the CF on or off; switching on re-anchors it at the current tick.
    function setCFActive(PoolId poolId, bool on) external restricted {
        _requireSwapModules();
        uint256 w = _word[poolId];
        if (w.cap() == 0) revert PoolNotConfigured();
        if (on) {
            uint256 cf = _cf[poolId];
            if (FeeRef.cfK(cf) == 0) revert CFNotConfigured();
            (uint160 sqrtPriceX96, int24 tick,,) = poolManager.getSlot0(poolId);
            if (sqrtPriceX96 == 0) revert PoolNotInitialized();
            _cf[poolId] = FeeRef.cfRearm(cf, block.timestamp, tick);
        }
        _word[poolId] = w.withCfOn(on);
        emit CFActiveSet(poolId, on);
    }

    /// @notice Switches the CF off and zeroes its slope; only `configureCF` can revive it.
    function killCF(PoolId poolId) external restricted {
        _requireSwapModules();
        uint256 w = _word[poolId];
        if (w.cap() == 0) revert PoolNotConfigured();
        _word[poolId] = w.withCfOn(false);
        _cf[poolId] = FeeRef.cfWithK(_cf[poolId], 0);
        emit CFKilled(poolId);
    }

    /// @notice Decoded pool word.
    function poolFee(PoolId poolId) external view returns (PoolWordLib.PoolWord memory) {
        return _word[poolId].unpack();
    }

    /// @notice Raw pool word.
    function poolWord(PoolId poolId) external view returns (uint256) {
        return _word[poolId];
    }

    function categoryOf(PoolId poolId) external view returns (uint8) {
        return _meta[poolId].category;
    }

    function category(uint8 id) external view returns (Category memory) {
        return _categories[id];
    }

    /// @notice Live poke; a zero side is not poked.
    function pokeOf(PoolId poolId) external view returns (uint24 fee0For1, uint24 fee1For0, uint40 expiry) {
        uint256 w = _word[poolId];
        return (w.poke0(), w.poke1(), w.expiry());
    }

    /// @notice Configured floor. A poke never resolves below max(floor, min(base, cap) / 2).
    function pokeFloor(PoolId poolId) external view returns (uint24) {
        return _word[poolId].floor();
    }

    /// @notice |base0 - base1| and whether zeroForOne is the dearer direction.
    function poolAsymmetry(PoolId poolId) external view returns (uint24 premiumPips, bool premiumZeroForOne) {
        uint256 w = _word[poolId];
        uint24 b0 = w.base0();
        uint24 b1 = w.base1();
        return b0 > b1 ? (b0 - b1, true) : (b1 - b0, false);
    }

    /// @notice Base fee of a direction, before poke and cap.
    function autonomousFee(PoolId poolId, bool zeroForOne) external view returns (uint256) {
        return _word[poolId].base(zeroForOne);
    }

    function lastRaiseAt(PoolId poolId) external view returns (uint40) {
        return _meta[poolId].lastRaiseAt;
    }

    /// @notice Decoded CF word and whether the CF is on.
    function cfOf(PoolId poolId) external view returns (FeeRef.CFWord memory cf, bool on) {
        return (FeeRef.unpackCF(_cf[poolId]), _word[poolId].cfOn());
    }

    /// @notice Raw CF word.
    function cfWord(PoolId poolId) external view returns (uint256) {
        return _cf[poolId];
    }

    function discountOf(PoolId poolId, address account) external view returns (DiscountLib.Entry memory) {
        return DiscountLib.unpack(_entry[poolId][account]);
    }

    function discountFilter(PoolId poolId) external view returns (uint8 seed, uint64 bloom) {
        uint256 w = _word[poolId];
        return (w.seed(), w.bloom());
    }
}
