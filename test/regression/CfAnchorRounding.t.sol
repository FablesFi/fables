// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {FablesHook} from "../../src/FablesHook.sol";
import {FeeRef} from "../../src/libraries/FeeRef.sol";

/// @notice The CF anchor step truncates toward the tick in both directions, in the assembly entry and in FeeRef.
contract CfAnchorRoundingTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;

    FablesHook hook;
    address hookAddr;
    PoolKey k;
    PoolId id;

    function setUp() public {
        deployFreshManagerAndRouters();
        AccessManager authority = new AccessManager(address(this));
        hookAddr = address(uint160(0x2222 << 144) | uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG));
        deployCodeTo("FablesHook.sol:FablesHook", abi.encode(manager, address(authority)), hookAddr);
        hook = FablesHook(payable(hookAddr));
        vm.warp(1_800_000_000);
        k = PoolKey(
            Currency.wrap(address(0x1111)),
            Currency.wrap(address(0x2222)),
            LPFeeLibrary.DYNAMIC_FEE_FLAG,
            1,
            IHooks(hookAddr)
        );
        id = k.toId();
        hook.setCategory(1, 0, 100_000, 1_000, "c");
        hook.configurePool(k, 1, 3_000, 3_000, 0, 10_000);
        _setTick(0);
        hook.configureCF(id, 0, 256, 2_500, 0, 300, 1);
        hook.setCFActive(id, true, TickMath.MIN_TICK, TickMath.MAX_TICK, type(uint256).max);
    }

    function test_upMoveConvergesToTheTick() public {
        (uint256 f0, uint256 f1) = _flat(100, 3_000);
        assertEq(_anchor(), 100 * 256, "anchor stalled below the tick");
        assertEq(f0, 3_000);
        assertEq(f1, 3_000, "oneForZero surcharge on a flat price");
    }

    function test_downMoveConvergesToTheTick() public {
        _setTick(100);
        hook.setCFActive(id, true, TickMath.MIN_TICK, TickMath.MAX_TICK, type(uint256).max);
        (uint256 f0, uint256 f1) = _flat(0, 3_000);
        assertEq(_anchor(), 0);
        assertEq(f0, 3_000);
        assertEq(f1, 3_000);
    }

    function test_feeRefConvergesBothWays() public pure {
        _converges(0, 100, 300, 1, 5_000);
        _converges(100, 0, 300, 1, 5_000);
        _converges(0, 100, 60, 1, 5_000);
        _converges(100, 0, 60, 1, 5_000);
        _converges(0, 100, 300, 12, 2_000);
        _converges(100, 0, 300, 12, 2_000);
    }

    function testFuzz_anchorStepIsMirrorSymmetric(int24 tick, uint32 d, uint16 tau, uint8 dt) public pure {
        tick = int24(bound(tick, -887_272, 887_272));
        tau = uint16(bound(tau, 5, 300));
        dt = uint8(bound(dt, 1, 254));
        int256 t = int256(tick) * 256;
        int256 gap = int256(bound(d, 1, uint256(int256(type(int32).max) - (t < 0 ? -t : t))));
        uint256 above = _cf(tau, 1, int32(t + gap), 0);
        uint256 below = _cf(tau, 1, int32(t - gap), 0);
        (, uint256 nAbove) = FeeRef.cfStep(above, tick, true, dt);
        (, uint256 nBelow) = FeeRef.cfStep(below, tick, true, dt);
        int256 aAbove = FeeRef.unpackCF(nAbove).anchor;
        int256 aBelow = FeeRef.unpackCF(nBelow).anchor;
        assertEq(aAbove - t, t - aBelow, "asymmetric step");
        assertLt(aAbove - t, gap, "gap did not shrink");
    }

    function _cf(uint16 tau, uint8 period, int32 anchor, uint40 tLast) internal pure returns (uint256) {
        uint256 maxAge = 5 * uint256(tau);
        if (maxAge > 255) maxAge = 255;
        return FeeRef.packCF(
            FeeRef.CFWord({
                tLast: tLast,
                anchor: anchor,
                decay1: FeeRef.decay1Q32(tau),
                kQ8: 256,
                cfCap: 2_500,
                band16: 0,
                maxAge: uint8(maxAge),
                period: period,
                tau: tau,
                mode: 0
            })
        );
    }

    function _converges(int24 fromTick, int24 toTick, uint16 tau, uint256 gap, uint256 steps) internal pure {
        uint256 ts = 1_000_000;
        uint256 cf = _cf(tau, 1, int32(int256(fromTick) * 256), uint40(ts));
        uint256 s0;
        uint256 s1;
        for (uint256 i; i < steps; ++i) {
            ts += gap;
            (s0, cf) = FeeRef.cfStep(cf, toTick, true, ts);
            (s1,) = FeeRef.cfStep(cf, toTick, false, ts);
        }
        assertEq(FeeRef.unpackCF(cf).anchor, int256(toTick) * 256, "anchor off the tick");
        assertEq(s0 + s1, 0, "surcharge on a flat price");
    }

    function _setTick(int24 t) internal {
        bytes32 slot = keccak256(abi.encodePacked(PoolId.unwrap(id), StateLibrary.POOLS_SLOT));
        vm.store(address(manager), slot, bytes32((uint256(uint24(t)) << 160) | uint256(TickMath.getSqrtPriceAtTick(t))));
    }

    function _fee(bool zfo) internal returns (uint256) {
        bytes memory cd = abi.encodeCall(
            IHooks.beforeSwap,
            (
                address(0xBEEF),
                k,
                IPoolManager.SwapParams({
                    zeroForOne: zfo,
                    amountSpecified: -1e18,
                    sqrtPriceLimitX96: zfo ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
                }),
                ""
            )
        );
        vm.prank(address(manager));
        (bool ok, bytes memory ret) = hookAddr.call(cd);
        assertTrue(ok, "beforeSwap reverted");
        (,, uint256 w) = abi.decode(ret, (bytes32, int256, uint256));
        return w ^ 0x400000;
    }

    function _flat(int24 t, uint256 secs) internal returns (uint256 f0, uint256 f1) {
        _setTick(t);
        for (uint256 i; i < secs; ++i) {
            vm.warp(block.timestamp + 1);
            _fee(i % 2 == 0);
        }
        f0 = _fee(true);
        f1 = _fee(false);
    }

    function _anchor() internal view returns (int256) {
        return FeeRef.unpackCF(hook.cfWord(id)).anchor;
    }
}
