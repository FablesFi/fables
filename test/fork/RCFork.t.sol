// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {console} from "forge-std/console.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";

import {RCBytecodeHarness, IsolateProbe} from "../utils/RCBytecodeHarness.sol";
import {RCForkHelpers, RCAddresses} from "../utils/ForkHelpers.sol";
import {FablesStableHookLite} from "../../src/FablesStableHookLite.sol";
import {StableFeeConfig} from "../../src/base/FablesStableFee.sol";

/// @notice Read-only Robinhood Chain fork tests on real USDe / USDG. Skipped unless `RC_RPC_URL` is set.
contract RCForkTest is RCBytecodeHarness, RCForkHelpers {
    uint24 internal constant K07 = 11_744_051;
    uint24 internal constant OPT_50 = 50;
    uint8 internal constant TM_100 = 100;
    /// @dev Stable Lite first-of-block swap over a hookless 50-pip pool, execution gas (block.number clock).
    uint256 internal constant LITE_DELTA_BOUND = 14_600;

    function setUp() public {
        forkOrSkip();
        probe = new IsolateProbe();
        liq = liqRC;
        swapRouter = new PoolSwapTest(pm);
        fundRC(RCAddresses.USDE, trader, 1e24);
        fundRC(RCAddresses.USDG, trader, 1e12);
        deal(RCAddresses.USDE, address(liq), 1e27);
        deal(RCAddresses.USDG, address(liq), 1e15);
        deal(RCAddresses.USDE, address(this), 1e25);
        deal(RCAddresses.USDG, address(this), 1e13);
        IERC20(RCAddresses.USDE).approve(address(swapRouter), type(uint256).max);
        IERC20(RCAddresses.USDG).approve(address(swapRouter), type(uint256).max);
    }

    function test_pinnedBlockAndTokens() public view {
        assertEq(block.chainid, RCAddresses.CHAIN_ID);
        assertEq(block.number, forkBlock);
        assertEq(IERC20Metadata(RCAddresses.USDE).decimals(), RCAddresses.USDE_DECIMALS, "USDe 18");
        assertEq(IERC20Metadata(RCAddresses.USDG).decimals(), RCAddresses.USDG_DECIMALS, "USDG 6");
        assertTrue(RCAddresses.USDE < RCAddresses.USDG, "USDe is currency0");
        assertEq(RCAddresses.POOL_MANAGER, PM_ADDR, "same PoolManager address");
    }

    function test_hooklessUsdeUsdgSwapViaUR() public {
        PoolKey memory k = usdeUsdgKey(address(0), 100, 1);
        (,, int24 tickNow) = createPoolIfNeeded(k, parityPriceUsdeUsdg());
        addLiquidity(k, tickNow - 1000, tickNow + 1000, 1e17);
        warm(k, 10e18, 10e6);
        GasSample memory s0 = swapUR(k, true, 100e18);
        GasSample memory s1 = swapUR(k, false, 100e6);
        logRow("fork_hookless_USDe_USDG_1bp", "single_0for1", s0);
        logRow("fork_hookless_USDe_USDG_1bp", "single_1for0", s1);
        assertGt(s0.execGas, 30_000);
        (BalanceDelta d,) = swapPST(k, true, -100e18);
        assertApproxEqRel(uint256(int256(d.amount1())), 100e6, 0.02e18, "near parity, ~100 USDG out");
    }

    /// @notice Stable Lite on the real pair: an in-band first-of-block swap against a hookless 50-pip pool. Foundry
    ///         does not run the ArbSys precompile on a fork, so the hook latches the block.number clock here.
    function test_stableLiteInBandFirstOfBlock() public {
        AccessManager authority = new AccessManager(address(this));
        address lite = flagged("fork.stableLite", FLAGS_STABLE_LITE);
        vm.etch(address(0x64), "");
        deployCodeTo("FablesStableHookLite.sol:FablesStableHookLite", abi.encode(PM_ADDR, address(authority)), lite);
        PoolKey memory kl = usdeUsdgKey(lite, 0, 1);
        uint160 ref = parityPriceUsdeUsdg();
        FablesStableHookLite(lite)
            .configureStablePool(
                kl,
                ref,
                StableFeeConfig({k: K07, optimalFeeE6: OPT_50, targetMultiplier: TM_100, referenceSqrtPriceX96: ref})
            );
        IERC20(RCAddresses.USDE).approve(lite, type(uint256).max);
        IERC20(RCAddresses.USDG).approve(lite, type(uint256).max);
        int24 lo = RCAddresses.USDE_USDG_PARITY_TICK - 72;
        int24 hi = RCAddresses.USDE_USDG_PARITY_TICK + 72;
        FablesStableHookLite(lite).deposit(kl, lo, hi, 1e21, type(uint128).max, type(uint128).max, block.timestamp);
        PoolKey memory kv = usdeUsdgKey(address(0), OPT_50, 1);
        (,, int24 tickNow) = createPoolIfNeeded(kv, ref);
        addLiquidity(kv, tickNow - 72, tickNow + 72, 1e21);
        warm(kl, 10e18, 10e6);
        warm(kv, 10e18, 10e6);
        vm.roll(block.number + 1);
        GasSample memory base = swapUR(kv, true, 100e18);
        vm.roll(block.number + 1);
        GasSample memory l = swapUR(kl, true, 100e18);
        logRow("fork_hookless50_USDe_USDG", "single_0for1", base);
        logRow("fork_stableLite_USDe_USDG", "single_0for1_firstOfBlock", l);
        int256 d = execDelta(l, base);
        console.log("Stable Lite exec delta over hookless:", d);
        if (l.isolated) assertLe(d, int256(LITE_DELTA_BOUND), "Stable Lite first-of-block above the bound");
    }
}
