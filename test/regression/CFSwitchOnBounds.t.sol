// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

// `setCFActive(true)` anchors the continuation fee at the current tick, which must lie in the caller's
// [minTick, maxTick], no later than the caller's deadline: whoever lands a relayable FEE_POKER call (for example a
// Safe execution anyone can submit) cannot move the price first and leave the anchor at a tick of their choice, and a
// signed call that did not land cannot be landed after its deadline. Switching off ignores both.

import {Test} from "forge-std/Test.sol";
import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FablesHook} from "../../src/FablesHook.sol";
import {FablesFeeEngine} from "../../src/base/FablesFeeEngine.sol";
import {FeeRef} from "../../src/libraries/FeeRef.sol";

/// Relays a call (stands in for a Safe whose signed execution anyone can submit).
contract SignedSafe {
    function relay(address to, bytes calldata data) external returns (bytes memory r) {
        bool s;
        (s, r) = to.call(data);
        if (!s) {
            assembly ("memory-safe") {
                revert(add(r, 32), mload(r))
            }
        }
    }
}

/// Moves the price to `toTick` inside its own unlock, relays a signed execution there, restores the price and settles.
contract TickMover is IUnlockCallback {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    IPoolManager internal immutable pm;
    int24 public movedTick;

    constructor(IPoolManager pm_) {
        pm = pm_;
    }

    function run(PoolKey calldata key, int24 toTick, address safe, bytes calldata relayData) external {
        pm.unlock(abi.encode(key, toTick, safe, relayData));
    }

    function unlockCallback(bytes calldata raw) external returns (bytes memory) {
        (PoolKey memory key, int24 toTick, address safe, bytes memory relayData) =
            abi.decode(raw, (PoolKey, int24, address, bytes));
        (uint160 p0,,,) = pm.getSlot0(key.toId());
        uint160 to = TickMath.getSqrtPriceAtTick(toTick);
        pm.swap(key, IPoolManager.SwapParams(to < p0, -int256(1e30), to), "");
        (, movedTick,,) = pm.getSlot0(key.toId());
        (bool ok, bytes memory r) = safe.call(relayData);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(r, 32), mload(r))
            }
        }
        pm.swap(key, IPoolManager.SwapParams(p0 < to, -int256(1e30), p0), "");
        _settle(key.currency0);
        _settle(key.currency1);
        return "";
    }

    function _settle(Currency c) internal {
        int256 delta = TransientStateLibrary.currencyDelta(pm, address(this), c);
        if (delta < 0) {
            pm.sync(c);
            IERC20(Currency.unwrap(c)).transfer(address(pm), uint256(-delta));
            pm.settle();
        } else if (delta > 0) {
            pm.take(c, address(this), uint256(delta));
        }
    }
}

contract CFSwitchOnBoundsTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint64 internal constant FEE_POKER = 1;
    uint24 internal constant BASE = 3_000;
    uint24 internal constant CF_CAP = 2_500;

    AccessManager internal authority;
    FablesHook internal hook;
    PoolKey internal k;
    PoolId internal id;
    SignedSafe internal pokerSafe;
    TickMover internal mover;
    address internal poker = makeAddr("poker");

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();
        authority = new AccessManager(address(this));
        address h = address(uint160(0x12B1 << 144) | uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG));
        deployCodeTo("FablesHook.sol:FablesHook", abi.encode(manager, address(authority)), h);
        hook = FablesHook(payable(h));
        bytes4[] memory s = new bytes4[](1);
        s[0] = FablesFeeEngine.setCFActive.selector;
        authority.setTargetFunctionRole(h, s, FEE_POKER);
        authority.grantRole(FEE_POKER, poker, 0);
        // FEE_POKER also held by a Safe: anyone can submit its signed execution
        pokerSafe = new SignedSafe();
        authority.grantRole(FEE_POKER, address(pokerSafe), 0);

        k = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 1, IHooks(h));
        id = k.toId();
        hook.setCategory(1, 0, 100_000, 100_000, "ANY");
        hook.configurePool(k, 1, BASE, BASE, 0, 10_000);
        hook.initializePool(k, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(k, IPoolManager.ModifyLiquidityParams(-6_000, 6_000, 1e21, 0), "");

        mover = new TickMover(manager);
        currency0.transfer(address(mover), 1e24);
        currency1.transfer(address(mover), 1e24);
    }

    /// CF continuation, k = 1.0, cfCap 25 bp, dead band `bandTicks`, tau 300 s, period 60 s; off.
    function _configure(uint16 bandTicks) internal {
        hook.configureCF(id, 0, 256, CF_CAP, bandTicks * 16, 300, 60);
    }

    function _signedOn(int24 lo, int24 hi) internal view returns (bytes memory) {
        return _signedOn(lo, hi, type(uint256).max);
    }

    function _signedOn(int24 lo, int24 hi, uint256 deadline) internal view returns (bytes memory) {
        return abi.encodeCall(
            SignedSafe.relay, (address(hook), abi.encodeCall(FablesFeeEngine.setCFActive, (id, true, lo, hi, deadline)))
        );
    }

    function _anchorTicks() internal view returns (int256) {
        (FeeRef.CFWord memory cf,) = hook.cfOf(id);
        return int256(cf.anchor) / 256;
    }

    function _tick() internal view returns (int24 t) {
        (, t,,) = manager.getSlot0(id);
    }

    /// The signer approved [-10, 10] at tick 0; a relayer moves the price 100 ticks and lands the call there: it reverts
    /// (without the bounds the anchor stayed at -100 and oneForZero paid base + cfCap at tick 0).
    function test_relayedSwitchOnOutsideTheBounds_reverts() public {
        _configure(0);
        assertEq(_tick(), 0);
        uint256 cfBefore = hook.cfWord(id);
        vm.expectRevert(abi.encodeWithSelector(FablesFeeEngine.CFTickOutOfRange.selector, int24(-100)));
        mover.run(k, -100, address(pokerSafe), _signedOn(-10, 10));
        assertEq(hook.cfWord(id), cfBefore, "nothing written");
        (, bool on) = hook.cfOf(id);
        assertFalse(on, "still off");
        assertEq(hook.currentFee(id, false), BASE);
        assertEq(hook.currentFee(id, true), BASE);
    }

    /// Inside the bounds the relayer moves the anchor at most to the range edge; with a dead band at least that wide the
    /// round trip leaves no surcharge on either side.
    function test_relayedSwitchOnInsideTheBounds_bandAbsorbsIt() public {
        _configure(10);
        mover.run(k, -10, address(pokerSafe), _signedOn(-10, 10));
        assertEq(mover.movedTick(), -10);
        assertEq(_tick(), 0, "price restored");
        assertEq(_anchorTicks(), -10, "the anchor is inside the signed range");
        assertEq(hook.currentFee(id, false), BASE, "1for0: within the dead band");
        assertEq(hook.currentFee(id, true), BASE, "0for1: moving back pays nothing extra");
    }

    /// No dead band: the surcharge left by an in-range relay is what the range allows (8 ticks x 1.0 x 100 pips), not
    /// cfCap, and it is the same surcharge an honest anchor 8 ticks away would carry.
    function test_relayedSwitchOnInsideTheBounds_noBand_bounded() public {
        _configure(0);
        mover.run(k, -8, address(pokerSafe), _signedOn(-8, 8));
        assertEq(_anchorTicks(), -8);
        assertEq(_tick(), 0);
        assertEq(hook.currentFee(id, false), BASE + 800, "8 ticks x k 1.0 x 100 pips");
        assertLt(hook.currentFee(id, false), BASE + CF_CAP);
        assertEq(hook.currentFee(id, true), BASE);
    }

    /// The bounds are inclusive.
    function test_boundsAreInclusive() public {
        _configure(0);
        vm.startPrank(poker);
        hook.setCFActive(id, true, 0, 0, block.timestamp);
        hook.setCFActive(id, true, 0, 5, block.timestamp);
        hook.setCFActive(id, true, -5, 0, block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(FablesFeeEngine.CFTickOutOfRange.selector, int24(0)));
        hook.setCFActive(id, true, 1, 5, block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(FablesFeeEngine.CFTickOutOfRange.selector, int24(0)));
        hook.setCFActive(id, true, -5, -1, block.timestamp);
        vm.stopPrank();
    }

    /// Inverted bounds never switch on; switching off ignores the bounds (any values).
    function test_invertedBoundsRefuseOn_offIgnoresBounds() public {
        _configure(0);
        vm.startPrank(poker);
        vm.expectRevert(abi.encodeWithSelector(FablesFeeEngine.CFTickOutOfRange.selector, int24(0)));
        hook.setCFActive(id, true, 5, -5, block.timestamp);
        hook.setCFActive(id, true, -1, 1, block.timestamp);
        hook.setCFActive(id, false, 5, -5, block.timestamp);
        (, bool on) = hook.cfOf(id);
        assertFalse(on);
        hook.setCFActive(id, false, type(int24).max, type(int24).min, block.timestamp);
        vm.stopPrank();
    }

    /// Re-arming while on is bounded the same way: a relayed re-arm at a moved price reverts and keeps the anchor.
    function test_relayedRearmWhileOn_reverts() public {
        _configure(0);
        vm.prank(poker);
        hook.setCFActive(id, true, -2, 2, block.timestamp);
        uint256 cfBefore = hook.cfWord(id);
        vm.warp(block.timestamp + 30);
        vm.expectRevert(abi.encodeWithSelector(FablesFeeEngine.CFTickOutOfRange.selector, int24(-100)));
        mover.run(k, -100, address(pokerSafe), _signedOn(-10, 10));
        assertEq(hook.cfWord(id), cfBefore, "anchor kept");
    }

    /// The keeper's direct path: read the tick, send a narrow range around it; the anchor is the tick.
    function test_directKeeperSwitchOn() public {
        _configure(0);
        swap(k, true, -1e18, ""); // move the price off tick 0
        int24 t = _tick();
        assertLt(t, 0);
        vm.prank(poker);
        hook.setCFActive(id, true, t - 2, t + 2, block.timestamp);
        assertEq(_anchorTicks(), int256(t));
        assertEq(hook.currentFee(id, true), BASE);
        assertEq(hook.currentFee(id, false), BASE);
    }

    /// The signer approved [-10, 10] (a range no wider than the 20-tick band) with a 60 s deadline; the market
    /// moves to -100, so the keeper's relay reverts out of range and the Safe nonce stays unused. Ten minutes later a
    /// relayer moves the price to +10, lands the same signed call and restores -100: it reverts on the deadline.
    function test_staleSignedSwitchOnAfterItsDeadline_reverts() public {
        _configure(20);
        bytes memory signedCall = _signedOn(-10, 10, block.timestamp + 60);
        swapRouter.swap(
            k,
            IPoolManager.SwapParams(true, -1e30, TickMath.getSqrtPriceAtTick(-100)),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        int24 t = _tick();
        assertLe(t, -100);
        vm.expectRevert(abi.encodeWithSelector(FablesFeeEngine.CFTickOutOfRange.selector, t));
        pokerSafe.relay(address(hook), _innerOn(signedCall));
        vm.warp(block.timestamp + 600);
        uint256 cfBefore = hook.cfWord(id);
        vm.expectRevert(FablesFeeEngine.CFDeadlineExpired.selector);
        mover.run(k, 10, address(pokerSafe), signedCall);
        assertEq(hook.cfWord(id), cfBefore, "nothing written");
        (, bool on) = hook.cfOf(id);
        assertFalse(on);
        assertEq(hook.currentFee(id, true), BASE);
    }

    /// The same stale call while its deadline is still open lands with the anchor in range but far from the price:
    /// why the deadline must be short.
    function test_staleSignedSwitchOnWithinItsDeadline_isWhatTheDeadlineBounds() public {
        _configure(20);
        bytes memory signedCall = _signedOn(-10, 10, block.timestamp + 3600);
        swapRouter.swap(
            k,
            IPoolManager.SwapParams(true, -1e30, TickMath.getSqrtPriceAtTick(-100)),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        vm.warp(block.timestamp + 600);
        mover.run(k, 10, address(pokerSafe), signedCall);
        assertEq(_anchorTicks(), 10);
        assertLe(_tick(), -100);
        assertEq(hook.currentFee(id, true), BASE + CF_CAP, "inside the deadline the stale call still costs cfCap");
    }

    /// The deadline is inclusive, switching off ignores it.
    function test_deadlineInclusive_offIgnoresIt() public {
        _configure(0);
        vm.startPrank(poker);
        vm.expectRevert(FablesFeeEngine.CFDeadlineExpired.selector);
        hook.setCFActive(id, true, -1, 1, block.timestamp - 1);
        hook.setCFActive(id, true, -1, 1, block.timestamp);
        hook.setCFActive(id, false, 0, 0, 0);
        (, bool on) = hook.cfOf(id);
        assertFalse(on);
        vm.stopPrank();
    }

    /// `_signedOn`'s inner setCFActive call data (the Safe's target call).
    function _innerOn(bytes memory relayCall) internal pure returns (bytes memory inner) {
        bytes memory args = new bytes(relayCall.length - 4);
        for (uint256 i; i < args.length; i++) {
            args[i] = relayCall[i + 4];
        }
        (, inner) = abi.decode(args, (address, bytes));
    }

    /// forge-config: default.fuzz.runs = 1024
    /// Switching on lands exactly when minTick <= tick <= maxTick, and then anchors at the tick.
    function testFuzz_switchOnLandsIffTheTickIsInBounds(int24 lo, int24 hi, int24 to, uint256 deadline) public {
        _configure(0);
        to = int24(bound(to, -5_000, 5_000));
        if (to != 0) {
            (uint160 p0,,,) = manager.getSlot0(id);
            uint160 target = TickMath.getSqrtPriceAtTick(to);
            swapRouter.swap(
                k, IPoolManager.SwapParams(target < p0, -1e30, target), PoolSwapTest.TestSettings(false, false), ""
            );
        }
        int24 t = _tick();
        vm.warp(10_000);
        deadline = bound(deadline, block.timestamp - 100, block.timestamp + 100);
        bool live = block.timestamp <= deadline;
        bool inBounds = lo <= t && t <= hi;
        vm.prank(poker);
        if (!live) vm.expectRevert(FablesFeeEngine.CFDeadlineExpired.selector);
        else if (!inBounds) vm.expectRevert(abi.encodeWithSelector(FablesFeeEngine.CFTickOutOfRange.selector, t));
        hook.setCFActive(id, true, lo, hi, deadline);
        (, bool on) = hook.cfOf(id);
        assertEq(on, live && inBounds);
        if (live && inBounds) assertEq(_anchorTicks(), int256(t));
    }
}
