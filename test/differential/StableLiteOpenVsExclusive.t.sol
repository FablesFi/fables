// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import "../utils/StableTestBase.sol";

/// @notice The stable fee depends on price and blocks only: along one price path, FablesStableHookLite without and with
///         outside liquidity and FablesStableHookLiteExclusive quote and charge the same fee and keep the same state.
contract StableLiteOpenVsExclusiveTest is StableTestBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    int24 internal constant SPACING = 10;
    uint256 internal constant STEPS = 24;

    address[3] internal hooks;
    SeqSwapper internal sw;

    struct Run {
        PoolKey[3] k;
        PoolId[3] id;
        uint256 swaps;
        uint256 charged;
    }

    function setUp() public {
        setUpChain();
        hooks[0] = _deployBuild("ox-open", false);
        hooks[1] = _deployBuild("ox-open-outside", false);
        hooks[2] = _deployBuild("ox-exclusive", true);
        sw = new SeqSwapper(pm);
        MockERC20(Currency.unwrap(c0)).mint(address(sw), BIG);
        MockERC20(Currency.unwrap(c1)).mint(address(sw), BIG);
    }

    function _r(uint256 seed, uint256 i) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(seed, i, "ox")));
    }

    function _cfg(uint256 x) internal pure returns (StableFeeConfig memory c) {
        c.k = x % 3 == 0 ? uint24(1 + (x >> 8) % ((1 << 24) - 1)) : K07;
        uint256 o = (x >> 32) % 3;
        c.optimalFeeE6 = o == 0 ? 7 : (o == 1 ? 50 : uint24((x >> 40) % 10_001));
        c.targetMultiplier = (x >> 64) % 2 == 0 ? 100 : uint8(1 + (x >> 72) % 100);
        c.referenceSqrtPriceX96 = _refSqrt();
    }

    /// forge-config: default.fuzz.runs = 256
    function testFuzz_sameFeeOnBothBuilds_withAndWithoutOutsideLiquidity(uint256 seed) public {
        Run memory R;
        _setupRun(R, seed);
        for (uint256 s = 1; s <= STEPS; s++) {
            uint256 y = _r(seed, s);
            if (y % 10 < 8) {
                _rollClock((y >> 8) % 6);
                int24 span = (y >> 16) % 5 == 0 ? int24(1500) : int24(600);
                _swapAll(R, INIT_TICK + int24(int256((y >> 24) % uint256(int256(2 * span + 1)))) - span);
            } else {
                StableFeeConfig memory c2 = _cfg(y >> 8);
                for (uint256 i; i < 3; i++) {
                    _updateConfig(hooks[i], R.k[i], c2);
                }
                _cmpState(R, "config");
            }
        }
        assertGt(R.swaps, 0, "no swap ran");
    }

    /// @dev Same config, start price and ledger liquidity in the three pools; outside positions in pool 1 only.
    function _setupRun(Run memory R, uint256 seed) internal {
        uint256 x = _r(seed, 0);
        StableFeeConfig memory c = _cfg(x);
        uint160 start = TickMath.getSqrtPriceAtTick(INIT_TICK + int24(int256((x >> 96) % 401)) - 200);
        for (uint256 i; i < 3; i++) {
            R.k[i] = PoolKey(c0, c1, DYN, SPACING, IHooks(hooks[i]));
            R.id[i] = R.k[i].toId();
            _createPool(hooks[i], R.k[i], start, c);
            _addLiq(hooks[i], R.k[i], TickMath.minUsableTick(SPACING), TickMath.maxUsableTick(SPACING), 1e21);
            _addLiq(hooks[i], R.k[i], INIT_TICK - 400, INIT_TICK + 400, 1e24);
        }
        uint256 n = 1 + (x >> 128) % 4;
        for (uint256 j; j < n; j++) {
            uint256 y = _r(seed, 100 + j);
            int24 lo = INIT_TICK + (int24(int256(y % 121)) - 60) * SPACING;
            _addDirect(R.k[1], lo, lo + int24(int256(1 + (y >> 8) % 60)) * SPACING, uint128(1e22 + (y >> 16) % 5e24));
        }
    }

    function _swapAll(Run memory R, int24 tick) internal {
        uint160 target = TickMath.getSqrtPriceAtTick(tick);
        (uint160 p,,,) = pm.getSlot0(R.id[0]);
        if (target == p) return;
        bool zfo = target < p;
        (uint24 g0, uint24 g1) = _getFee(hooks[0], R.k[0]);
        for (uint256 i; i < 3; i++) {
            (uint24 f0, uint24 f1) = _getFee(hooks[i], R.k[i]);
            assertEq(abi.encode(f0, f1), abi.encode(g0, g1), "getFee differs");
            assertEq(_swapOne(R, i, zfo, target), zfo ? g0 : g1, "charged fee != the shared quote");
        }
        _cmpState(R, "swap");
        R.swaps++;
        if ((zfo ? g0 : g1) != 0) R.charged++;
    }

    function _swapOne(Run memory R, uint256 i, bool zfo, uint160 target) internal returns (uint24 fee) {
        vm.recordLogs();
        (bool ok,) = sw.swap(R.k[i], zfo, -1e30, target);
        assertTrue(ok, "swap");
        bool found;
        (found, fee) = _swapEventFee(vm.getRecordedLogs(), R.id[i]);
        assertTrue(found, "no Swap event");
        (uint160 q,,,) = pm.getSlot0(R.id[i]);
        assertEq(q, target, "the price path differs");
    }

    function _cmpState(Run memory R, string memory tag) internal view {
        bytes32 s0 = keccak256(_stateBytes(hooks[0], R.id[0]));
        for (uint256 i = 1; i < 3; i++) {
            assertEq(keccak256(_stateBytes(hooks[i], R.id[i])), s0, string.concat("fee state differs after ", tag));
        }
    }
}
