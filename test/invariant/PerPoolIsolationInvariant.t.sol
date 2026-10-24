// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IERC20Minimal} from "v4-core/src/interfaces/external/IERC20Minimal.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";

import {FablesLedgerV2} from "../../src/base/FablesLedgerV2.sol";
import {FablesFeeEngine} from "../../src/base/FablesFeeEngine.sol";
import {PoolWordLib} from "../../src/libraries/PoolWordLib.sol";
import {MockBallotGate} from "../utils/mocks/MockBallotGate.sol";
import {LedgerFixture, ICurrentFee} from "../utils/LedgerFixture.sol";

/// @notice Random per-pool admin actions and LP traffic on two pools of one hook, mirrored per pool.
contract IsolationHandler is Test {
    using PoolIdLibrary for PoolKey;

    FablesLedgerV2 public immutable hook;
    FablesFeeEngine public immutable engine;
    IPoolManager internal immutable poolManager;
    PoolSwapTest public immutable swapRouter;
    PoolKey public keyA;
    PoolKey public keyB;

    mapping(bytes32 => uint16) public expectedBps;
    mapping(bytes32 => uint256) public expectedPausedUntil;
    mapping(bytes32 => uint24) public expectedBase0;
    mapping(bytes32 => uint24) public expectedBase1;
    mapping(bytes32 => uint24) public expectedFloor;
    mapping(bytes32 => uint24) public expectedCap;

    uint256 public pausesLanded;
    uint256 public feesLanded;
    uint256 public rateOnlyLanded;
    uint256 public configsLanded;
    uint256 public depositsLanded;
    uint256 public swapsLanded;

    address internal constant TREASURY = address(0xFEE);
    uint160 internal constant MIN_PRICE_LIMIT = 4295128740;
    uint160 internal constant MAX_PRICE_LIMIT = 1461446703485210103287273052203988822378723970341;

    constructor(FablesLedgerV2 hook_, PoolSwapTest swapRouter_, PoolKey memory a, PoolKey memory b) {
        hook = hook_;
        engine = FablesFeeEngine(address(hook_));
        poolManager = IPoolManager(address(hook_.poolManager()));
        swapRouter = swapRouter_;
        keyA = a;
        keyB = b;
        _mirrorConfig(a.toId());
        _mirrorConfig(b.toId());
    }

    function _mirrorConfig(PoolId id) internal {
        PoolWordLib.PoolWord memory w = engine.poolFee(id);
        bytes32 k = PoolId.unwrap(id);
        expectedBase0[k] = w.base0;
        expectedBase1[k] = w.base1;
        expectedFloor[k] = w.floor;
        expectedCap[k] = w.cap;
    }

    function _pick(bool useA) internal view returns (PoolKey memory) {
        return useA ? keyA : keyB;
    }

    function setClaimFee(bool useA, uint16 bps) external {
        PoolKey memory k = _pick(useA);
        bps = uint16(bound(bps, 0, hook.MAX_CLAIM_FEE_BPS()));
        hook.setClaimFee(k, new Currency[](0), bps, TREASURY);
        expectedBps[PoolId.unwrap(k.toId())] = bps;
        feesLanded++;
    }

    function setClaimFeeBpsOnly(bool useA, uint16 bps) external {
        PoolKey memory k = _pick(useA);
        bps = uint16(bound(bps, 0, hook.MAX_CLAIM_FEE_BPS()));
        if (hook.claimFeeRecipient() == address(0)) return;
        hook.setClaimFeeBps(k, bps);
        expectedBps[PoolId.unwrap(k.toId())] = bps;
        rateOnlyLanded++;
    }

    function pausePool(bool useA, uint32 duration) external {
        PoolKey memory k = _pick(useA);
        bytes32 id = PoolId.unwrap(k.toId());
        duration = uint32(bound(duration, 1, uint32(hook.MAX_PAUSE())));
        uint256 until_ = block.timestamp + duration;
        if (until_ <= expectedPausedUntil[id]) return;
        hook.pausePool(k, duration);
        expectedPausedUntil[id] = until_;
        pausesLanded++;
    }

    function liftPool(bool useA) external {
        PoolKey memory k = _pick(useA);
        hook.setPoolPaused(k, 0);
        expectedPausedUntil[PoolId.unwrap(k.toId())] = 0;
        pausesLanded++;
    }

    function reconfigure(bool useA, uint24 base0, uint24 base1, uint24 floor, uint24 cap) external {
        PoolKey memory k = _pick(useA);
        cap = uint24(bound(cap, 1, 100_000));
        floor = uint24(bound(floor, 0, cap));
        base0 = uint24(bound(base0, floor, cap));
        base1 = uint24(bound(base1, floor, cap));
        engine.configurePool(k, 1, base0, base1, floor, cap);
        bytes32 id = PoolId.unwrap(k.toId());
        expectedBase0[id] = base0;
        expectedBase1[id] = base1;
        expectedFloor[id] = floor;
        expectedCap[id] = cap;
        configsLanded++;
    }

    function deposit(bool useA, uint96 liq) external {
        PoolKey memory k = _pick(useA);
        if (hook.pausedFor(k.toId())) return;
        uint128 amount = uint128(bound(liq, 1e14, 1e17));
        hook.deposit(k, -120, 120, amount, type(uint128).max, type(uint128).max, block.timestamp + 1);
        depositsLanded++;
    }

    function swapOn(bool useA, bool zeroForOne, uint96 amount) external {
        PoolKey memory k = _pick(useA);
        (uint160 sqrtPriceX96,,,) = StateLibrary.getSlot0(poolManager, k.toId());
        if (zeroForOne ? sqrtPriceX96 <= MIN_PRICE_LIMIT : sqrtPriceX96 >= MAX_PRICE_LIMIT) return;
        int256 spec = -int256(uint256(bound(amount, 1e12, 1e15)));
        swapRouter.swap(
            k,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: spec,
                sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        swapsLanded++;
    }

    function warp(uint32 dt) external {
        vm.warp(block.timestamp + bound(dt, 1 hours, 3 days));
    }
}

/// @notice Each pool's pause, claim fee and fee config always equal what was set for that pool.
abstract contract PerPoolIsolationInvariantBase is LedgerFixture {
    using PoolIdLibrary for PoolKey;

    IsolationHandler handler;
    FablesLedgerV2 hook;
    FablesFeeEngine engine;
    PoolKey kA;
    PoolKey kB;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();
        AccessManager authority = new AccessManager(address(this));

        address addr = _deployBuild(0x5151, address(authority));
        hook = FablesLedgerV2(addr);
        engine = FablesFeeEngine(addr);
        hook.setBallotGate(address(new MockBallotGate()));

        kA = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(addr));
        kB = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 30, IHooks(addr));
        engine.configurePool(kA, CAT, 500, 600, 0, 10_000);
        engine.configurePool(kB, CAT, 700, 700, 100, 9_000);

        vm.warp(1785859200);
        _initPool(kA, SQRT_PRICE_1_1);
        _initPool(kB, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(kA, LIQUIDITY_PARAMS, ZERO_BYTES);
        modifyLiquidityRouter.modifyLiquidity(kB, LIQUIDITY_PARAMS, ZERO_BYTES);

        handler = new IsolationHandler(hook, swapRouter, kA, kB);
        authority.grantRole(authority.ADMIN_ROLE(), address(handler), 0);
        IERC20Minimal(Currency.unwrap(currency0)).transfer(address(handler), 1e22);
        IERC20Minimal(Currency.unwrap(currency1)).transfer(address(handler), 1e22);
        vm.startPrank(address(handler));
        IERC20Minimal(Currency.unwrap(currency0)).approve(address(hook), type(uint256).max);
        IERC20Minimal(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);
        IERC20Minimal(Currency.unwrap(currency0)).approve(address(swapRouter), type(uint256).max);
        IERC20Minimal(Currency.unwrap(currency1)).approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();

        targetContract(address(handler));
    }

    function invariant_theProtocolFeeIsWhatThisPoolWasGiven() public view {
        assertEq(hook.claimFeeBps(kA.toId()), handler.expectedBps(PoolId.unwrap(kA.toId())), "A rate");
        assertEq(hook.claimFeeBps(kB.toId()), handler.expectedBps(PoolId.unwrap(kB.toId())), "B rate");
    }

    function invariant_thePauseIsWhatThisPoolWasGiven() public view {
        assertEq(hook.pausedUntilOf(kA.toId()), handler.expectedPausedUntil(PoolId.unwrap(kA.toId())), "A pause");
        assertEq(hook.pausedUntilOf(kB.toId()), handler.expectedPausedUntil(PoolId.unwrap(kB.toId())), "B pause");
    }

    function invariant_theFeeConfigIsWhatThisPoolWasGiven() public view {
        _assertConfig(kA.toId(), "A");
        _assertConfig(kB.toId(), "B");
    }

    function _assertConfig(PoolId id, string memory who) internal view {
        bytes32 k = PoolId.unwrap(id);
        PoolWordLib.PoolWord memory w = engine.poolFee(id);
        assertEq(w.base0, handler.expectedBase0(k), string.concat(who, " base0"));
        assertEq(w.base1, handler.expectedBase1(k), string.concat(who, " base1"));
        assertEq(w.floor, handler.expectedFloor(k), string.concat(who, " floor"));
        assertEq(w.cap, handler.expectedCap(k), string.concat(who, " cap"));
        assertEq(hook.maxFee(id), handler.expectedCap(k), string.concat(who, " maxFee"));
    }

    function invariant_theHookWidePauseStaysUntouched() public view {
        assertFalse(hook.paused(), "no per-pool action may set the hook-wide freeze");
    }

    function invariant_sharesRemainLiquidityUnitsPerPool() public view {
        uint256 ridA = hook.rangeId(kA.toId(), -120, 120);
        uint256 ridB = hook.rangeId(kB.toId(), -120, 120);
        assertEq(hook.rangeState(ridA).totalShares, hook.balanceOf(address(handler), ridA), "A shares");
        assertEq(hook.rangeState(ridB).totalShares, hook.balanceOf(address(handler), ridB), "B shares");
    }

    function test_twoPoolsWithDifferentConfigsResolveDifferently() public view {
        uint24 feeA = ICurrentFee(address(hook)).currentFee(kA.toId(), true);
        uint24 feeB = ICurrentFee(address(hook)).currentFee(kB.toId(), true);
        assertEq(feeA, 500, "A resolves its own base");
        assertEq(feeB, 700, "B resolves its own base");
    }

    function test_theHandlersActionsActuallyReachTheHook() public {
        handler.setClaimFee(true, 500);
        handler.pausePool(false, 1 days);
        handler.reconfigure(true, 800, 900, 100, 20_000);
        handler.deposit(true, 1e15);
        handler.swapOn(true, true, 1e13);

        assertEq(handler.feesLanded(), 1, "claim fee landed");
        assertEq(handler.pausesLanded(), 1, "pause landed");
        assertEq(handler.configsLanded(), 1, "reconfigure landed");
        assertEq(handler.depositsLanded(), 1, "deposit landed");
        assertEq(handler.swapsLanded(), 1, "swap landed");

        handler.setClaimFeeBpsOnly(true, 300);
        assertGt(handler.rateOnlyLanded(), 0, "the rate-only claim-fee lever never lands");

        assertEq(hook.claimFeeBps(kA.toId()), 300, "A got the rate-only change");
        assertEq(hook.claimFeeBps(kB.toId()), 0, "B did not");
        assertTrue(hook.pausedFor(kB.toId()), "B got the pause");
        assertFalse(hook.pausedFor(kA.toId()), "A did not");
        assertEq(engine.poolFee(kA.toId()).base0, 800, "A got the new base");
        assertEq(engine.poolFee(kB.toId()).base0, 700, "B kept its own");
        assertEq(hook.maxFee(kA.toId()), 20_000, "A got the new cap");
        assertEq(hook.maxFee(kB.toId()), 9_000, "B kept its own");
    }

    function test_theClaimFeeHistoryIsPerPoolToo() public {
        handler.setClaimFee(true, 900);
        handler.setClaimFee(true, 100);
        handler.setClaimFee(false, 700);

        uint256 lenA = hook.claimFeeHistoryLength(kA.toId());
        uint256 lenB = hook.claimFeeHistoryLength(kB.toId());
        assertGt(lenA, lenB, "A took more rate changes than B: the histories are not the same list");

        assertEq(hook.claimFeeFor(kA.toId(), 1), 100, "A's history min from its first change");
        assertEq(hook.claimFeeFor(kB.toId(), 1), 700, "B's history is untouched by A's changes");
        assertEq(hook.claimFeeAllTimeMin(kA.toId()), 100, "A's all-time min is its lowest recorded rate");
        assertEq(hook.claimFeeAllTimeMin(kB.toId()), 700, "and B's is its own");
        assertEq(hook.claimFeeBps(kA.toId()), 100, "A's advertised rate");
        assertEq(hook.claimFeeBps(kB.toId()), 700, "B's advertised rate");
    }
}

contract PerPoolIsolationInvariantTest is PerPoolIsolationInvariantBase {}
