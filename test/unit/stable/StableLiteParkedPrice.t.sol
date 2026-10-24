// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import "../../utils/StableTestBase.sol";

/// @notice A price parked beyond the 10% fee window reads as the window edge: after the price is walked through empty
///         ticks beyond every range and time passes, the trade back pays at least the fee at the edge.
abstract contract StableLiteParkedPriceBase is StableTestBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint256 internal constant SQRT_MIN_RATIO_X96 = 75162434512514379355924140470;
    int24 internal constant RANGE = 600;

    SeqSwapper internal sw;
    address internal parked;
    address internal edge;
    PoolKey internal kp;
    PoolKey internal ke;
    /// @dev In-range liquidity of `kp` once parked: none, unless an outside LP holds the parked range.
    uint128 internal parkedLiquidity;

    function setUp() public {
        setUpChain();
        sw = new SeqSwapper(pm);
        MockERC20(Currency.unwrap(c0)).mint(address(sw), BIG);
        MockERC20(Currency.unwrap(c1)).mint(address(sw), BIG);
        parked = _deployLite("pk-parked");
        edge = _deployLite("pk-edge");
        kp = PoolKey(c0, c1, DYN, 1, IHooks(parked));
        ke = PoolKey(c0, c1, DYN, 1, IHooks(edge));
        StableFeeConfig memory c =
            StableFeeConfig({k: K07, optimalFeeE6: 50, targetMultiplier: 100, referenceSqrtPriceX96: _refSqrt()});
        _createPool(parked, kp, _refSqrt(), c);
        _createPool(edge, ke, _refSqrt(), c);
        _addLiq(parked, kp, INIT_TICK - RANGE, INIT_TICK + RANGE, 1e24);
        _addLiq(edge, ke, INIT_TICK - RANGE, INIT_TICK + RANGE, 1e24);
    }

    function _edgePrice(bool below) internal pure returns (uint160) {
        uint256 ref = _refSqrt();
        return uint160(below ? ref * SQRT_MIN_RATIO_X96 / (1 << 96) : ref * (1 << 96) / SQRT_MIN_RATIO_X96);
    }

    function _walk(PoolKey memory k, uint160 to) internal {
        (uint160 p,,,) = pm.getSlot0(k.toId());
        (bool ok,) = sw.swap(k, to < p, -1e30, to);
        assertTrue(ok, "walk");
        (p,,,) = pm.getSlot0(k.toId());
        assertEq(p, to, "walked to the target");
    }

    function _tradeBack(PoolKey memory k, bool below, int256 amount) internal returns (uint24 fee) {
        vm.recordLogs();
        (bool ok,) = sw.swap(k, !below, amount, below ? TickMath.MAX_SQRT_PRICE - 1 : TickMath.MIN_SQRT_PRICE + 1);
        assertTrue(ok, "trade back");
        bool found;
        (found, fee) = _swapEventFee(vm.getRecordedLogs(), k.toId());
        assertTrue(found, "no Swap event");
    }

    /// @notice Walks `kp` to `parkedAt` and `ke` to the window edge in one block, waits `gap` blocks, then trades back
    ///         on both in one block.
    function _parkWaitTradeBack(bool below, uint160 parkedAt, uint256 gap) internal returns (uint24 fp, uint24 fe) {
        _rollClock(1);
        _walk(kp, parkedAt);
        _walk(ke, _edgePrice(below));
        assertEq(pm.getLiquidity(kp.toId()), parkedLiquidity, "parked liquidity");
        _rollClock(gap);
        (uint24 p0, uint24 p1) = _getFee(parked, kp);
        (uint24 e0, uint24 e1) = _getFee(edge, ke);
        assertEq(abi.encode(p0, p1), abi.encode(e0, e1), "quotes: parked == edge");
        fp = _tradeBack(kp, below, -1e18);
        fe = _tradeBack(ke, below, -1e18);
        assertEq(fp, below ? p1 : p0, "charged == quoted");
    }

    function test_parkedBeyondEveryRange_tradeBackPaysAtLeastTheEdgeFee() public {
        uint256[4] memory gaps = [uint256(1), 5, 60, 5000];
        for (uint256 b; b < 2; b++) {
            bool below = b == 0;
            int24 far = below ? INIT_TICK - 2400 : INIT_TICK + 2400;
            for (uint256 i; i < gaps.length; i++) {
                uint256 snap = vm.snapshotState();
                (uint24 fp, uint24 fe) = _parkWaitTradeBack(below, TickMath.getSqrtPriceAtTick(far), gaps[i]);
                assertGe(fp, fe, "the trade back pays at least the edge fee");
                assertEq(fp, fe, "a parked price reads as the edge");
                assertGt(fp, 0, "the trade back pays");
                vm.revertToState(snap);
            }
        }
    }

    /// forge-config: default.fuzz.runs = 256
    function testFuzz_beyondTheWindowReadsAsTheEdge(bool below, uint256 beyond, uint256 gap) public {
        uint256 e = _edgePrice(below);
        beyond = bound(beyond, 1, 4000);
        uint160 at = uint160(below ? e - e * beyond / 10_000 : e + e * beyond / 10_000);
        (uint24 fp, uint24 fe) = _parkWaitTradeBack(below, at, bound(gap, 0, 10_000));
        assertEq(fp, fe, "fee beyond the window == fee at its edge");
        (uint40 d1, uint160 s1, uint40 b1) = FablesStableHookLite(parked).feeState(kp.toId());
        (uint40 d2, uint160 s2, uint40 b2) = FablesStableHookLite(edge).feeState(ke.toId());
        assertEq(abi.encode(d1, s1, b1), abi.encode(d2, s2, b2), "state written beyond the window == at its edge");
    }
}

/// @notice On FablesStableHookLite, plus an outside LP holding a far range beyond the window.
contract StableLiteParkedPriceTest is StableLiteParkedPriceBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    function test_parkedInAnOutsideFarRange_tradeBackPaysAtLeastTheEdgeFee() public {
        int24 lo = INIT_TICK - 2600;
        int24 hi = INIT_TICK - 2000;
        _addDirect(kp, lo, hi, 1e23);
        parkedLiquidity = 1e23;
        uint256[3] memory gaps = [uint256(1), 60, 5000];
        for (uint256 i; i < gaps.length; i++) {
            uint256 snap = vm.snapshotState();
            (uint24 fp, uint24 fe) = _parkWaitTradeBack(true, TickMath.getSqrtPriceAtTick(INIT_TICK - 2300), gaps[i]);
            assertEq(pm.getLiquidity(kp.toId()), 1e23, "the trade back starts in the outside LP's range");
            assertGe(fp, fe, "the trade back pays at least the edge fee");
            assertGt(fp, 0, "the trade back pays");
            vm.revertToState(snap);
        }
    }
}

/// @notice On FablesStableHookLiteExclusive.
contract StableLiteParkedPriceExclusiveTest is StableLiteParkedPriceBase {
    function _exclusive() internal pure override returns (bool) {
        return true;
    }
}
