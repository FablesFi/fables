// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {console} from "forge-std/console.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {HooklessBaseline} from "../utils/RCBytecodeHarness.sol";
import {FullHarness} from "../utils/FullHarness.sol";

/// @notice FablesHook swap gas as execution-gas deltas over a hookless pool of the same shape.
contract FullGasTest is HooklessBaseline {
    using PoolIdLibrary for PoolKey;

    uint8 constant CAT = 1;
    FullHarness hook;
    address hookAddr;
    AccessManager authority;
    PoolKey k1;
    PoolKey k2;
    PoolId id1;
    Shape sh;

    function setUp() public {
        setUpRC();
        authority = new AccessManager(address(this));
        hookAddr = flagged("full.gas", FLAGS_FEE_FULL);
        deployCodeTo("FullHarness.sol:FullHarness", abi.encode(pm, address(authority)), hookAddr);
        hook = FullHarness(hookAddr);
        vm.label(hookAddr, "FullHarness");
        sh = defaultShape();
        hook.setCategory(CAT, 0, 100_000, 100_000, "ANY");
        k1 = dynamicKey(c0, c1, sh.tickSpacing, hookAddr);
        k2 = dynamicKey(c1, c2, sh.tickSpacing, hookAddr);
        id1 = k1.toId();
        hook.configurePool(k1, CAT, sh.fee, sh.fee, 0, 50_000);
        hook.configurePool(k2, CAT, sh.fee, sh.fee, 0, 50_000);
        _seedAndWarmHooked(k1, sh.sqrtPriceX96, sh.liquidity, sh.amountIn);
        _seedAndWarmHooked(k2, sh.sqrtPriceX96, sh.liquidity, sh.amountIn);
    }

    function _seedAndWarmHooked(PoolKey memory key, uint160 sqrtPriceX96, int256 liquidity, uint128 warmAmount)
        internal
    {
        hook.initializePool(key, sqrtPriceX96);
        addFullRange(key, liquidity);
        warm(key, warmAmount);
    }

    function _ids1() internal view returns (PoolId[] memory ids) {
        ids = new PoolId[](1);
        ids[0] = id1;
    }

    function _logDelta(string memory name, GasSample memory hooked, GasSample memory base) internal pure {
        console.log(string.concat("DELTA|", name, "|"), execDelta(hooked, base));
    }

    function test_G_fullColdVsHookless() public {
        Baseline memory base = hooklessBaseline(sh);
        Baseline memory h = measureHooked(k1, k2, sh.amountIn);
        logBaseline("hookless", base);
        logBaseline("full", h);
        _logDelta("single_0for1", h.single0for1, base.single0for1);
        _logDelta("single_1for0", h.single1for0, base.single1for0);
        _logDelta("double_same_pool", h.doubleSamePool, base.doubleSamePool);
        _logDelta("twohop", h.twoHop, base.twoHop);
        _logDelta("pst_0for1", h.pst0for1, base.pst0for1);
        assertEq(hook.currentFee(id1, true), sh.fee, "apples to apples: same fee as the vanilla pool");
        if (h.single0for1.isolated) {
            assertLe(execDelta(h.single0for1, base.single0for1), 7_000, "gas: FablesHook cold <= +7.0k");
            assertLe(execDelta(h.single1for0, base.single1for0), 7_000, "gas: FablesHook cold (1for0) <= +7.0k");
            assertLe(execDelta(h.twoHop, base.twoHop), 14_000, "gas: two hooked hops <= 2 x 7.0k");
        }
    }

    function test_G_listedSender_cfOff_cfOn() public {
        Baseline memory base = hooklessBaseline(sh);
        GasSample memory full = swapUR(k1, true, sh.amountIn);
        logRow("full", "cold", full);

        hook.setDiscount(_ids1(), UR_ADDR, 1_000, 0, 3, uint40(block.timestamp + 1 days));
        assertEq(hook.feeFor(id1, true, UR_ADDR), 2_700, "discount in force");
        GasSample memory listed = swapUR(k1, true, sh.amountIn);
        logRow("full", "listed_sender", listed);
        address[] memory none = new address[](0);
        hook.setDiscountFilter(id1, 0, none);
        hook.setDiscount(_ids1(), UR_ADDR, 0, 0, 0, 0);

        hook.configureCF(id1, 0, 256, 2_500, 0, 60, 1);
        GasSample memory cfOff = swapUR(k1, true, sh.amountIn);
        logRow("full", "cf_configured_off", cfOff);

        hook.setCFActive(id1, true, TickMath.MIN_TICK, TickMath.MAX_TICK, type(uint256).max);
        GasSample memory cfRead = swapUR(k1, true, sh.amountIn);
        logRow("full", "cf_on_read", cfRead);
        assertEq(hook.cfWord(id1) & 0xffffffffff, block.timestamp, "armed now: no write due");

        vm.warp(block.timestamp + 2);
        GasSample memory cfWrite = swapUR(k1, true, sh.amountIn);
        logRow("full", "cf_on_write", cfWrite);
        assertEq(hook.cfWord(id1) & 0xffffffffff, block.timestamp, "CF word written");

        _logDelta("full_cold_vs_hookless", full, base.single0for1);
        _logDelta("listed_vs_hookless", listed, base.single0for1);
        _logDelta("cf_off_vs_full", cfOff, full);
        _logDelta("cf_read_vs_full", cfRead, full);
        _logDelta("cf_write_vs_full", cfWrite, full);
        if (full.isolated) {
            assertLe(execDelta(full, base.single0for1), 7_000, "gas: FablesHook cold <= +7.0k");
            assertLe(execDelta(listed, base.single0for1), 9_800, "gas: listed sender <= +9.8k");
            assertLe(execDelta(cfOff, full), 150, "gas: CF configured but off <= +150");
            assertLe(execDelta(cfWrite, full), 6_800, "gas: CF write <= +6.8k");
        }
    }

    function test_G_hookOnly() public {
        (uint256 g, bytes memory ret) = hookOnlyGas(hookAddr, k1, true, -int256(uint256(sh.amountIn)));
        assertEq(feeFromBeforeSwapReturn(ret), sh.fee);
        console.log("ROW|full|hook_only_cold|", g);
        hook.setDiscount(_ids1(), UR_ADDR, 1_000, 0, 3, uint40(block.timestamp + 1 days));
        (uint256 gl, bytes memory retl) = hookOnlyGas(hookAddr, k1, true, -int256(uint256(sh.amountIn)));
        assertEq(feeFromBeforeSwapReturn(retl), 2_700);
        console.log("ROW|full|hook_only_listed|", gl);
        if (isolated()) {
            assertLt(g, 5_000, "one SLOAD and arithmetic");
            assertLt(gl, 8_000, "two SLOADs and arithmetic");
        }
    }
}
