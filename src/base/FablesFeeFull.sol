// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {FablesFeeEngine} from "./FablesFeeEngine.sol";
import {PoolWordLib} from "../libraries/PoolWordLib.sol";
import {DiscountLib} from "../libraries/DiscountLib.sol";
import {FeeRef} from "../libraries/FeeRef.sol";

/// @title FablesFeeFull
/// @notice Fee engine whose assembly `beforeSwap` entry (the fallback) resolves and overrides the fee on every swap.
/// @dev The entry must match `FeeRef.resolve` (`_resolveFeeRef`, used by the views); past the gate it never reverts.
///      Only the PoolManager passes the gate and its calldata is canonical, so it is read at fixed offsets:
///        0x00 selector (0x575e24b4)   0x04 sender   0x24 PoolKey (160 bytes)   0xc4 zeroForOne   0xe4 amountSpecified
///      PoolId = keccak256 of the 160 PoolKey bytes. The key is hashed from free memory, everything else uses scratch
///      space, and the fallback returns 0x00-0x5f without re-entering Solidity code.
abstract contract FablesFeeFull is FablesFeeEngine {
    using PoolWordLib for uint256;
    using StateLibrary for IPoolManager;

    /// @dev The engine's mapping slots differ from WORD_SLOT / CF_SLOT / ENTRY_SLOT.
    error StorageLayoutMismatch();

    /// @notice IHooks.beforeSwap.selector, the one selector the fallback serves.
    uint32 public constant BEFORE_SWAP_SELECTOR = 0x575e24b4;
    /// @notice NotPoolManager.selector, the gate's revert.
    uint32 public constant NOT_POOL_MANAGER_SELECTOR = 0xae18210a;
    /// @notice IExtsload.extsload(bytes32) selector, used to read the pool's slot0.
    uint32 public constant EXTSLOAD_SELECTOR = 0x1e2eaeaf;
    /// @notice PoolManager `pools` mapping slot: slot0 of a pool = keccak256(id . 6).
    uint256 public constant PM_POOLS_SLOT = 6;
    uint24 public constant OVERRIDE_FEE_FLAG = 0x400000;

    /// @notice Slot of `_word`: word of `id` at keccak256(id . 2). Checked in the constructor.
    uint256 public constant WORD_SLOT = 2;
    /// @notice Slot of `_cf`: CF word of `id` at keccak256(id . 3).
    uint256 public constant CF_SLOT = 3;
    /// @notice Slot of `_entry`: entry of (`id`, `account`) at keccak256(account . keccak256(id . 4)).
    uint256 public constant ENTRY_SLOT = 4;

    constructor(IPoolManager poolManager_, address authority_) FablesFeeEngine(poolManager_, authority_) {
        uint256 wordSlot;
        uint256 cfSlot;
        uint256 entrySlot;
        assembly ("memory-safe") {
            wordSlot := _word.slot
            cfSlot := _cf.slot
            entrySlot := _entry.slot
        }
        if (wordSlot != WORD_SLOT || cfSlot != CF_SLOT || entrySlot != ENTRY_SLOT) revert StorageLayoutMismatch();
    }

    function _hookPermissions() internal pure virtual override returns (Hooks.Permissions memory permissions) {
        permissions.beforeInitialize = true;
        permissions.beforeSwap = true;
    }

    /// @notice `beforeSwap`, PoolManager only. Returns (selector, 0 delta, fee | OVERRIDE_FEE_FLAG).
    /// @dev Inlines `FeeRef.resolve`: base and poke, discount on a Bloom hit, then CF (which may write the CF word).
    fallback() external {
        address pm = address(poolManager);
        assembly {
            if iszero(and(eq(caller(), pm), eq(shr(224, calldataload(0x00)), BEFORE_SWAP_SELECTOR))) {
                mstore(0x00, shl(224, NOT_POOL_MANAGER_SELECTOR))
                revert(0x00, 0x04)
            }

            let fmp := mload(0x40)
            calldatacopy(fmp, 0x24, 0xa0)
            let id := keccak256(fmp, 0xa0) // == PoolId
            let side := iszero(calldataload(0xc4)) // 0 = zeroForOne, 1 = oneForZero
            let sender := and(calldataload(0x04), 0xffffffffffffffffffffffffffffffffffffffff)

            mstore(0x00, id)
            mstore(0x20, _word.slot)
            let w := sload(keccak256(0x00, 0x40))

            // base and poke, capped
            let sh := mul(side, 24)
            let pre := and(shr(sh, w), 0xffffff) // base[side]
            let cap := and(shr(160, w), 0xffffff)
            let floor_ := and(shr(136, w), 0xffffff)
            let fee := pre
            if lt(timestamp(), and(shr(96, w), 0xffffffffff)) {
                let poked := and(shr(add(48, sh), w), 0xffffff) // poke[side]; 0 = side not poked
                if poked {
                    // lo = max(floor, min(pre, cap) / 2): the 50% cut rule
                    let lo := pre
                    if gt(lo, cap) { lo := cap }
                    lo := shr(1, lo)
                    if lt(lo, floor_) { lo := floor_ }
                    fee := poked
                    if lt(fee, lo) { fee := lo }
                }
            }
            if gt(fee, cap) { fee := cap }

            // FeeRef.discounted (Bloom hit only)
            let bloom := and(shr(184, w), 0xffffffffffffffff)
            if bloom {
                // DiscountLib.mask64: h = (sender ^ (seed << 160)) * HASH_MULTIPLIER, k = 3 six-bit slices
                let h :=
                    mul(
                        xor(sender, shl(160, and(shr(248, w), 0x7f))),
                        0x9E3779B97F4A7C15F39CC0605CEDC8341082276BF3A27251F86C6A11D0C18E95
                    )
                // Yul shl(shift, value): 1 << k
                // slither-disable-next-line incorrect-shift
                let m := or(or(shl(shr(250, h), 1), shl(and(shr(244, h), 63), 1)), shl(and(shr(238, h), 63), 1))
                if eq(and(bloom, m), m) {
                    // entry slot = keccak256(sender . keccak256(id . _entry.slot))
                    mstore(0x00, id)
                    mstore(0x20, _entry.slot)
                    mstore(0x20, keccak256(0x00, 0x40))
                    mstore(0x00, sender)
                    let e := sload(keccak256(0x00, 0x40))
                    let bps := and(e, 0xffff)
                    // DiscountLib.isLive: bps != 0, now < expiry, dirs bit of this side
                    if and(
                        and(iszero(iszero(bps)), lt(timestamp(), and(shr(48, e), 0xffffffffff))),
                        and(shr(add(40, side), e), 1)
                    ) {
                        // DiscountLib.applyDiscount: min(fee, max(ceil(fee * (1 - min(bps, 50%))), floor, minFee))
                        if gt(bps, 5000) { bps := 5000 }
                        let d := div(add(mul(fee, sub(10000, bps)), 9999), 10000)
                        let lo := and(shr(16, e), 0xffffff)
                        if lt(lo, floor_) { lo := floor_ }
                        if lt(d, lo) { d := lo }
                        if lt(d, fee) { fee := d }
                    }
                }
            }

            // FeeRef.cfStep (cfOn only)
            if shr(255, w) {
                // PoolManager slot0 of this pool: extsload(keccak256(id . POOLS_SLOT))
                mstore(0x00, id)
                mstore(0x20, PM_POOLS_SLOT)
                let s0Slot := keccak256(0x00, 0x40)
                mstore(0x00, shl(224, EXTSLOAD_SELECTOR))
                mstore(0x04, s0Slot)
                // separate statement: returndatasize() must be read after the call
                let ok := staticcall(gas(), pm, 0x00, 0x24, 0x00, 0x20)
                if and(ok, eq(returndatasize(), 0x20)) {
                    let tick := signextend(2, shr(160, mload(0x00))) // Slot0.tick
                    mstore(0x00, id)
                    mstore(0x20, _cf.slot)
                    let cfSlot := keccak256(0x00, 0x40)
                    let cf := sload(cfSlot)
                    let a := signextend(3, shr(40, cf)) // anchor, 1/256 tick
                    let t := mul(tick, 256)
                    let dt := 0
                    if gt(timestamp(), and(cf, 0xffffffffff)) { dt := sub(timestamp(), and(cf, 0xffffffffff)) }
                    // anchor update when dt >= period: A = T + (A - T) * decay1^dt / 2^32 (sdiv: toward T), tLast = now
                    if iszero(lt(dt, and(shr(168, cf), 0xff))) {
                        let f := 0 // decay1^dt in Q32; stays 0 at or past maxAge (full reset)
                        if lt(dt, and(shr(160, cf), 0xff)) {
                            f := 0x100000000
                            let b := and(shr(72, cf), 0xffffffff)
                            for {} dt {} {
                                if and(dt, 1) { f := shr(32, mul(f, b)) }
                                dt := shr(1, dt)
                                b := shr(32, mul(b, b))
                            }
                        }
                        a := add(t, sdiv(mul(sub(a, t), f), 0x100000000))
                        let cfNew :=
                            or(
                                and(cf, not(0xffffffffffffffffff)),
                                or(and(timestamp(), 0xffffffffff), shl(40, and(a, 0xffffffff)))
                            )
                        if iszero(eq(cfNew, cf)) { sstore(cfSlot, cfNew) }
                    }
                    // x = m - band * 16; m = how far this direction already ran; mode 1 negates m
                    let x := sub(a, t)
                    if side { x := sub(t, a) }
                    if and(shr(192, cf), 1) { x := sub(0, x) }
                    x := sub(x, shl(4, and(shr(144, cf), 0xffff)))
                    if sgt(x, 0) {
                        // s = min((k * x * 100) >> 16, cfCap); fee = min(fee + s, cap)
                        let s := shr(16, mul(mul(and(shr(104, cf), 0xffff), x), 100))
                        let cfCap := and(shr(120, cf), 0xffffff)
                        if gt(s, cfCap) { s := cfCap }
                        fee := add(fee, s)
                        if gt(fee, cap) { fee := cap }
                    }
                }
            }

            mstore(0x00, shl(224, BEFORE_SWAP_SELECTOR))
            mstore(0x20, 0)
            mstore(0x40, or(fee, OVERRIDE_FEE_FLAG))
            return(0x00, 0x60)
        }
    }

    /// @notice Sender-free fee of a direction right now, CF included, no discount; a router quotes its own fee with
    ///         `feeFor`.
    function currentFee(PoolId poolId, bool zeroForOne) external view returns (uint24) {
        (uint256 fee,) = _resolveFeeRef(poolId, zeroForOne, address(0));
        // fee <= cap < 2^24 (FeeRef)
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint24(fee);
    }

    /// @notice Fee `sender` would pay right now, discount included.
    function feeFor(PoolId poolId, bool zeroForOne, address sender) external view returns (uint24) {
        (uint256 fee,) = _resolveFeeRef(poolId, zeroForOne, sender);
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint24(fee);
    }

    /// FeeRef.resolve over this storage: the swap entry's fee and the CF word it would leave (0 while the CF is off).
    function _resolveFeeRef(PoolId poolId, bool zeroForOne, address sender)
        internal
        view
        returns (uint256 fee, uint256 cfNew)
    {
        uint256 w = _word[poolId];
        uint256 entry;
        uint64 bloom = w.bloom();
        if (bloom != 0 && DiscountLib.hit64(bloom, sender, w.seed())) entry = _entry[poolId][sender];
        uint256 cf;
        int24 tick;
        if (w.cfOn()) {
            cf = _cf[poolId];
            (, tick,,) = poolManager.getSlot0(poolId);
        }
        return FeeRef.resolve(w, zeroForOne, sender, entry, cf, tick, block.timestamp);
    }
}
