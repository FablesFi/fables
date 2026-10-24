// SPDX-License-Identifier: MIT
// Adapted from OpenZeppelin Uniswap Hooks v1.3.0 (MIT, Copyright (c) 2016-2026 Zeppelin Group Ltd).
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolDonateTest} from "v4-core/src/test/PoolDonateTest.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {Position} from "v4-core/src/libraries/Position.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {ProtocolFeeLibrary} from "v4-core/src/libraries/ProtocolFeeLibrary.sol";
import {FablesLedgerV2} from "../../../src/base/FablesLedgerV2.sol";
import {RangeState, UserPosition} from "../../../src/base/LedgerTypesV2.sol";
import {OzBaseHandler} from "./OzBaseHandler.sol";

interface IEngineQuote {
    function feeFor(PoolId poolId, bool zeroForOne, address sender) external view returns (uint24);
    function pokeFee(PoolId poolId, uint24 fee0For1, uint24 fee1For0, uint40 ttl) external;
}

interface IStableQuote {
    function feeFor(PoolKey calldata key, bool zeroForOne, address sender) external view returns (uint24);
}

/// @notice Handler for one hook carrying two pools: swaps, ledger liquidity, receipt transfers, fee claims, router
///         liquidity, donations and pokes. Every swap is checked against the hook's quote; every ledger action
///         against the PoolManager's fee accounting; round trips against value creation.
contract OzHookHandler is OzBaseHandler {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;
    using ProtocolFeeLibrary for uint24;
    using ProtocolFeeLibrary for uint16;

    struct Setup {
        IPoolManager manager;
        FablesLedgerV2 hook;
        bool stable;
        PoolSwapTest swapRouter;
        PoolModifyLiquidityTest lpRouter;
        PoolDonateTest donateRouter;
        PoolKey key0;
        PoolKey key1;
        address[3] actors;
    }

    struct RouterPosition {
        address owner;
        uint8 pool;
        uint8 range;
        uint128 liquidity;
    }

    struct Snap {
        uint256 claims0;
        uint256 claims1;
        uint256 pending0;
        uint256 pending1;
    }

    bytes32 internal constant SWAP_TOPIC =
        keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");
    uint256 internal constant Q128 = 1 << 128;
    /// @notice ETH sent with every native-pool call; the unspent part is refunded.
    uint256 public constant NATIVE_VALUE = 1e24;
    uint256 internal constant MIN_LIQUIDITY = 1e12;
    uint256 internal constant MAX_LIQUIDITY = 1e20;
    uint256 internal constant MIN_AMOUNT = 1e3;
    uint256 internal constant MAX_AMOUNT = 1e18;
    /// @dev An add rounds up and a remove rounds down, each through two divisions.
    uint256 internal constant ROUND_TRIP_DUST = 2;

    FablesLedgerV2 public immutable hook;
    bool public immutable stable;
    PoolSwapTest public immutable swapRouter;
    PoolModifyLiquidityTest public immutable lpRouter;
    PoolDonateTest public immutable donateRouter;

    PoolKey[2] internal _keys;
    int24[2] internal _window = [int24(1200), 400];
    int24[3][2] internal _lowers = [[int24(-600), -120, 60], [int24(-100), -20, -200]];
    int24[3][2] internal _uppers = [[int24(600), 120, 600], [int24(100), 20, -10]];
    RouterPosition[] internal _routerPositions;

    /// @notice Swaps and donates the pool accepted but the hook reverted.
    uint256 public ghost_hookRejections;
    bytes public ghost_lastRejection;
    /// @notice Swaps whose charged fee differs from the hook's pre-swap quote (with the protocol fee composed in).
    uint256 public ghost_feeMismatches;
    uint256 public ghost_swaps;
    uint256 public ghost_swapRoundTrips;
    uint256 public ghost_ledgerRoundTrips;
    uint256 public ghost_directAddsLanded;
    uint256 public ghost_directAddsRejected;

    constructor(Setup memory s) {
        manager = s.manager;
        hook = s.hook;
        stable = s.stable;
        swapRouter = s.swapRouter;
        lpRouter = s.lpRouter;
        donateRouter = s.donateRouter;
        _keys[0] = s.key0;
        _keys[1] = s.key1;
        for (uint256 i; i < 3; ++i) {
            _createActor(s.actors[i]);
        }
    }

    // --------------- Actions --------------- //

    function swap(uint256 actorSeed, uint256 poolSeed, uint256 amountSeed, bool zeroForOne, bool exactInput)
        external
        recordCall("swap")
    {
        int256 amount = int256(bound(amountSeed, MIN_AMOUNT, MAX_AMOUNT));
        _checkedSwap(_actorFromSeed(actorSeed), poolSeed % 2, zeroForOne, exactInput ? -amount : amount);
    }

    /// @notice Swap in, then swap the whole output back: the trader never ends with more of what it paid.
    function swapRoundTrip(uint256 actorSeed, uint256 poolSeed, uint256 amountSeed, bool zeroForOne)
        external
        recordCall("swapRoundTrip")
    {
        address actor = _actorFromSeed(actorSeed);
        uint256 p = poolSeed % 2;
        (bool ok, BalanceDelta out) =
            _checkedSwap(actor, p, zeroForOne, -int256(bound(amountSeed, MIN_AMOUNT, MAX_AMOUNT)));
        int128 received = zeroForOne ? out.amount1() : out.amount0();
        if (!ok || received <= 0) return;
        BalanceDelta back;
        (ok, back) = _checkedSwap(actor, p, !zeroForOne, -int256(received));
        // a leg stopped by the price limit is not a full round trip
        if (!ok || (zeroForOne ? back.amount1() : back.amount0()) != -received) return;
        int128 net = zeroForOne ? out.amount0() + back.amount0() : out.amount1() + back.amount1();
        assertLe(net, 0, "a swap round trip returned more than it paid");
        ghost_swapRoundTrips++;
    }

    function deposit(uint256 actorSeed, uint256 poolSeed, uint256 rangeSeed, uint256 liquiditySeed)
        external
        recordCall("deposit")
    {
        _deposit(
            _actorFromSeed(actorSeed),
            poolSeed % 2,
            rangeSeed % 3,
            uint128(bound(liquiditySeed, MIN_LIQUIDITY, MAX_LIQUIDITY))
        );
    }

    function withdraw(uint256 actorSeed, uint256 poolSeed, uint256 rangeSeed, uint256 amountSeed)
        external
        recordCall("withdraw")
    {
        address actor = _actorFromSeed(actorSeed);
        (uint256 p, uint256 r) = (poolSeed % 2, rangeSeed % 3);
        uint256 balance = hook.balanceOf(actor, rangeIdOf(p, r));
        if (balance == 0) return;
        uint128 amount = uint128(bound(amountSeed, 1, balance));
        Snap memory s = _snap(p, r);
        vm.prank(actor);
        hook.withdraw(_keys[p], _lowers[p][r], _uppers[p][r], amount, actor, 0, 0, block.timestamp);
        _assertSynced(p, s, 0, 0);
    }

    /// @notice Deposit then withdraw the same liquidity: the LP gets back what it paid, less rounding.
    function ledgerRoundTrip(uint256 actorSeed, uint256 poolSeed, uint256 rangeSeed, uint256 liquiditySeed)
        external
        recordCall("ledgerRoundTrip")
    {
        address actor = _actorFromSeed(actorSeed);
        (uint256 p, uint256 r) = (poolSeed % 2, rangeSeed % 3);
        uint128 liquidity = uint128(bound(liquiditySeed, MIN_LIQUIDITY, MAX_LIQUIDITY));
        PoolKey memory k = _keys[p];
        uint256 before0 = _balanceOf(k.currency0, actor);
        uint256 before1 = _balanceOf(k.currency1, actor);
        if (!_deposit(actor, p, r, liquidity)) return;
        vm.prank(actor);
        hook.withdraw(k, _lowers[p][r], _uppers[p][r], liquidity, actor, 0, 0, block.timestamp);
        _assertRoundTrip(before0, _balanceOf(k.currency0, actor), "currency0");
        _assertRoundTrip(before1, _balanceOf(k.currency1, actor), "currency1");
        ghost_ledgerRoundTrips++;
    }

    function transferReceipts(uint256 fromSeed, uint256 toSeed, uint256 poolSeed, uint256 rangeSeed, uint256 amountSeed)
        external
        recordCall("transferReceipts")
    {
        address from = _actorFromSeed(fromSeed);
        (uint256 p, uint256 r) = (poolSeed % 2, rangeSeed % 3);
        uint256 id = rangeIdOf(p, r);
        uint256 balance = hook.balanceOf(from, id);
        if (balance == 0) return;
        (address to, uint256 amount) = (_actorFromSeed(toSeed), bound(amountSeed, 1, balance));
        Snap memory s = _snap(p, r);
        vm.prank(from);
        assertTrue(hook.transfer(to, id, amount));
        _assertSynced(p, s, 0, 0);
    }

    function claim(uint256 actorSeed, uint256 poolSeed, uint256 rangeSeed) external recordCall("claim") {
        address actor = _actorFromSeed(actorSeed);
        (uint256 p, uint256 r) = (poolSeed % 2, rangeSeed % 3);
        PoolKey memory k = _keys[p];
        Snap memory s = _snap(p, r);
        uint256 before0 = _balanceOf(k.currency0, actor);
        uint256 before1 = _balanceOf(k.currency1, actor);
        vm.prank(actor);
        try hook.claimFees(k, _lowers[p][r], _uppers[p][r], actor, 10_000) {}
        catch {
            return;
        }
        _assertSynced(p, s, _balanceOf(k.currency0, actor) - before0, _balanceOf(k.currency1, actor) - before1);
    }

    /// @notice Liquidity added around the ledger, through a router.
    function directAdd(uint256 actorSeed, uint256 poolSeed, uint256 rangeSeed, uint256 liquiditySeed)
        external
        recordCall("directAdd")
    {
        address actor = _actorFromSeed(actorSeed);
        (uint256 p, uint256 r) = (poolSeed % 2, rangeSeed % 3);
        uint128 liquidity = uint128(bound(liquiditySeed, MIN_LIQUIDITY, MAX_LIQUIDITY));
        PoolKey memory k = _keys[p];
        IPoolManager.ModifyLiquidityParams memory params = IPoolManager.ModifyLiquidityParams({
            tickLower: _lowers[p][r],
            tickUpper: _uppers[p][r],
            liquidityDelta: int256(uint256(liquidity)),
            salt: bytes32(uint256(uint160(actor)))
        });
        uint256 value = _value(k);
        vm.prank(actor);
        try lpRouter.modifyLiquidity{value: value}(k, params, "") {
            ghost_directAddsLanded++;
            // forge-lint: disable-next-line(unsafe-typecast)
            _routerPositions.push(RouterPosition(actor, uint8(p), uint8(r), liquidity));
        } catch (bytes memory reason) {
            if (_isHookRejection(reason, address(hook))) ghost_directAddsRejected++;
        }
    }

    /// @notice Removes a router position; removals stay open on every build.
    function directRemove(uint256 positionSeed) external recordCall("directRemove") {
        uint256 n = _routerPositions.length;
        if (n == 0) return;
        uint256 i = positionSeed % n;
        RouterPosition memory pos = _routerPositions[i];
        _routerPositions[i] = _routerPositions[n - 1];
        _routerPositions.pop();
        IPoolManager.ModifyLiquidityParams memory params = IPoolManager.ModifyLiquidityParams({
            tickLower: _lowers[pos.pool][pos.range],
            tickUpper: _uppers[pos.pool][pos.range],
            liquidityDelta: -int256(uint256(pos.liquidity)),
            salt: bytes32(uint256(uint160(pos.owner)))
        });
        PoolKey memory k = _keys[pos.pool];
        vm.prank(pos.owner);
        lpRouter.modifyLiquidity(k, params, "");
    }

    function donate(uint256 poolSeed, uint256 amountSeed) external recordCall("donate") {
        PoolKey memory k = _keys[poolSeed % 2];
        if (manager.getLiquidity(k.toId()) == 0) return;
        uint256 amount = bound(amountSeed, 1, MAX_AMOUNT / 100);
        uint256 value = k.currency0.isAddressZero() ? amount : 0;
        address donor = _actorFromSeed(amountSeed);
        vm.prank(donor);
        try donateRouter.donate{value: value}(k, amount, amount, "") {}
        catch (bytes memory reason) {
            _recordRejection(reason);
        }
    }

    /// @notice Moves the engine fee within whatever the hook accepts (Stable build: no-op).
    function poke(uint256 poolSeed, uint256 fee0Seed, uint256 fee1Seed, uint256 ttlSeed) external recordCall("poke") {
        if (stable) return;
        PoolId id = _keys[poolSeed % 2].toId();
        // forge-lint: disable-next-line(unsafe-typecast)
        uint24 fee0 = uint24(bound(fee0Seed, 0, 50_000));
        // forge-lint: disable-next-line(unsafe-typecast)
        uint24 fee1 = uint24(bound(fee1Seed, 0, 50_000));
        // forge-lint: disable-next-line(unsafe-typecast)
        uint40 ttl = uint40(bound(ttlSeed, 1, 72 hours));
        try IEngineQuote(address(hook)).pokeFee(id, fee0, fee1, ttl) {} catch {}
    }

    function nextBlock(uint256 seed) external recordCall("nextBlock") {
        vm.roll(block.number + bound(seed, 1, 3));
        vm.warp(block.timestamp + bound(seed >> 8, 1, 120));
    }

    // --------------- Views --------------- //

    function key(uint256 p) external view returns (PoolKey memory) {
        return _keys[p];
    }

    function rangeIdOf(uint256 p, uint256 r) public view returns (uint256) {
        return hook.rangeId(_keys[p].toId(), _lowers[p][r], _uppers[p][r]);
    }

    function lowerOf(uint256 p, uint256 r) external view returns (int24) {
        return _lowers[p][r];
    }

    function upperOf(uint256 p, uint256 r) external view returns (int24) {
        return _uppers[p][r];
    }

    /// @notice Receipts of range `r` held across the actors.
    function receiptsHeld(uint256 p, uint256 r) external view returns (uint256 sum) {
        address[] memory holders = actors();
        uint256 id = rangeIdOf(p, r);
        for (uint256 a; a < holders.length; ++a) {
            sum += hook.balanceOf(holders[a], id);
        }
    }

    /// @notice Liquidity of the ledger's own PoolManager position for range `r`.
    function positionLiquidity(uint256 p, uint256 r) external view returns (uint128) {
        bytes32 positionKey = Position.calculatePositionKey(address(hook), _lowers[p][r], _uppers[p][r], bytes32(0));
        return manager.getPositionLiquidity(_keys[p].toId(), positionKey);
    }

    /// @notice What the ledger owes in `currency`: every holder's settled and pending fees, plus the sink balances.
    function owedIn(Currency currency) external view returns (uint256 owed) {
        owed = hook.distributorOwed(currency) + hook.claimFeeOwed(currency);
        address[] memory holders = actors();
        for (uint256 p; p < 2; ++p) {
            bool side0 = _keys[p].currency0 == currency;
            if (!side0 && !(_keys[p].currency1 == currency)) continue;
            for (uint256 r; r < 3; ++r) {
                uint256 id = rangeIdOf(p, r);
                RangeState memory st = hook.rangeState(id);
                for (uint256 a; a < holders.length; ++a) {
                    UserPosition memory pos = hook.userPosition(id, holders[a]);
                    uint256 unstaked = hook.balanceOf(holders[a], id) - pos.staked;
                    owed += side0
                        ? pos.owed0 + FullMath.mulDiv(unstaked, _since(st.accFee0X128, pos.checkpoint0X128), Q128)
                        : pos.owed1 + FullMath.mulDiv(unstaked, _since(st.accFee1X128, pos.checkpoint1X128), Q128);
                }
            }
        }
    }

    // --------------- Internals --------------- //

    function _value(PoolKey memory k) internal pure returns (uint256) {
        return k.currency0.isAddressZero() ? NATIVE_VALUE : 0;
    }

    function _quote(PoolKey memory k, bool zeroForOne) internal view returns (uint24) {
        if (stable) return IStableQuote(address(hook)).feeFor(k, zeroForOne, address(swapRouter));
        return IEngineQuote(address(hook)).feeFor(k.toId(), zeroForOne, address(swapRouter));
    }

    /// @dev Runs one swap as `actor`, records a hook rejection, and checks the fee it paid against the quote.
    function _checkedSwap(address actor, uint256 p, bool zeroForOne, int256 amountSpecified)
        internal
        returns (bool ok, BalanceDelta delta)
    {
        PoolKey memory k = _keys[p];
        uint24 quoted = _quote(k, zeroForOne);
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: amountSpecified,
            sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(zeroForOne ? -_window[p] : _window[p])
        });
        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        uint256 value = _value(k);
        vm.recordLogs();
        vm.prank(actor);
        try swapRouter.swap{value: value}(k, params, settings, "") returns (BalanceDelta d) {
            (ok, delta) = (true, d);
            ghost_swaps++;
            _checkFee(k, zeroForOne, quoted);
        } catch (bytes memory reason) {
            _recordRejection(reason);
        }
    }

    function _recordRejection(bytes memory reason) internal {
        if (!_isHookRejection(reason, address(hook))) return;
        ghost_hookRejections++;
        ghost_lastRejection = reason;
    }

    /// @dev The `Swap` event's fee must be the hook's quote, composed with the pool's protocol fee for the side.
    function _checkFee(PoolKey memory k, bool zeroForOne, uint24 quoted) internal {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 id = PoolId.unwrap(k.toId());
        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory entry = logs[i];
            if (entry.emitter != address(manager) || entry.topics.length < 2) continue;
            if (entry.topics[0] != SWAP_TOPIC || entry.topics[1] != id) continue;
            (,,,,, uint24 fee) = abi.decode(entry.data, (int128, int128, uint160, uint128, int24, uint24));
            (,, uint24 protocolFee,) = manager.getSlot0(k.toId());
            uint16 side = zeroForOne ? protocolFee.getZeroForOneFee() : protocolFee.getOneForZeroFee();
            if (fee != (side == 0 ? quoted : side.calculateSwapFee(quoted))) ghost_feeMismatches++;
            return;
        }
        ghost_feeMismatches++;
    }

    function _deposit(address actor, uint256 p, uint256 r, uint128 liquidity) internal returns (bool ok) {
        PoolKey memory k = _keys[p];
        Snap memory s = _snap(p, r);
        uint256 value = _value(k);
        // forge-lint: disable-next-line(unsafe-typecast)
        uint128 max0 = value == 0 ? type(uint128).max : uint128(value);
        vm.prank(actor);
        try hook.deposit{value: value}(
            k, _lowers[p][r], _uppers[p][r], liquidity, max0, type(uint128).max, block.timestamp
        ) {
            ok = true;
        } catch {
            return false;
        }
        _assertSynced(p, s, 0, 0);
    }

    function _snap(uint256 p, uint256 r) internal view returns (Snap memory s) {
        PoolKey memory k = _keys[p];
        s.claims0 = claimsOf(k.currency0, address(hook));
        s.claims1 = claimsOf(k.currency1, address(hook));
        (s.pending0, s.pending1) = _calculateFees(k.toId(), address(hook), _lowers[p][r], _uppers[p][r], bytes32(0));
    }

    /// @dev Every fee the PoolManager reports for the ledger's position becomes hook claims at the sync, wei for wei;
    ///      claims leave only as payouts.
    function _assertSynced(uint256 p, Snap memory s, uint256 paid0, uint256 paid1) internal view {
        PoolKey memory k = _keys[p];
        assertEq(
            claimsOf(k.currency0, address(hook)) + paid0,
            s.claims0 + s.pending0,
            "currency0: synced fees differ from the PoolManager's position fees"
        );
        assertEq(
            claimsOf(k.currency1, address(hook)) + paid1,
            s.claims1 + s.pending1,
            "currency1: synced fees differ from the PoolManager's position fees"
        );
    }

    function _assertRoundTrip(uint256 before, uint256 afterwards, string memory what) internal pure {
        assertLe(afterwards, before, string.concat(what, ": a ledger round trip paid out more than it took"));
        assertLe(before - afterwards, ROUND_TRIP_DUST, string.concat(what, ": a round trip kept more than dust"));
    }

    function _since(uint256 level, uint256 checkpoint) internal pure returns (uint256) {
        unchecked {
            return level - checkpoint;
        }
    }
}
