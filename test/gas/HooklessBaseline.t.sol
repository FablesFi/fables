// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {HooklessBaseline} from "../utils/RCBytecodeHarness.sol";
import {RCBytecode} from "../utils/RCBytecode.sol";
import {FixedFeeHook} from "../utils/mocks/FixedFeeHook.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {console} from "forge-std/console.sol";

/// @notice The etched Robinhood Chain bytecode runs locally; hookless and fixed-fee-hook swaps through the router and
///         PoolSwapTest.
contract HooklessBaselineTest is HooklessBaseline {
    using PoolIdLibrary for PoolKey;

    address hook;
    uint24 constant FEE = 3000;

    function setUp() public {
        setUpRC();
        hook = flagged("harness.fixedFeeHook", FLAGS_FEE_FULL);
        deployCodeTo("FixedFeeHook.sol:FixedFeeHook", abi.encode(pm, FEE), hook);
        vm.label(hook, "FixedFeeHook");
    }

    function test_rcBytecodeIsTheRealThing() public view {
        assertEq(PM_ADDR.code.length, RCBytecode.PM_CODESIZE, "PoolManager size");
        assertEq(UR_ADDR.code.length, RCBytecode.UR_CODESIZE, "UniversalRouter size");
        assertEq(PERMIT2_ADDR.code.length, RCBytecode.PERMIT2_CODESIZE, "Permit2 size");
        assertEq(keccak256(PM_ADDR.code), RCBytecode.PM_CODEHASH, "PoolManager hash");
        assertEq(keccak256(UR_ADDR.code), RCBytecode.UR_CODEHASH, "UniversalRouter hash");
        assertEq(keccak256(PERMIT2_ADDR.code), RCBytecode.PERMIT2_CODEHASH, "Permit2 hash");
        assertEq(block.chainid, RC_CHAIN_ID);
    }

    function test_hooklessSwapsViaUR_printGas() public {
        Baseline memory b = hooklessBaseline(defaultShape());
        logBaseline("hookless", b);
        console.log("isolated:", b.single0for1.isolated);
        assertGt(b.single0for1.execGas, 30_000, "a swap executes");
        assertGt(b.twoHop.execGas, b.single0for1.execGas, "2 hops cost more than 1");
        assertGt(b.doubleSamePool.execGas, b.single0for1.execGas, "2 swaps cost more than 1");
        if (b.single0for1.isolated) {
            assertApproxEqAbs(b.single0for1.txGas, 118_677, 3_000, "hookless tx gas");
            assertApproxEqAbs(b.single0for1.execGas, 91_501, 3_000, "hookless exec gas");
        }
    }

    function test_hooklessSwapViaPoolSwapTest_deltaSigns() public {
        PoolKey memory k = poolKey(c0, c1, FEE, 60, address(0));
        seedAndWarm(k, TickMath.getSqrtPriceAtTick(MID_WORD_TICK), 1e24, 1e18);
        (BalanceDelta d, GasSample memory s) = swapPST(k, true, -1e18);
        assertEq(d.amount0(), -1e18, "exact input paid");
        assertGt(d.amount1(), 0, "output received");
        assertGt(s.execGas, 30_000);
        (d,) = swapPST(k, false, -1e18);
        assertEq(d.amount1(), -1e18);
        assertGt(d.amount0(), 0);
    }

    function test_fixedFeeHook_overUR_deltaVsHookless() public {
        Shape memory sh = defaultShape();
        Baseline memory base = hooklessBaseline(sh);
        PoolKey memory k1 = dynamicKey(c0, c1, sh.tickSpacing, hook);
        PoolKey memory k2 = dynamicKey(c1, c2, sh.tickSpacing, hook);
        seedAndWarm(k1, sh.sqrtPriceX96, sh.liquidity, sh.amountIn);
        seedAndWarm(k2, sh.sqrtPriceX96, sh.liquidity, sh.amountIn);
        Baseline memory h = measureHooked(k1, k2, sh.amountIn);
        logBaseline("fixedFeeHook", h);
        int256 d1 = execDelta(h.single0for1, base.single0for1);
        int256 d2 = execDelta(h.twoHop, base.twoHop);
        console.log("delta single (exec):", d1);
        console.log("delta 2-hop  (exec):", d2);
        assertGt(d1, 0, "a beforeSwap hook costs something");
        assertLt(d1, 12_000, "a 1-slot Solidity hook is < 12k over vanilla");
        assertGt(d2, d1, "two hooked hops cost more than one");
        if (h.single0for1.isolated) {
            assertApproxEqAbs(uint256(d1), 7_565, 1_500, "1-slot Solidity hook delta");
        }
    }

    function test_fixedFeeHook_feeOverrideEqualsStaticFee() public {
        uint160 p = TickMath.getSqrtPriceAtTick(MID_WORD_TICK);
        PoolKey memory v = poolKey(c0, c1, FEE, 60, address(0));
        PoolKey memory hk = dynamicKey(c0, c1, 60, hook);
        createPool(v, p);
        createPool(hk, p);
        addFullRange(v, 1e24);
        addFullRange(hk, 1e24);
        (BalanceDelta dv,) = swapPST(v, true, -1e18);
        (BalanceDelta dh,) = swapPST(hk, true, -1e18);
        assertEq(dh.amount1(), dv.amount1(), "override 3000 == static 3000 through the real PoolManager");

        FixedFeeHook(hook).setFee(10_000);
        (BalanceDelta dh2,) = swapPST(hk, true, -1e18);
        assertLt(dh2.amount1(), dv.amount1(), "a higher override fee pays out less");
    }

    function test_hookOnlyGas_decodesFee() public {
        PoolKey memory k1 = dynamicKey(c0, c1, 60, hook);
        createPool(k1, TickMath.getSqrtPriceAtTick(MID_WORD_TICK));
        (uint256 g, bytes memory ret) = hookOnlyGas(hook, k1, true, -1e18);
        assertEq(feeFromBeforeSwapReturn(ret), FEE);
        assertGt(g, 0);
        console.log("FixedFeeHook hook-only exec gas (cold slot):", g);
    }

    function test_flaggedAddressCarriesFlags() public pure {
        assertEq(uint160(flagged("x", FLAGS_FEE_FULL)) & 0x3FFF, FLAGS_FEE_FULL);
        assertEq(uint160(flagged("y", FLAGS_STABLE_LITE)) & 0x3FFF, FLAGS_STABLE_LITE);
        assertTrue(flagged("x", FLAGS_FEE_FULL) != flagged("y", FLAGS_FEE_FULL));
    }
}

/// @notice Same harness with 6-decimal tokens.
contract HooklessBaselineSixDecimalsTest is HooklessBaseline {
    function setUp() public {
        setUpRC(6, 18, 6);
    }

    function test_sixDecimalPoolSwaps() public {
        Shape memory sh = Shape({
            fee: 100,
            tickSpacing: 1,
            sqrtPriceX96: TickMath.getSqrtPriceAtTick(MID_WORD_TICK),
            liquidity: 1e20,
            amountIn: 1e6
        });
        Baseline memory b = hooklessBaseline(sh);
        logBaseline("hookless_6dec_1bp", b);
        assertGt(b.single0for1.execGas, 30_000);
        assertTrue(tokA.decimals() == 6 || tokB.decimals() == 6 || tokC.decimals() == 6);
    }
}
