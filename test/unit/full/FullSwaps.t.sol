// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {RCBytecodeHarness} from "../../utils/RCBytecodeHarness.sol";
import {FullHarness} from "../../utils/FullHarness.sol";

/// @notice Several swaps in one unlock, quoting `feeFor` before each leg.
contract MultiSwap is IUnlockCallback {
    using PoolIdLibrary for PoolKey;

    IPoolManager internal immutable pm;
    FullHarness internal immutable hook;

    struct Leg {
        PoolKey key;
        bool zeroForOne;
        int256 amount;
    }

    constructor(IPoolManager pm_, FullHarness hook_) {
        pm = pm_;
        hook = hook_;
    }

    function run(Leg[] memory legs) external returns (uint24[] memory quoted) {
        return abi.decode(pm.unlock(abi.encode(legs)), (uint24[]));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(pm), "MultiSwap: not pm");
        Leg[] memory legs = abi.decode(data, (Leg[]));
        uint24[] memory quoted = new uint24[](legs.length);
        for (uint256 i = 0; i < legs.length; ++i) {
            Leg memory l = legs[i];
            quoted[i] = hook.feeFor(l.key.toId(), l.zeroForOne, address(this));
            BalanceDelta d = pm.swap(
                l.key,
                IPoolManager.SwapParams({
                    zeroForOne: l.zeroForOne,
                    amountSpecified: l.amount,
                    sqrtPriceLimitX96: l.zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
                }),
                ""
            );
            _settle(l.key.currency0, d.amount0());
            _settle(l.key.currency1, d.amount1());
        }
        return abi.encode(quoted);
    }

    function _settle(Currency c, int128 amt) internal {
        if (amt < 0) {
            pm.sync(c);
            IERC20(Currency.unwrap(c)).transfer(address(pm), uint128(-amt));
            pm.settle();
        } else if (amt > 0) {
            pm.take(c, address(this), uint128(amt));
        }
    }
}

/// @notice On the Robinhood Chain v4 bytecode, the fee in the PoolManager Swap event equals `feeFor` / `currentFee` for
///         bases, pokes, discounts, the CF, multi-swap transactions and 2-hop routes.
contract FullSwapsTest is RCBytecodeHarness {
    using PoolIdLibrary for PoolKey;

    bytes32 constant SWAP_TOPIC = keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");
    uint8 constant CAT = 1;
    uint24 constant BASE = 3_000;
    uint128 constant SMALL = 1e18;
    uint128 constant BIG = 1e22;

    FullHarness hook;
    address hookAddr;
    AccessManager authority;
    MultiSwap ms;
    PoolKey k1;
    PoolKey k2;
    PoolId id1;
    PoolId id2;

    function setUp() public {
        setUpRC();
        authority = new AccessManager(address(this));
        hookAddr = flagged("full.swaps", FLAGS_FEE_FULL);
        deployCodeTo("FullHarness.sol:FullHarness", abi.encode(pm, address(authority)), hookAddr);
        hook = FullHarness(hookAddr);
        vm.label(hookAddr, "FullHarness");
        hook.setCategory(CAT, 0, 100_000, 100_000, "ANY");
        k1 = dynamicKey(c0, c1, 60, hookAddr);
        k2 = dynamicKey(c1, c2, 60, hookAddr);
        id1 = k1.toId();
        id2 = k2.toId();
        hook.configurePool(k1, CAT, BASE, BASE, 0, 50_000);
        hook.configurePool(k2, CAT, BASE, BASE, 0, 50_000);
        _seedAndWarmHooked(k1, TickMath.getSqrtPriceAtTick(MID_WORD_TICK), 1e24, SMALL);
        _seedAndWarmHooked(k2, TickMath.getSqrtPriceAtTick(MID_WORD_TICK), 1e24, SMALL);
        ms = new MultiSwap(pm, hook);
        tokA.mint(address(ms), 1e30);
        tokB.mint(address(ms), 1e30);
        tokC.mint(address(ms), 1e30);
    }

    function _seedAndWarmHooked(PoolKey memory key, uint160 sqrtPriceX96, int256 liquidity, uint128 warmAmount)
        internal
    {
        hook.initializePool(key, sqrtPriceX96);
        addFullRange(key, liquidity);
        warm(key, warmAmount);
    }

    function _swapEvents() internal view returns (PoolId[] memory ids, uint24[] memory fees) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 n;
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter == PM_ADDR && logs[i].topics[0] == SWAP_TOPIC) ++n;
        }
        ids = new PoolId[](n);
        fees = new uint24[](n);
        uint256 j;
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter != PM_ADDR || logs[i].topics[0] != SWAP_TOPIC) continue;
            (,,,,, uint24 fee) = abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
            ids[j] = PoolId.wrap(logs[i].topics[1]);
            fees[j] = fee;
            ++j;
        }
    }

    function _oneSwapFee() internal view returns (uint24) {
        (PoolId[] memory ids, uint24[] memory fees) = _swapEvents();
        assertEq(ids.length, 1, "one Swap event");
        return fees[0];
    }

    function _urSwapChecked(PoolKey memory key, bool zeroForOne, uint128 amountIn, bool unlisted)
        internal
        returns (uint24 fee)
    {
        PoolId id = key.toId();
        uint24 quoted = hook.feeFor(id, zeroForOne, UR_ADDR);
        uint24 current = hook.currentFee(id, zeroForOne);
        vm.recordLogs();
        swapUR(key, zeroForOne, amountIn);
        fee = _oneSwapFee();
        assertEq(fee, quoted, "Swap event fee != feeFor(UR)");
        if (unlisted) assertEq(fee, current, "Swap event fee != currentFee");
    }

    function _pstSwapChecked(PoolKey memory key, bool zeroForOne, bool unlisted) internal returns (uint24 fee) {
        PoolId id = key.toId();
        uint24 quoted = hook.feeFor(id, zeroForOne, address(swapRouter));
        uint24 current = hook.currentFee(id, zeroForOne);
        vm.recordLogs();
        swapPST(key, zeroForOne, -int256(uint256(SMALL)));
        fee = _oneSwapFee();
        assertEq(fee, quoted, "Swap event fee != feeFor(PoolSwapTest)");
        if (unlisted) assertEq(fee, current, "Swap event fee != currentFee");
    }

    function _ids1() internal view returns (PoolId[] memory ids) {
        ids = new PoolId[](1);
        ids[0] = id1;
    }

    function _tLast(PoolId id) internal view returns (uint256) {
        return hook.cfWord(id) & 0xffffffffff;
    }

    function test_basesBothDirectionsBothRouters() public {
        assertEq(_urSwapChecked(k1, true, SMALL, true), BASE);
        assertEq(_urSwapChecked(k1, false, SMALL, true), BASE);
        assertEq(_pstSwapChecked(k1, true, true), BASE);
        assertEq(_pstSwapChecked(k1, false, true), BASE);
    }

    function test_asymmetricBasesAndPokes() public {
        hook.configurePool(k1, CAT, 2_500, 4_000, 0, 50_000);
        assertEq(_urSwapChecked(k1, true, SMALL, true), 2_500);
        assertEq(_urSwapChecked(k1, false, SMALL, true), 4_000);
        hook.pokeFee(id1, 3_500, 0, 600);
        assertEq(_urSwapChecked(k1, true, SMALL, true), 3_500, "poked side");
        assertEq(_urSwapChecked(k1, false, SMALL, true), 4_000, "sentinel side keeps its base");
        hook.pokeFee(id1, 100, 1_000, 600);
        assertEq(_urSwapChecked(k1, true, SMALL, true), 1_250, "50% rule on zeroForOne");
        assertEq(_urSwapChecked(k1, false, SMALL, true), 2_000, "50% rule on oneForZero");
        vm.warp(block.timestamp + 600);
        assertEq(_urSwapChecked(k1, true, SMALL, true), 2_500, "expired");
        assertEq(_urSwapChecked(k1, false, SMALL, true), 4_000);
    }

    function test_discountAppliesToTheListedSenderOnly() public {
        hook.setDiscount(_ids1(), UR_ADDR, 2_000, 0, 3, uint40(block.timestamp + 1 days));
        assertEq(hook.currentFee(id1, true), BASE, "quotes stay sender-free");
        assertEq(hook.feeFor(id1, true, UR_ADDR), 2_400);
        assertEq(_urSwapChecked(k1, true, SMALL, false), 2_400, "UR pays the discounted fee");
        assertEq(_pstSwapChecked(k1, true, true), BASE, "PoolSwapTest (unlisted) pays the base");
        hook.setDiscount(_ids1(), address(swapRouter), 5_000, 0, 2, uint40(block.timestamp + 1 days));
        assertEq(_pstSwapChecked(k1, true, true), BASE, "direction not covered");
        assertEq(_pstSwapChecked(k1, false, false), 1_500, "covered direction");
        address[] memory accounts = new address[](2);
        accounts[0] = UR_ADDR;
        accounts[1] = address(swapRouter);
        hook.revokeDiscount(_ids1(), accounts);
        assertEq(_urSwapChecked(k1, true, SMALL, true), BASE);
        assertEq(_pstSwapChecked(k1, false, true), BASE);
    }

    function test_cfContinuationChargesTheContinuingSide() public {
        hook.configureCF(id1, 0, 256, 2_500, 0, 60, 1);
        hook.setCFActive(id1, true, TickMath.MIN_TICK, TickMath.MAX_TICK, type(uint256).max);
        (, int24 tick0,,) = slot0(id1);
        assertEq(_urSwapChecked(k1, true, BIG, true), BASE, "first swap at the anchor pays the base");
        (, int24 tick1,,) = slot0(id1);
        assertLt(tick1, tick0 - 50, "the price moved");
        vm.warp(block.timestamp + 1);
        uint24 cont = _urSwapChecked(k1, true, SMALL, true);
        assertEq(cont, BASE + 2_500, "continuation at the CF cap");
        assertEq(_tLast(id1), block.timestamp, "CF word written on the first swap of the period");
        assertEq(_urSwapChecked(k1, false, SMALL, true), BASE, "returning side pays the base");
        vm.warp(block.timestamp + 255);
        assertEq(_urSwapChecked(k1, true, SMALL, true), BASE, "anchor snapped to the tick");
    }

    function test_cfReverseChargesTheReturningSide() public {
        hook.configureCF(id1, 1, 256, 2_500, 0, 60, 1);
        hook.setCFActive(id1, true, TickMath.MIN_TICK, TickMath.MAX_TICK, type(uint256).max);
        assertEq(_urSwapChecked(k1, true, BIG, true), BASE, "first swap at the anchor");
        vm.warp(block.timestamp + 1);
        assertEq(_urSwapChecked(k1, false, SMALL, true), BASE + 2_500, "moving BACK toward the anchor is taxed");
        assertEq(_urSwapChecked(k1, true, SMALL, true), BASE, "continuing is free in reverse mode");
        hook.setCFActive(id1, false, 0, 0, 0);
        assertEq(_urSwapChecked(k1, false, SMALL, true), BASE);
    }

    function test_cfKillAndDiscountStackAsSpecified() public {
        hook.configureCF(id1, 0, 256, 2_500, 0, 60, 1);
        hook.setCFActive(id1, true, TickMath.MIN_TICK, TickMath.MAX_TICK, type(uint256).max);
        hook.setDiscount(_ids1(), UR_ADDR, 5_000, 0, 3, uint40(block.timestamp + 1 days));
        swapUR(k1, true, BIG);
        vm.warp(block.timestamp + 1);
        assertEq(_urSwapChecked(k1, true, SMALL, false), 1_500 + 2_500, "discounted base + full CF");
        assertEq(_pstSwapChecked(k1, true, true), BASE + 2_500, "unlisted: base + CF");
        hook.killCF(id1);
        assertEq(_urSwapChecked(k1, true, SMALL, false), 1_500, "killed: discount only");
        vm.expectRevert();
        hook.setCFActive(id1, true, TickMath.MIN_TICK, TickMath.MAX_TICK, type(uint256).max);
    }

    function test_overrideEqualsAVanillaPoolOfTheSameFee() public {
        PoolKey memory v = poolKey(c0, c1, BASE, 60, address(0));
        seedAndWarm(v, TickMath.getSqrtPriceAtTick(MID_WORD_TICK), 1e24, SMALL);
        (BalanceDelta dv,) = swapPST(v, true, -int256(uint256(SMALL)));
        (BalanceDelta dh,) = swapPST(k1, true, -int256(uint256(SMALL)));
        assertEq(dh.amount1(), dv.amount1(), "override 3000 == static 3000");
        hook.pokeFee(id1, 6_000, 6_000, 600);
        (BalanceDelta dh2,) = swapPST(k1, true, -int256(uint256(SMALL)));
        assertLt(dh2.amount1(), dv.amount1(), "a higher override pays out less");
    }

    function test_threeSwapsOnePoolOneTxBothDirections() public {
        hook.configureCF(id1, 0, 256, 2_500, 0, 60, 1);
        hook.setCFActive(id1, true, TickMath.MIN_TICK, TickMath.MAX_TICK, type(uint256).max);
        vm.warp(block.timestamp + 1);
        MultiSwap.Leg[] memory legs = new MultiSwap.Leg[](3);
        legs[0] = MultiSwap.Leg(k1, true, -int256(uint256(BIG)));
        legs[1] = MultiSwap.Leg(k1, true, -int256(uint256(SMALL)));
        legs[2] = MultiSwap.Leg(k1, false, -int256(uint256(SMALL)));
        vm.recordLogs();
        uint24[] memory quoted = ms.run(legs);
        (PoolId[] memory ids, uint24[] memory fees) = _swapEvents();
        assertEq(fees.length, 3);
        for (uint256 i = 0; i < 3; ++i) {
            assertEq(PoolId.unwrap(ids[i]), PoolId.unwrap(id1));
            assertEq(fees[i], quoted[i], "leg fee != feeFor quoted inside the tx");
        }
        assertEq(fees[0], BASE, "leg 1 at the anchor");
        assertEq(fees[1], BASE + 2_500, "leg 2 continues the move");
        assertEq(fees[2], BASE, "leg 3 returns");
        assertEq(_tLast(id1), block.timestamp, "CF word written once in the tx");
    }

    function test_twoHopThroughTwoFullPoolsWithCfWriteAndRead() public {
        hook.configureCF(id1, 0, 256, 2_500, 0, 60, 1);
        hook.configureCF(id2, 0, 256, 2_500, 0, 60, 1);
        hook.setCFActive(id1, true, TickMath.MIN_TICK, TickMath.MAX_TICK, type(uint256).max);
        hook.setCFActive(id2, true, TickMath.MIN_TICK, TickMath.MAX_TICK, type(uint256).max);
        vm.warp(block.timestamp + 1);
        uint256 tBefore = _tLast(id1);
        assertEq(_tLast(id2), tBefore);

        uint24 q1 = hook.feeFor(id1, true, UR_ADDR);
        uint24 q2 = hook.feeFor(id2, true, UR_ADDR);
        vm.recordLogs();
        swapURTwoHop(c0, k1, c1, k2, c2, BIG);
        (PoolId[] memory ids, uint24[] memory fees) = _swapEvents();
        assertEq(fees.length, 2);
        assertEq(PoolId.unwrap(ids[0]), PoolId.unwrap(id1));
        assertEq(PoolId.unwrap(ids[1]), PoolId.unwrap(id2));
        assertEq(fees[0], q1);
        assertEq(fees[1], q2);
        assertEq(fees[0], BASE);
        assertEq(fees[1], BASE);
        assertEq(_tLast(id1), block.timestamp, "pool 1 CF word written");
        assertEq(_tLast(id2), block.timestamp, "pool 2 CF word written");
        uint256 cf1 = hook.cfWord(id1);
        uint256 cf2 = hook.cfWord(id2);

        q1 = hook.feeFor(id1, true, UR_ADDR);
        q2 = hook.feeFor(id2, true, UR_ADDR);
        vm.recordLogs();
        swapURTwoHop(c0, k1, c1, k2, c2, SMALL);
        (, fees) = _swapEvents();
        assertEq(fees[0], q1);
        assertEq(fees[1], q2);
        assertEq(fees[0], BASE + 2_500, "hop 1 continuation");
        assertEq(fees[1], BASE + 2_500, "hop 2 continuation");
        assertEq(hook.cfWord(id1), cf1, "no second write within the period");
        assertEq(hook.cfWord(id2), cf2);

        q1 = hook.feeFor(id2, false, UR_ADDR);
        q2 = hook.feeFor(id1, false, UR_ADDR);
        vm.recordLogs();
        swapURTwoHop(c2, k2, c1, k1, c0, SMALL);
        (, fees) = _swapEvents();
        assertEq(fees[0], q1);
        assertEq(fees[1], q2);
        assertEq(fees[0], BASE);
        assertEq(fees[1], BASE);
    }

    function test_urDoubleSwapSamePool() public {
        hook.pokeFee(id1, 4_500, 4_500, 600);
        vm.recordLogs();
        swapURDouble(k1, true, SMALL);
        (, uint24[] memory fees) = _swapEvents();
        assertEq(fees.length, 2);
        assertEq(fees[0], 4_500);
        assertEq(fees[1], 4_500);
    }
}
