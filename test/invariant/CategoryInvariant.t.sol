// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {console} from "forge-std/console.sol";
import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";

import {FablesFeeEngine} from "../../src/base/FablesFeeEngine.sol";
import {FablesFeeFull} from "../../src/base/FablesFeeFull.sol";
import {FablesLedgerV2} from "../../src/base/FablesLedgerV2.sol";
import {RangeState, UserPosition} from "../../src/base/LedgerTypesV2.sol";
import {PoolWordLib} from "../../src/libraries/PoolWordLib.sol";
import {FeeRef} from "../../src/libraries/FeeRef.sol";
import {MockWETH9} from "../utils/mocks/MockWETH9.sol";
import {CategoryTable} from "../utils/CategoryTable.sol";
import {CategoryHandler} from "./CategoryHandler.sol";
import {EtchDeploy, BuildCode, Depth} from "../utils/Artifacts.sol";

/// @notice One FablesHook carrying five pools, one per fee category: fee bands, twin equality, ledger conservation and
///         share accounting after every step.
abstract contract CategoryInvariantBase is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using PoolWordLib for uint256;
    using CurrencyLibrary for Currency;

    uint256 internal constant Q128 = 1 << 128;
    uint256 internal constant START = 1_800_000_000;
    uint128 internal constant SEED_L = 1e25;

    CategoryHandler internal handler;
    address internal hookAddr;
    AccessManager internal authority;
    PoolKey[5] internal keys;
    address[3] internal actors;

    function _eth() internal pure virtual returns (bool);

    function _creation() internal pure returns (bytes memory) {
        return _eth() ? BuildCode.fablesHookETH() : BuildCode.fablesHook();
    }

    function setUp() public {
        vm.warp(START);
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();
        authority = new AccessManager(address(this));
        MockWETH9 weth = new MockWETH9();
        uint160 flags = uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG);
        hookAddr = address(uint160(0xCA7E << 144) | flags);
        bytes memory args =
            _eth() ? abi.encode(manager, address(authority), address(weth)) : abi.encode(manager, address(authority));
        EtchDeploy.to(_creation(), args, hookAddr);
        vm.label(hookAddr, "FablesHook*");
        for (uint8 c = 1; c <= CategoryTable.COUNT; ++c) {
            CategoryTable.Cat memory t = CategoryTable.get(c);
            FablesFeeEngine(hookAddr).setCategory(c, t.floorMin, t.capMax, t.raiseStep, CategoryTable.label(c));
        }
        vm.deal(address(this), 1 << 200);
        int24[5] memory spacings = [int24(10), int24(30), int24(60), int24(100), int24(200)];
        Currency c0 = _eth() ? CurrencyLibrary.ADDRESS_ZERO : currency0;
        for (uint256 i = 0; i < 5; ++i) {
            keys[i] = PoolKey(c0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, spacings[i], IHooks(hookAddr));
            _initialConfig(i);
            FablesFeeEngine(hookAddr).initializePool(keys[i], SQRT_PRICE_1_1);
            modifyLiquidityRouter.modifyLiquidity{value: _eth() ? 1e26 : 0}(
                keys[i],
                IPoolManager.ModifyLiquidityParams({
                    tickLower: TickMath.minUsableTick(spacings[i]),
                    tickUpper: TickMath.maxUsableTick(spacings[i]),
                    liquidityDelta: int256(uint256(SEED_L)),
                    salt: 0
                }),
                ""
            );
        }
        actors = [makeAddr("lpA"), makeAddr("lpB"), makeAddr("lpC")];
        handler = new CategoryHandler(manager, hookAddr, _eth(), keys, actors);
        authority.grantRole(0, address(handler), 0);
        MockERC20(Currency.unwrap(currency1)).transfer(address(handler), 1 << 250);
        if (!_eth()) MockERC20(Currency.unwrap(currency0)).transfer(address(handler), 1 << 250);
        vm.deal(address(handler), 1 << 200);
        for (uint256 a = 0; a < 3; ++a) {
            MockERC20(Currency.unwrap(currency1)).transfer(actors[a], 1e30);
            if (!_eth()) MockERC20(Currency.unwrap(currency0)).transfer(actors[a], 1e30);
        }
        handler.wire();
        for (uint256 i = 0; i < 5; ++i) {
            for (uint256 a = 0; a < 3; ++a) {
                handler.deposit(i, a, a, 1e18 * (a + 1));
            }
        }
        handler.setBudget(Depth.budget(Depth.PR_STEPS));
        targetContract(address(handler));
        targetSelector(StdInvariant.FuzzSelector({addr: address(handler), selectors: handler.fuzzSelectors()}));
    }

    function _initialConfig(uint256 i) internal {
        CategoryTable.Cat memory t = CategoryTable.get(uint8(i + 1));
        uint24 cap = t.capMax / 2;
        uint24 base = t.floorMin + (cap - t.floorMin) / 3;
        uint24 b1 = base + (cap - base) / 4;
        FablesFeeEngine(hookAddr).configurePool(keys[i], uint8(i + 1), base, b1, t.floorMin, cap);
    }

    function invariant_categoryProperties() public view {
        if (handler.noop()) return;
        _checkHandlerSawNoViolation();
        _checkWordsStayInTheirCategoryBand();
        _checkResolvedFeeInBandAndEqualsTheTwin();
        _checkLedgerConservation();
        _checkRangeSharesEqualPoolLiquidity();
        _checkNoEthParkedOnTheHook();
    }

    function _checkHandlerSawNoViolation() internal view {
        assertEq(handler.violations(), 0, handler.firstViolation());
    }

    function _checkWordsStayInTheirCategoryBand() internal view {
        for (uint256 i = 0; i < 5; ++i) {
            PoolId id = keys[i].toId();
            CategoryTable.Cat memory t = CategoryTable.get(uint8(i + 1));
            uint256 w = FablesFeeEngine(hookAddr).poolWord(id);
            uint256 lo = w.base0() < w.base1() ? w.base0() : w.base1();
            uint256 hi = w.base0() < w.base1() ? w.base1() : w.base0();
            assertGe(w.cap(), 1, "cap back to 0");
            assertLe(w.cap(), t.capMax, "cap above the category cap");
            assertLe(t.capMax, CategoryTable.ABSOLUTE_MAX_FEE, "category cap above 100_000");
            assertGe(w.floor(), t.floorMin, "floor under the category floor");
            assertLe(w.floor(), lo, "floor above a base");
            assertLe(hi, w.cap(), "base above the cap");
            assertEq(FablesFeeEngine(hookAddr).maxFee(id), w.cap(), "maxFee != cap");
            assertEq(FablesFeeEngine(hookAddr).categoryOf(id), i + 1, "pool left its category");
        }
    }

    function _checkResolvedFeeInBandAndEqualsTheTwin() internal view {
        for (uint256 i = 0; i < 5; ++i) {
            PoolId id = keys[i].toId();
            uint256 w = FablesFeeEngine(hookAddr).poolWord(id);
            (, int24 tick,,) = manager.getSlot0(id);
            for (uint256 s = 0; s < 2; ++s) {
                bool z = s == 0;
                uint256 fee = FablesFeeFull(hookAddr).currentFee(id, z);
                uint256 cf = FablesFeeFull(hookAddr).cfWord(id);
                (uint256 twin,) = FeeRef.resolve(w, z, address(0), 0, cf, tick, block.timestamp);
                assertEq(fee, twin, "currentFee != FeeRef.resolve");
                assertLe(fee, w.cap(), "resolved fee above the cap");
                assertGe(fee, w.floor(), "resolved fee under the floor");
            }
        }
    }

    function _checkLedgerConservation() internal view {
        (uint256 p0, uint256 p1) = _promisedQ();
        assertLe(p0, manager.balanceOf(hookAddr, keys[0].currency0.toId()) * Q128, "currency0 over-promised");
        assertLe(p1, manager.balanceOf(hookAddr, keys[0].currency1.toId()) * Q128, "currency1 over-promised");
    }

    function _checkRangeSharesEqualPoolLiquidity() internal view {
        for (uint256 i = 0; i < 5; ++i) {
            for (uint256 k = 0; k < 2; ++k) {
                uint256 rid = handler.rangeIdAt(i, k);
                RangeState memory r = FablesLedgerV2(payable(hookAddr)).rangeState(rid);
                (uint128 liq,,) =
                    manager.getPositionInfo(keys[i].toId(), hookAddr, handler.lowers(k), handler.uppers(k), bytes32(0));
                assertEq(uint256(r.totalShares), uint256(liq), "range shares != PoolManager liquidity");
            }
        }
    }

    function _checkNoEthParkedOnTheHook() internal view {
        assertEq(hookAddr.balance, 0, "ETH left on the hook");
    }

    function _promisedQ() internal view returns (uint256 q0, uint256 q1) {
        FablesLedgerV2 l = FablesLedgerV2(payable(hookAddr));
        q0 = (l.distributorOwed(keys[0].currency0) + l.claimFeeOwed(keys[0].currency0)) * Q128;
        q1 = (l.distributorOwed(keys[0].currency1) + l.claimFeeOwed(keys[0].currency1)) * Q128;
        for (uint256 i = 0; i < 5; ++i) {
            for (uint256 k = 0; k < 2; ++k) {
                uint256 rid = handler.rangeIdAt(i, k);
                RangeState memory r = l.rangeState(rid);
                for (uint256 a = 0; a < 3; ++a) {
                    UserPosition memory u = l.userPosition(rid, actors[a]);
                    uint256 unstaked = l.balanceOf(actors[a], rid) - u.staked;
                    q0 += uint256(u.owed0) * Q128 + unstaked * (r.accFee0X128 - u.checkpoint0X128);
                    q1 += uint256(u.owed1) * Q128 + unstaked * (r.accFee1X128 - u.checkpoint1X128);
                }
            }
        }
    }

    function afterInvariant() public view {
        string[13] memory names = [
            "configure",
            "poke",
            "clearPoke",
            "discountGrant",
            "discountRevoke",
            "discountFilter",
            "cfConfigure",
            "cfSwitch",
            "cfKill",
            "swap",
            "deposit",
            "withdraw",
            "claim"
        ];
        for (uint256 i = 0; i < names.length; ++i) {
            (uint256 l, uint256 r) = handler.counts(bytes32(bytes(names[i])));
            if (l + r != 0) console.log(string.concat(names[i], " landed/refused"), l, r);
        }
        console.log("raises landed", handler.raisesLanded());
        console.log(
            "swaps with live poke / discount / CF",
            handler.swapsWithLivePoke(),
            handler.swapsWithDiscount(),
            handler.swapsWithCF()
        );
        console.log("max charged fee", handler.maxChargedFee());
    }

    function test_scriptedWalkReachesEveryDoor() public {
        handler.setBudget(type(uint256).max);
        for (uint256 p = 0; p < 5; ++p) {
            handler.configure(p, 1_000, 2_000, 0, 9_000, 1);
            handler.pokeRaise(p, 100, 100, 1 hours);
            handler.pokeRaise(p, 100, 100, 1 hours);
            handler.swap(p, 0, true, 1e18, false);
            handler.swap(p, 1, false, 1e18, true);
            handler.warpShort(61);
            handler.poke(p, 1, 1, 1 hours, 1);
            handler.swapLarge(p, 2, true, 1e22, false);
            handler.discountGrant(p, 0, CategoryHandler.DiscIn(5_000, 0, 3, 1 days, 1));
            handler.swap(p, 0, true, 1e18, false);
            handler.cfConfigure(p, CategoryHandler.CFIn(uint8(p % 2), 256, 2_500, 0, 5, 1), 1);
            handler.cfSwitch(p, 1);
            handler.swapLarge(p, 1, false, 3e23, false);
            handler.warpShort(2);
            handler.swapLarge(p, 2, false, 3e23, false);
            handler.discountFilter(p, 7, 1);
            handler.discountRevoke(p, 0, false);
            handler.cfSwitch(p, 2);
            handler.clearPoke(p);
            handler.deposit(p, 0, 0, 1e20);
            handler.withdraw(p, 1, 1, 1e17);
            handler.claim(p, 2, 0);
        }
        (uint256 l,) = handler.counts("swap");
        assertGt(l, 10, "swaps never land");
        assertGt(handler.raisesLanded(), 0, "no raise ever landed");
        assertGt(handler.swapsWithDiscount(), 0, "no discounted swap");
        assertGt(handler.swapsWithCF(), 0, "no swap with the CF on");
        _checkHandlerSawNoViolation();
        _checkWordsStayInTheirCategoryBand();
        _checkResolvedFeeInBandAndEqualsTheTwin();
        _checkLedgerConservation();
        _checkRangeSharesEqualPoolLiquidity();
        _checkNoEthParkedOnTheHook();
    }
}

contract CategoryInvariantTest is CategoryInvariantBase {
    function _eth() internal pure override returns (bool) {
        return false;
    }
}

/// @notice Same walk on FablesHookETH with native currency0.
contract CategoryInvariantETHTest is CategoryInvariantBase {
    function _eth() internal pure override returns (bool) {
        return true;
    }
}
