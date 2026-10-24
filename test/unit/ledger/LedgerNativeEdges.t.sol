// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "v4-core/src/libraries/SqrtPriceMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {IERC20Minimal} from "v4-core/src/interfaces/external/IERC20Minimal.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";

import {FablesLedgerV2} from "../../../src/base/FablesLedgerV2.sol";
import {FablesFeeEngine} from "../../../src/base/FablesFeeEngine.sol";
import {FablesHookETH} from "../../../src/FablesHookETH.sol";
import {MockWETH9} from "../../utils/mocks/MockWETH9.sol";

/// @notice FablesHookETH: the native refund's transient balance slot and `rangeGrowth` on a resting range.
contract LedgerNativeEdgesTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;

    uint8 internal constant CAT = 1;
    FablesLedgerV2 internal hook;
    address internal hookAddr;
    PoolKey internal nkey;
    address internal alice = makeAddr("edge.alice");

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();
        AccessManager am = new AccessManager(address(this));
        hookAddr = address(uint160(0x1414 << 144) | uint160(0x2080));
        deployCodeTo(
            "FablesHookETH.sol:FablesHookETH", abi.encode(manager, address(am), address(new MockWETH9())), hookAddr
        );
        hook = FablesLedgerV2(payable(hookAddr));
        assertTrue(address(FablesHookETH(payable(hookAddr)).weth()) != address(0), "native build");
        FablesFeeEngine(hookAddr).setCategory(CAT, 0, 100_000, 100_000, "ANY");
        nkey = PoolKey(CurrencyLibrary.ADDRESS_ZERO, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(hookAddr));
        FablesFeeEngine(hookAddr).configurePool(nkey, CAT, 3000, 3000, 0, 50_000);
        FablesFeeEngine(hookAddr).initializePool(nkey, SQRT_PRICE_1_1);
        IERC20Minimal(Currency.unwrap(currency1)).transfer(alice, 1e24);
        vm.prank(alice);
        IERC20Minimal(Currency.unwrap(currency1)).approve(hookAddr, type(uint256).max);
        vm.deal(alice, 100 ether);
    }

    function _owed0(uint128 liq) internal pure returns (uint256) {
        return SqrtPriceMath.getAmount0Delta(SQRT_PRICE_1_1, TickMath.getSqrtPriceAtTick(600), liq, true);
    }

    function test_nativeRefund_paysOnlyThisCallsUnspentValue_forcedEthStrands() public {
        vm.deal(hookAddr, 3 ether);
        uint256 owed = _owed0(1e18);
        uint256 before = alice.balance;
        vm.prank(alice);
        hook.deposit{value: 5 ether}(nkey, -600, 600, 1e18, 5 ether, type(uint128).max, block.timestamp);
        assertEq(before - alice.balance, owed, "alice paid exactly the principal");
        assertEq(hookAddr.balance, 3 ether, "the forced ETH stays on the hook");
    }

    function test_nativeRefund_secondDepositMeasuresItsOwnDelta() public {
        vm.deal(hookAddr, 1 ether);
        uint256 owed = _owed0(1e17);
        vm.startPrank(alice);
        uint256 before = alice.balance;
        hook.deposit{value: 2 ether}(nkey, -600, 600, 1e17, 2 ether, type(uint128).max, block.timestamp);
        hook.deposit{value: 4 ether}(nkey, -600, 600, 1e17, 4 ether, type(uint128).max, block.timestamp);
        vm.stopPrank();
        assertEq(before - alice.balance, 2 * owed, "each deposit refunded its own remainder");
        assertEq(hookAddr.balance, 1 ether, "forced ETH untouched");
    }

    function test_rangeGrowth_restingRangeIsV4FeeGrowthInside() public {
        PoolKey memory k = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(hookAddr));
        FablesFeeEngine(hookAddr).configurePool(k, CAT, 3000, 3000, 0, 50_000);
        FablesFeeEngine(hookAddr).initializePool(k, SQRT_PRICE_1_1);
        uint256 rid = hook.rangeId(k.toId(), -600, 600);
        (uint256 g0, uint256 g1) = hook.rangeGrowth(rid);
        assertEq(g0 + g1, 0, "unset range");
        IERC20Minimal(Currency.unwrap(currency0)).approve(hookAddr, type(uint256).max);
        IERC20Minimal(Currency.unwrap(currency1)).approve(hookAddr, type(uint256).max);
        hook.deposit(k, -600, 600, 1e18, type(uint128).max, type(uint128).max, block.timestamp);
        swap(k, true, -1e15, ZERO_BYTES);
        (g0, g1) = hook.rangeGrowth(rid);
        (uint256 v0, uint256 v1) = StateLibrary.getFeeGrowthInside(manager, k.toId(), -600, 600);
        assertEq(g0, v0, "growth0 == v4 feeGrowthInside0");
        assertEq(g1, v1, "growth1 == v4 feeGrowthInside1");
        assertGt(g0, 0, "a zeroForOne swap pays fees in currency0");
        assertEq(g1, 0);
    }
}
