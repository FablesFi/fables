// SPDX-License-Identifier: MIT
// Adapted from OpenZeppelin Uniswap Hooks v1.3.0 (MIT, Copyright (c) 2016-2026 Zeppelin Group Ltd).
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IERC20Minimal} from "v4-core/src/interfaces/external/IERC20Minimal.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";

import {FablesFeeEngine} from "../../../src/base/FablesFeeEngine.sol";
import {FablesLedgerV2} from "../../../src/base/FablesLedgerV2.sol";
import {FablesStableHookLite} from "../../../src/FablesStableHookLite.sol";
import {StableFeeConfig} from "../../../src/base/FablesStableFee.sol";
import {RangeState} from "../../../src/base/LedgerTypesV2.sol";
import {MockWETH9} from "../../utils/mocks/MockWETH9.sol";
import {OzHookHandler} from "./OzHookHandler.sol";

/// @notice OpenZeppelin-style campaign for one build: a hook carrying two pools that share currency1, a protocol fee
///         on the first pool, and the ledger seeded by the first actor.
abstract contract OzHookInvariants is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    struct Build {
        string name;
        uint160 flags;
        bool eth;
        bool exclusive;
        bool stable;
    }

    uint24 internal constant PROTOCOL_FEE = 500 | (300 << 12);
    uint128 internal constant SEED_LIQUIDITY = 1e20;
    /// @dev Truncation slack: a few wei per sync, so it grows with the call count, not the amounts.
    uint256 internal constant ROUNDING_TOLERANCE = 1e4;

    OzHookHandler internal handler;
    address internal hook;
    Currency[] internal currencies;

    function _build() internal pure virtual returns (Build memory);

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();
        Build memory b = _build();
        AccessManager authority = new AccessManager(address(this));
        hook = address(uint160(0x0A11 << 144) | b.flags);
        bytes memory args = b.eth
            ? abi.encode(manager, address(authority), address(new MockWETH9()))
            : abi.encode(manager, address(authority));
        deployCodeTo(string.concat(b.name, ".sol:", b.name), args, hook);

        Currency first = b.eth ? CurrencyLibrary.ADDRESS_ZERO : currency0;
        PoolKey memory key0 = PoolKey(first, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(hook));
        PoolKey memory key1 = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 10, IHooks(hook));
        _createPool(b.stable, key0);
        _createPool(b.stable, key1);
        vm.prank(feeController);
        manager.setProtocolFee(key0, PROTOCOL_FEE);

        if (b.eth) currencies.push(CurrencyLibrary.ADDRESS_ZERO);
        currencies.push(currency0);
        currencies.push(currency1);

        address[3] memory actors = [makeAddr("alice"), makeAddr("bob"), makeAddr("carol")];
        handler = new OzHookHandler(
            OzHookHandler.Setup({
                manager: manager,
                hook: FablesLedgerV2(payable(hook)),
                stable: b.stable,
                swapRouter: swapRouter,
                lpRouter: modifyLiquidityRouter,
                donateRouter: donateRouter,
                key0: key0,
                key1: key1,
                actors: actors
            })
        );
        authority.grantRole(0, address(handler), 0);
        for (uint256 i; i < actors.length; ++i) {
            _fund(actors[i]);
        }
        _seed(actors[0], key0, 0);
        _seed(actors[0], key1, 1);

        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: _actions()}));
    }

    function _createPool(bool stable, PoolKey memory key) internal {
        if (stable) {
            FablesStableHookLite(hook)
                .configureStablePool(
                    key,
                    SQRT_PRICE_1_1,
                    StableFeeConfig({
                    k: 11_744_051, optimalFeeE6: 50, targetMultiplier: 100, referenceSqrtPriceX96: SQRT_PRICE_1_1
                })
                );
            return;
        }
        FablesFeeEngine(hook).setCategory(1, 0, 100_000, 100_000, "ANY");
        FablesFeeEngine(hook).configurePool(key, 1, 3000, 3000, 500, 50_000);
        FablesFeeEngine(hook).initializePool(key, SQRT_PRICE_1_1);
    }

    function _fund(address who) internal {
        vm.deal(who, 1e30);
        IERC20Minimal t0 = IERC20Minimal(Currency.unwrap(currency0));
        IERC20Minimal t1 = IERC20Minimal(Currency.unwrap(currency1));
        assertTrue(t0.transfer(who, 1e30));
        assertTrue(t1.transfer(who, 1e30));
        address[4] memory spenders = [hook, address(swapRouter), address(modifyLiquidityRouter), address(donateRouter)];
        vm.startPrank(who);
        for (uint256 i; i < spenders.length; ++i) {
            t0.approve(spenders[i], type(uint256).max);
            t1.approve(spenders[i], type(uint256).max);
        }
        vm.stopPrank();
    }

    function _seed(address who, PoolKey memory key, uint256 p) internal {
        uint256 value = key.currency0.isAddressZero() ? handler.NATIVE_VALUE() : 0;
        // forge-lint: disable-next-line(unsafe-typecast)
        uint128 max0 = value == 0 ? type(uint128).max : uint128(value);
        (int24 lower, int24 upper) = (handler.lowerOf(p, 0), handler.upperOf(p, 0));
        vm.prank(who);
        FablesLedgerV2(payable(hook)).deposit{value: value}(
            key, lower, upper, SEED_LIQUIDITY, max0, type(uint128).max, block.timestamp
        );
    }

    function _actions() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](12);
        s[0] = OzHookHandler.swap.selector;
        s[1] = OzHookHandler.swapRoundTrip.selector;
        s[2] = OzHookHandler.deposit.selector;
        s[3] = OzHookHandler.withdraw.selector;
        s[4] = OzHookHandler.ledgerRoundTrip.selector;
        s[5] = OzHookHandler.transferReceipts.selector;
        s[6] = OzHookHandler.claim.selector;
        s[7] = OzHookHandler.directAdd.selector;
        s[8] = OzHookHandler.directRemove.selector;
        s[9] = OzHookHandler.donate.selector;
        s[10] = OzHookHandler.poke.selector;
        s[11] = OzHookHandler.nextBlock.selector;
    }

    /// @notice OZ INV-05: the hook never rejects a swap or donation the pool accepted.
    function invariant_hookNeverRejectsASwap() public view {
        assertEq(
            handler.ghost_hookRejections(),
            0,
            string.concat("the hook rejected a swap: ", vm.toString(handler.ghost_lastRejection()))
        );
    }

    /// @notice OZ BaseOverrideFee: the stored LP fee stays 0 and each swap pays the hook's quoted override, composed
    ///         with the protocol fee.
    function invariant_swapsPayTheQuotedOverrideFee() public view {
        assertEq(handler.ghost_feeMismatches(), 0, "a swap paid a fee other than the hook's quote");
        for (uint256 p; p < 2; ++p) {
            (,,, uint24 lpFee) = manager.getSlot0(handler.key(p).toId());
            assertEq(lpFee, 0, "the stored LP fee moved");
        }
    }

    /// @notice OZ INV-L-01 / INV-L-04: a range's receipts add up to its shares, which equal the ledger's position.
    function invariant_receiptsMatchTheLedgerPosition() public view {
        for (uint256 p; p < 2; ++p) {
            for (uint256 r; r < 3; ++r) {
                RangeState memory st = FablesLedgerV2(payable(hook)).rangeState(handler.rangeIdOf(p, r));
                assertEq(handler.receiptsHeld(p, r), st.totalShares, "receipts differ from the range's shares");
                assertEq(handler.positionLiquidity(p, r), st.totalShares, "the position differs from the shares");
            }
        }
    }

    /// @notice OZ INV-S-01 / INV-08: the hook's claims cover what the ledger owes, the surplus stays within rounding,
    ///         and no token rests in the hook itself.
    function invariant_hookHoldsWhatItOwes() public view {
        for (uint256 i; i < currencies.length; ++i) {
            Currency c = currencies[i];
            uint256 claims = handler.claimsOf(c, hook);
            uint256 owed = handler.owedIn(c);
            assertGe(claims, owed, "claims fall short of what the ledger owes");
            assertLe(claims - owed, ROUNDING_TOLERANCE, "claims exceed what the ledger owes beyond rounding");
            uint256 held = c.isAddressZero() ? hook.balance : IERC20Minimal(Currency.unwrap(c)).balanceOf(hook);
            assertEq(held, 0, "tokens rest in the hook");
        }
    }

    /// @notice Exclusive builds: liquidity enters only through the ledger.
    function invariant_onlyTheLedgerAddsLiquidity() public view {
        if (_build().exclusive) assertEq(handler.ghost_directAddsLanded(), 0, "a router added liquidity");
    }
}

contract OzInvariantsFablesHook is OzHookInvariants {
    function _build() internal pure override returns (Build memory) {
        return Build("FablesHook", 0x2080, false, false, false);
    }
}

contract OzInvariantsFablesHookETH is OzHookInvariants {
    function _build() internal pure override returns (Build memory) {
        return Build("FablesHookETH", 0x2080, true, false, false);
    }
}

contract OzInvariantsFablesHookExclusive is OzHookInvariants {
    function _build() internal pure override returns (Build memory) {
        return Build("FablesHookExclusive", 0x2880, false, true, false);
    }
}

contract OzInvariantsFablesHookETHExclusive is OzHookInvariants {
    function _build() internal pure override returns (Build memory) {
        return Build("FablesHookETHExclusive", 0x2880, true, true, false);
    }
}

contract OzInvariantsFablesStableHookLite is OzHookInvariants {
    function _build() internal pure override returns (Build memory) {
        return Build("FablesStableHookLite", 0x2080, false, false, true);
    }
}

contract OzInvariantsFablesStableHookLiteExclusive is OzHookInvariants {
    function _build() internal pure override returns (Build memory) {
        return Build("FablesStableHookLiteExclusive", 0x2880, false, true, true);
    }
}
