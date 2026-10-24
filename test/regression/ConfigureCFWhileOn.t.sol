// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {IAccessManager} from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FablesHook} from "../../src/FablesHook.sol";
import {FablesFeeEngine} from "../../src/base/FablesFeeEngine.sol";
import {FeeRef} from "../../src/libraries/FeeRef.sol";

/// @notice Relays a call (stands in for a relayed multisig execution).
contract Relay {
    function relay(address to, bytes calldata data) external returns (bytes memory r) {
        bool s;
        (s, r) = to.call(data);
        if (!s) {
            assembly ("memory-safe") {
                revert(add(r, 32), mload(r))
            }
        }
    }
}

/// @notice Moves the price inside its own unlock, relays a call there, swaps back.
contract MovingRelayer is IUnlockCallback {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    IPoolManager internal immutable pm;
    int24 public movedTick;

    constructor(IPoolManager pm_) {
        pm = pm_;
    }

    function run(PoolKey calldata key, uint256 amountIn, address safe, bytes calldata relayData) external {
        pm.unlock(abi.encode(key, amountIn, safe, relayData));
    }

    function unlockCallback(bytes calldata raw) external returns (bytes memory) {
        (PoolKey memory key, uint256 amountIn, address safe, bytes memory relayData) =
            abi.decode(raw, (PoolKey, uint256, address, bytes));
        BalanceDelta d = pm.swap(key, IPoolManager.SwapParams(true, -int256(amountIn), TickMath.MIN_SQRT_PRICE + 1), "");
        (, movedTick,,) = pm.getSlot0(key.toId());
        (bool ok, bytes memory r) = safe.call(relayData);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(r, 32), mload(r))
            }
        }
        pm.swap(key, IPoolManager.SwapParams(false, -int256(d.amount1()), TickMath.MAX_SQRT_PRICE - 1), "");
        _settle(key.currency0);
        _settle(key.currency1);
        return "";
    }

    function _settle(Currency c) internal {
        int256 delta = TransientStateLibrary.currencyDelta(pm, address(this), c);
        if (delta < 0) {
            pm.sync(c);
            IERC20(Currency.unwrap(c)).transfer(address(pm), uint256(-delta));
            pm.settle();
        } else if (delta > 0) {
            pm.take(c, address(this), uint256(delta));
        }
    }
}

/// @notice `configureCF` reverts while the CF is on, so a relayed configure cannot anchor at a moved price.
contract ConfigureCFWhileOnTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;

    bytes4 internal constant CF_ACTIVE = bytes4(keccak256("CFActive()"));
    uint64 internal constant FEE_POKER = 1;
    uint64 internal constant PAUSER = 4;
    uint24 internal constant BASE = 3_000;
    uint256 internal constant MOVE = 5e18;

    AccessManager internal authority;
    FablesHook internal hook;
    PoolKey internal k;
    PoolId internal id;
    Relay internal safe;
    MovingRelayer internal relayer;
    address internal poker = makeAddr("poker");
    address internal pauser = makeAddr("pauser");
    bytes internal cfData;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();
        authority = new AccessManager(address(this));
        address h = address(uint160(0x12B0 << 144) | uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG));
        deployCodeTo("FablesHook.sol:FablesHook", abi.encode(manager, address(authority)), h);
        hook = FablesHook(payable(h));
        bytes4[] memory s = new bytes4[](1);
        s[0] = FablesFeeEngine.setCFActive.selector;
        authority.setTargetFunctionRole(h, s, FEE_POKER);
        s[0] = FablesFeeEngine.killCF.selector;
        authority.setTargetFunctionRole(h, s, PAUSER);
        authority.grantRole(FEE_POKER, poker, 0);
        authority.grantRole(PAUSER, pauser, 0);
        safe = new Relay();
        authority.grantRole(0, address(safe), 1 days);

        k = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(h));
        id = k.toId();
        hook.setCategory(1, 0, 100_000, 100_000, "ANY");
        hook.configurePool(k, 1, BASE, BASE, 0, 10_000);
        hook.initializePool(k, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(k, IPoolManager.ModifyLiquidityParams(-6_000, 6_000, 1e21, 0), "");

        hook.configureCF(id, 0, 256, 2_500, 0, 300, 60);
        vm.prank(poker);
        hook.setCFActive(id, true);

        relayer = new MovingRelayer(manager);
        currency0.transfer(address(relayer), 1e24);
        currency1.transfer(address(relayer), 1e24);

        cfData = abi.encodeCall(FablesFeeEngine.configureCF, (id, 0, 256, 2_500, 0, 300, 60));
        safe.relay(address(authority), abi.encodeCall(IAccessManager.schedule, (address(hook), cfData, 0)));
        vm.warp(block.timestamp + 1 days);
    }

    function _relayData() internal view returns (bytes memory) {
        return abi.encodeCall(
            Relay.relay, (address(authority), abi.encodeCall(IAccessManager.execute, (address(hook), cfData)))
        );
    }

    function _assertNoSurcharge(string memory m) internal view {
        assertEq(hook.currentFee(id, true), BASE, m);
        assertEq(hook.currentFee(id, false), BASE, m);
    }

    function test_relayedConfigureAtAMovedPrice_reverts() public {
        uint256 cfBefore = hook.cfWord(id);
        _assertNoSurcharge("anchored at the tick");
        vm.expectRevert(CF_ACTIVE);
        relayer.run(k, MOVE, address(safe), _relayData());
        assertEq(hook.cfWord(id), cfBefore, "nothing written");
        assertGt(authority.getSchedule(authority.hashOperation(address(safe), address(hook), cfData)), 0, "still due");
        _assertNoSurcharge("no anchor chosen by the relayer");
    }

    function test_configureWhileOn_reverts_landsWhenOffOrKilled() public {
        vm.expectRevert(CF_ACTIVE);
        hook.configureCF(id, 1, 128, 1_000, 0, 60, 10);
        vm.prank(poker);
        hook.setCFActive(id, false);
        hook.configureCF(id, 1, 128, 1_000, 0, 60, 10);
        vm.prank(poker);
        hook.setCFActive(id, true);
        vm.prank(pauser);
        hook.killCF(id);
        hook.configureCF(id, 0, 256, 2_500, 0, 300, 60);
        (FeeRef.CFWord memory c, bool on) = hook.cfOf(id);
        assertFalse(on, "configureCF never switches on");
        assertEq(c.kQ8, 256, "revived");
    }

    function test_offConfigureOn() public {
        vm.prank(poker);
        hook.setCFActive(id, false);
        relayer.run(k, MOVE, address(safe), _relayData());
        assertLt(relayer.movedTick(), -50, "the price was moved");
        assertEq(FeeRef.unpackCF(hook.cfWord(id)).anchor, int32(relayer.movedTick()) * 256, "sampled, but off");
        _assertNoSurcharge("off");
        vm.prank(poker);
        hook.setCFActive(id, true);
        _assertNoSurcharge("re-anchored at the current tick");
    }
}
