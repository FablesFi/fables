// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {LiquidityAmounts} from "v4-core/test/utils/LiquidityAmounts.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {RCBytecodeHarness, IUniversalRouter, ExactInputSingleParams} from "../utils/RCBytecodeHarness.sol";
import {MockERC20} from "../utils/mocks/MockERC20.sol";
import {MockBallotGate} from "../utils/mocks/MockBallotGate.sol";
import {MockDistributor} from "../utils/mocks/MockDistributor.sol";
import {MockWETH9} from "../utils/mocks/MockWETH9.sol";
import {Roles} from "../utils/Roles.sol";

/// @notice Lifecycle fixture: Robinhood Chain v4 bytecode, AccessManager with role bindings and an ADMIN behind a 1-day
///         delay.
abstract contract FullCycleBase is RCBytecodeHarness {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint32 internal constant CONFIG_DELAY = 1 days;
    uint64 internal constant SEEDER = Roles.SEEDER;
    bytes32 internal constant SWAP_TOPIC =
        keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");

    AccessManager internal am;
    MockWETH9 internal weth;
    MockBallotGate internal gate;
    MockDistributor internal distributor;
    MockERC20 internal fablesToken;

    address internal multisig = makeAddr("fc.multisig");
    address internal poker = makeAddr("fc.poker");
    address internal guardian = makeAddr("fc.guardian");
    address internal discountAdmin = makeAddr("fc.discountAdmin");
    address internal revenueOps = makeAddr("fc.revenueOps");
    address internal treasury = makeAddr("fc.treasury");
    address internal stranger = makeAddr("fc.stranger");

    mapping(address currency => uint256 fee) internal feesCharged;
    mapping(address currency => uint256 n) internal swapsIn;

    function _deployAuthority() internal {
        am = new AccessManager(address(this));
        am.grantRole(Roles.POKER_ADMIN, address(this), 0);
        am.setRoleAdmin(Roles.FEE_POKER, Roles.POKER_ADMIN);
        am.setRoleGuardian(Roles.POKER_ADMIN, Roles.ADMIN);
        am.grantRole(Roles.PAUSER_ADMIN, address(this), 0);
        am.setRoleAdmin(Roles.PAUSER, Roles.PAUSER_ADMIN);
        am.setRoleGuardian(Roles.PAUSER_ADMIN, Roles.ADMIN);
        am.setRoleGuardian(Roles.PAUSER, Roles.ADMIN);
        am.grantRole(Roles.FEE_POKER, poker, 0);
        am.grantRole(Roles.PAUSER, guardian, 0);
        am.grantRole(Roles.PAUSER, multisig, 0);
        am.grantRole(Roles.REVENUE_OPS, revenueOps, CONFIG_DELAY);
        am.labelRole(SEEDER, "SEEDER");
        am.setRoleAdmin(SEEDER, Roles.ADMIN);
        am.grantRole(SEEDER, multisig, 0);
        weth = new MockWETH9();
        gate = new MockBallotGate();
        fablesToken = new MockERC20("FABLES", "FABLES", 18);
        distributor = new MockDistributor(address(fablesToken));
    }

    function _bindFamily(address hook, string memory family) internal {
        am.setTargetAdminDelay(hook, CONFIG_DELAY);
        bool stable = keccak256(bytes(family)) == keccak256("FablesStableHookLite");
        string[] memory s = new string[](1);
        s[0] = "setClaimFeeBps((address,address,uint24,int24,address),uint16)";
        _bind(hook, s, Roles.REVENUE_OPS);
        s = new string[](stable ? 3 : 5);
        s[0] = "pause(uint256)";
        s[1] = "pausePool((address,address,uint24,int24,address),uint256)";
        s[2] = "revokeDiscount(bytes32[],address[])";
        if (!stable) {
            s[3] = "clearPoke(bytes32)";
            s[4] = "killCF(bytes32)";
        }
        _bind(hook, s, Roles.PAUSER);
        s = new string[](2);
        s[0] = "setDiscount(bytes32[],address,uint16,uint24,uint8,uint40)";
        s[1] = "setDiscountFilter(bytes32,uint8,address[])";
        _bind(hook, s, Roles.DISCOUNT_ADMIN);
        if (stable) return;
        s = new string[](2);
        s[0] = "pokeFee(bytes32,uint24,uint24,uint40)";
        s[1] = "setCFActive(bytes32,bool,int24,int24,uint256)";
        _bind(hook, s, Roles.FEE_POKER);
        s = new string[](1);
        s[0] = "initializePool((address,address,uint24,int24,address),uint160)";
        _bind(hook, s, SEEDER);
    }

    function _bind(address hook, string[] memory sigs, uint64 role) internal {
        bytes4[] memory sels = new bytes4[](sigs.length);
        for (uint256 i; i < sigs.length; i++) {
            sels[i] = bytes4(keccak256(bytes(sigs[i])));
        }
        am.setTargetFunctionRole(hook, sels, role);
    }

    function _handOver() internal {
        am.labelRole(Roles.DISCOUNT_ADMIN, "DISCOUNT_ADMIN");
        am.setRoleGuardian(Roles.DISCOUNT_ADMIN, Roles.PAUSER);
        am.setRoleAdmin(Roles.DISCOUNT_ADMIN, Roles.ADMIN);
        am.grantRole(Roles.DISCOUNT_ADMIN, discountAdmin, Roles.DISCOUNT_ADMIN_DELAY);
        am.grantRole(Roles.ADMIN, multisig, CONFIG_DELAY);
        am.grantRole(Roles.POKER_ADMIN, multisig, 0);
        am.grantRole(Roles.PAUSER_ADMIN, multisig, 0);
        am.renounceRole(Roles.POKER_ADMIN, address(this));
        am.renounceRole(Roles.PAUSER_ADMIN, address(this));
        am.renounceRole(Roles.ADMIN, address(this));
        (bool held, uint32 d) = am.hasRole(Roles.ADMIN, multisig);
        assertTrue(held && d == CONFIG_DELAY, "multisig is ADMIN with the config delay");
        (held,) = am.hasRole(Roles.ADMIN, address(this));
        assertFalse(held, "deployer renounced ADMIN");
    }

    function _delayed(address caller, address target, bytes memory data) internal {
        (, uint32 d) = am.canCall(caller, target, bytes4(data));
        vm.prank(caller);
        am.schedule(target, data, 0);
        vm.warp(block.timestamp + d);
        vm.prank(caller);
        am.execute(target, data);
    }

    function _delayedExpectRevert(address caller, address target, bytes memory data, bytes memory reason) internal {
        (, uint32 d) = am.canCall(caller, target, bytes4(data));
        vm.prank(caller);
        am.schedule(target, data, 0);
        vm.warp(block.timestamp + d);
        vm.prank(caller);
        vm.expectRevert(reason);
        am.execute(target, data);
        vm.prank(caller);
        am.cancel(caller, target, data);
    }

    function _delayedDirect(address caller, address target, bytes memory data) internal {
        (, uint32 d) = am.canCall(caller, target, bytes4(data));
        vm.prank(caller);
        am.schedule(target, data, 0);
        vm.warp(block.timestamp + d);
        vm.prank(caller);
        (bool ok, bytes memory ret) = target.call(data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 0x20), mload(ret))
            }
        }
    }

    function _admin(address target, bytes memory data) internal {
        _delayed(multisig, target, data);
    }

    function _adminBatch(address target, bytes[] memory datas) internal {
        vm.startPrank(multisig);
        for (uint256 i; i < datas.length; i++) {
            am.schedule(target, datas[i], 0);
        }
        vm.stopPrank();
        vm.warp(block.timestamp + CONFIG_DELAY);
        vm.startPrank(multisig);
        for (uint256 i; i < datas.length; i++) {
            am.execute(target, datas[i]);
        }
        vm.stopPrank();
    }

    function _unauthorized(address caller) internal pure returns (bytes memory) {
        return abi.encodeWithSignature("AccessManagedUnauthorized(address)", caller);
    }

    function _swap(address from, PoolKey memory key, bool zeroForOne, uint128 amountIn) internal returns (uint24 fee) {
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = urSingleInput(key, zeroForOne, amountIn, 0);
        Currency cin = zeroForOne ? key.currency0 : key.currency1;
        uint256 value = cin.isAddressZero() ? amountIn : 0;
        vm.recordLogs();
        vm.prank(from);
        IUniversalRouter(UR_ADDR).execute{value: value}(hex"10", inputs, block.timestamp + 1000);
        fee = _bookSwap(key, zeroForOne);
    }

    function _swapVia(PoolSwapTest exec, address from, PoolKey memory key, bool zeroForOne, uint128 amountIn)
        internal
        returns (uint24 fee)
    {
        Currency cin = zeroForOne ? key.currency0 : key.currency1;
        uint256 value = cin.isAddressZero() ? amountIn : 0;
        vm.recordLogs();
        vm.prank(from);
        exec.swap{value: value}(
            key,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(uint256(amountIn)),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        fee = _bookSwap(key, zeroForOne);
    }

    function _bookSwap(PoolKey memory key, bool zeroForOne) internal returns (uint24 fee) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 id = PoolId.unwrap(key.toId());
        bool seen;
        int128 a0;
        int128 a1;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == PM_ADDR && logs[i].topics[0] == SWAP_TOPIC && logs[i].topics[1] == id) {
                (a0, a1,,,, fee) = abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
                seen = true;
            }
        }
        assertTrue(seen, "no Swap event");
        int128 paid = zeroForOne ? a0 : a1;
        assertLt(paid, 0, "swapper paid");
        address cin = Currency.unwrap(zeroForOne ? key.currency0 : key.currency1);
        feesCharged[cin] += uint256(uint128(-paid)) * fee / 1e6;
        swapsIn[cin] += 1;
        _assertSettled();
    }

    function _assertSettled() internal view {
        assertEq(TransientStateLibrary.getNonzeroDeltaCount(pm), 0, "PoolManager left a non-zero delta");
        assertFalse(TransientStateLibrary.isUnlocked(pm), "PoolManager left unlocked");
    }

    function _wrapped(address hook, bytes4 callback, bytes memory reason) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            hook,
            callback,
            reason,
            abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        );
    }

    function _bal(Currency c, address who) internal view returns (uint256) {
        return c.isAddressZero() ? who.balance : IERC20(Currency.unwrap(c)).balanceOf(who);
    }

    function _sinkBal(Currency c, address who) internal view returns (uint256) {
        return c.isAddressZero() ? weth.balanceOf(who) : IERC20(Currency.unwrap(c)).balanceOf(who);
    }

    function _align(int24 tick, int24 spacing) internal pure returns (int24) {
        int24 r = tick / spacing * spacing;
        if (tick < 0 && r != tick) r -= spacing;
        return r;
    }

    function _liqFor(PoolId id, int24 lo, int24 hi, uint256 amount0, uint256 amount1)
        internal
        view
        returns (uint128 l)
    {
        (uint160 sqrtP,,,) = pm.getSlot0(id);
        l = LiquidityAmounts.getLiquidityForAmounts(
            sqrtP, TickMath.getSqrtPriceAtTick(lo), TickMath.getSqrtPriceAtTick(hi), amount0, amount1
        );
    }

    function _amountsFor(PoolId id, int24 lo, int24 hi, uint128 l) internal view returns (uint256 a0, uint256 a1) {
        (uint160 sqrtP,,,) = pm.getSlot0(id);
        (a0, a1) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtP, TickMath.getSqrtPriceAtTick(lo), TickMath.getSqrtPriceAtTick(hi), l
        );
    }

    function _tick(PoolId id) internal view returns (int24 t) {
        (, t,,) = pm.getSlot0(id);
    }

    function _approveAll(address who, Currency c, address spender) internal {
        if (c.isAddressZero()) return;
        vm.prank(who);
        IERC20(Currency.unwrap(c)).approve(spender, type(uint256).max);
    }

    function _fund(address who, Currency c, uint256 amount) internal {
        if (c.isAddressZero()) vm.deal(who, who.balance + amount);
        else MockERC20(Currency.unwrap(c)).mint(who, amount);
    }
}
