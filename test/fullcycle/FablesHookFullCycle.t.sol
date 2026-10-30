// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {Position} from "v4-core/src/libraries/Position.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {FablesFeeEngine} from "../../src/base/FablesFeeEngine.sol";
import {FablesFeeFull} from "../../src/base/FablesFeeFull.sol";
import {FablesLedgerV2} from "../../src/base/FablesLedgerV2.sol";
import {FablesHookCore} from "../../src/base/FablesHookCore.sol";
import {FablesExclusiveLiquidityV2} from "../../src/base/FablesExclusiveLiquidityV2.sol";
import {DiscountLib} from "../../src/libraries/DiscountLib.sol";
import {MockERC20} from "../utils/mocks/MockERC20.sol";
import {FullCycleBase} from "./FullCycleBase.sol";

/// @notice Full lifecycle per FablesHook build: configure, initialize, LPs, swaps, pokes, discount, CF, staking,
///         claims, sweeps, pause and exits, with fee conservation.
contract FablesHookFullCycleTest is FullCycleBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    struct Build {
        string name;
        string family;
        uint160 flags;
        bool eth;
        bool exclusive;
    }

    struct Ctx {
        PoolKey key;
        PoolId id;
        uint256 u0;
        uint256 u1;
        int24 wLo;
        int24 wHi;
        int24 nLo;
        int24 nHi;
        uint256 wideId;
        uint256 narrowId;
    }

    uint8 internal constant CAT = 7;
    uint24 internal constant FLOOR_MIN = 100;
    uint24 internal constant CAP_MAX = 10_000;
    uint24 internal constant RAISE_STEP = 500;
    uint24 internal constant FLOOR = 1_000;
    uint24 internal constant CAP = 8_000;
    uint24 internal constant BASE0 = 3_000;
    uint16 internal constant CLAIM_BPS = 1_000;
    int24 internal constant TS = 60;
    uint256 internal constant DEPTH = 100_000;
    uint128 internal constant SWAP_UNITS = 500;

    Build internal b;
    address internal hook;
    Ctx internal C;
    MockERC20 internal six;
    MockERC20 internal e18;
    PoolSwapTest internal mmRouter;

    address internal alice = makeAddr("fc.alice");
    address internal bob = makeAddr("fc.bob");
    address internal carol = makeAddr("fc.carol");
    address internal dave = makeAddr("fc.dave");
    address internal eve = makeAddr("fc.eve");
    address internal mm = makeAddr("fc.mm");
    address internal voter = makeAddr("fc.voter");

    mapping(address currency => uint256) internal lpFees;
    mapping(address sink => mapping(address currency => uint256)) internal sinkStart;

    function test_fullCycle_FablesHook() public {
        _run(Build("FablesHook", "FablesHook", FLAGS_FEE_FULL, false, false));
    }

    function test_fullCycle_FablesHookETH() public {
        _run(Build("FablesHookETH", "FablesHook", FLAGS_FEE_FULL, true, false));
    }

    function test_fullCycle_FablesHookExclusive() public {
        _run(Build("FablesHookExclusive", "FablesHook", FLAGS_FEE_FULL_EXCLUSIVE, false, true));
    }

    function test_fullCycle_FablesHookETHExclusive() public {
        _run(Build("FablesHookETHExclusive", "FablesHook", FLAGS_FEE_FULL_EXCLUSIVE, true, true));
    }

    function _run(Build memory build_) internal {
        b = build_;
        setUpRC(6, 18, 18);
        _deployAuthority();
        (six, e18) = _pickTokens();
        hook = flagged(string.concat("fc.", b.name), b.flags);
        bytes memory args = b.eth ? abi.encode(pm, address(am), address(weth)) : abi.encode(pm, address(am));
        deployCodeTo(string.concat(b.name, ".sol:", b.name), args, hook);
        _bindFamily(hook, b.family);
        _handOver();
        _globalSetup();

        _pool(Currency.wrap(address(six)), Currency.wrap(address(e18)));
        if (b.eth) _pool(CurrencyLibrary.ADDRESS_ZERO, Currency.wrap(address(six)));
    }

    function _pickTokens() internal view returns (MockERC20 s, MockERC20 e) {
        MockERC20[3] memory t = [tokA, tokB, tokC];
        for (uint256 i; i < 3; i++) {
            if (t[i].decimals() == 6) s = t[i];
            else if (address(e) == address(0)) e = t[i];
        }
    }

    function _globalSetup() internal {
        bytes[] memory d = new bytes[](3);
        d[0] = abi.encodeCall(FablesFeeEngine.setCategory, (CAT, FLOOR_MIN, CAP_MAX, RAISE_STEP, "MAJOR"));
        d[1] = abi.encodeCall(FablesLedgerV2.setBallotGate, (address(gate)));
        d[2] = abi.encodeCall(FablesLedgerV2.setDistributor, (new Currency[](0), address(distributor)));
        _adminBatch(hook, d);
        FablesFeeEngine.Category memory c = FablesFeeEngine(hook).category(CAT);
        assertTrue(c.exists && c.capMax == CAP_MAX && c.raiseStep == RAISE_STEP, "category");
        assertEq(FablesLedgerV2(payable(hook)).ballotGate(), address(gate), "gate");
        assertEq(FablesLedgerV2(payable(hook)).distributor(), address(distributor), "distributor");
    }

    function _pool(Currency a, Currency bb) internal {
        (Currency x0, Currency x1) = Currency.unwrap(a) < Currency.unwrap(bb) ? (a, bb) : (bb, a);
        C.key = dynamicKey(x0, x1, TS, hook);
        C.id = C.key.toId();
        _resetAccounting();
        _configureAndInit();
        _deposits();
        _baseSwaps();
        _discount();
        _pokes();
        _continuationFee();
        _stakeAndClaims();
        _pause();
        _exitAll();
        _assertConserved();
    }

    function _resetAccounting() internal {
        address[2] memory cs = [Currency.unwrap(C.key.currency0), Currency.unwrap(C.key.currency1)];
        for (uint256 i; i < 2; i++) {
            feesCharged[cs[i]] = 0;
            swapsIn[cs[i]] = 0;
            lpFees[cs[i]] = 0;
            sinkStart[treasury][cs[i]] = _sinkBal(Currency.wrap(cs[i]), treasury);
            sinkStart[address(distributor)][cs[i]] = _sinkBal(Currency.wrap(cs[i]), address(distributor));
        }
    }

    function _base1() internal pure returns (uint24) {
        return 2_500;
    }

    function _configureAndInit() internal {
        int24 t0;
        if (C.key.currency0.isAddressZero()) {
            t0 = -200_340;
            (C.u0, C.u1) = (5e14, 1e6);
        } else if (Currency.unwrap(C.key.currency0) == address(six)) {
            t0 = 276_300;
            (C.u0, C.u1) = (1e6, 1e18);
        } else {
            t0 = -276_300;
            (C.u0, C.u1) = (1e18, 1e6);
        }
        uint160 sqrtP = TickMath.getSqrtPriceAtTick(t0);

        vm.prank(multisig);
        vm.expectRevert(FablesHookCore.PoolNotConfigured.selector);
        FablesFeeEngine(hook).initializePool(C.key, sqrtP);
        vm.prank(stranger);
        vm.expectRevert(
            _wrapped(
                hook,
                IHooks.beforeInitialize.selector,
                abi.encodeWithSelector(FablesFeeEngine.InvalidInitializer.selector, stranger)
            )
        );
        pm.initialize(C.key, sqrtP);

        bytes[] memory d = new bytes[](2);
        d[0] = abi.encodeCall(FablesFeeEngine.configurePool, (C.key, CAT, BASE0, _base1(), FLOOR, CAP));
        d[1] = abi.encodeCall(FablesLedgerV2.setClaimFee, (C.key, new Currency[](0), CLAIM_BPS, treasury));
        _adminBatch(hook, d);
        assertEq(FablesFeeEngine(hook).maxFee(C.id), CAP, "maxFee mirrors cap");
        assertEq(FablesLedgerV2(payable(hook)).claimFeeBps(C.id), CLAIM_BPS, "claim fee");

        _initPool(sqrtP);
        assertEq(FablesFeeFull(hook).currentFee(C.id, true), BASE0, "base0");
        assertEq(FablesFeeFull(hook).currentFee(C.id, false), _base1(), "base1");

        C.wLo = _align(t0 - 12_000, TS);
        C.wHi = _align(t0 + 12_000, TS);
        C.nLo = _align(t0 - 600, TS);
        C.nHi = _align(t0 + 600, TS);
        FablesLedgerV2 l = FablesLedgerV2(payable(hook));
        C.wideId = l.rangeId(C.id, C.wLo, C.wHi);
        C.narrowId = l.rangeId(C.id, C.nLo, C.nHi);

        address[6] memory lps = [alice, bob, carol, dave, eve, mm];
        for (uint256 i; i < lps.length; i++) {
            _fund(lps[i], C.key.currency0, 10 * DEPTH * C.u0);
            _fund(lps[i], C.key.currency1, 10 * DEPTH * C.u1);
            _approveAll(lps[i], C.key.currency0, hook);
            _approveAll(lps[i], C.key.currency1, hook);
        }
        _fund(trader, C.key.currency0, 100 * DEPTH * C.u0);
        if (address(mmRouter) == address(0)) mmRouter = new PoolSwapTest(pm);
        _approveAll(mm, C.key.currency0, address(mmRouter));
        _approveAll(mm, C.key.currency1, address(mmRouter));
    }

    function _initPool(uint160 sqrtP) internal {
        vm.prank(stranger);
        vm.expectRevert(_unauthorized(stranger));
        FablesFeeEngine(hook).initializePool(C.key, sqrtP);
        vm.prank(multisig);
        FablesFeeEngine(hook).initializePool(C.key, sqrtP);
        vm.prank(multisig);
        vm.expectRevert(abi.encodeWithSelector(bytes4(keccak256("PoolAlreadyInitialized()"))));
        FablesFeeEngine(hook).initializePool(C.key, sqrtP);
    }

    function test_strangerCannotInitializeAConfiguredPool() public {
        b = Build("FablesHook", "FablesHook", FLAGS_FEE_FULL, false, false);
        setUpRC(6, 18, 18);
        _deployAuthority();
        (six, e18) = _pickTokens();
        hook = flagged("fc.initializer", b.flags);
        deployCodeTo("FablesHook.sol:FablesHook", abi.encode(pm, address(am)), hook);
        _bindFamily(hook, b.family);
        _handOver();
        _globalSetup();
        (address x0, address x1) =
            address(six) < address(e18) ? (address(six), address(e18)) : (address(e18), address(six));
        C.key = dynamicKey(Currency.wrap(x0), Currency.wrap(x1), TS, hook);
        _admin(hook, abi.encodeCall(FablesFeeEngine.configurePool, (C.key, CAT, BASE0, BASE0, FLOOR, CAP)));
        vm.prank(stranger);
        vm.expectRevert(
            _wrapped(
                hook,
                IHooks.beforeInitialize.selector,
                abi.encodeWithSelector(FablesFeeEngine.InvalidInitializer.selector, stranger)
            )
        );
        pm.initialize(C.key, TickMath.getSqrtPriceAtTick(0));
    }

    function _deposits() internal {
        uint128 le = _liqFor(C.id, C.nLo, C.nHi, 1_000 * C.u0, 1_000 * C.u1);
        (uint256 p0, uint256 p1) = _deposit(eve, C.nLo, C.nHi, le);
        (uint256 r0, uint256 r1) = _withdraw(eve, C.nLo, C.nHi, le);
        assertApproxEqAbs(r0, p0, 2, "eve round trip c0");
        assertApproxEqAbs(r1, p1, 2, "eve round trip c1");
        assertLe(r0, p0, "rounding favours the pool c0");
        assertLe(r1, p1, "rounding favours the pool c1");

        uint128 lw = _liqFor(C.id, C.wLo, C.wHi, DEPTH * C.u0, DEPTH * C.u1);
        uint128 ln = _liqFor(C.id, C.nLo, C.nHi, DEPTH * C.u0 / 4, DEPTH * C.u1 / 4);
        _deposit(alice, C.wLo, C.wHi, lw);
        _deposit(carol, C.wLo, C.wHi, lw);
        _deposit(bob, C.nLo, C.nHi, ln);
        FablesLedgerV2 l = FablesLedgerV2(payable(hook));
        assertEq(l.balanceOf(alice, C.wideId), lw, "alice receipts 1:1 with liquidity");
        assertEq(l.rangeState(C.wideId).totalShares, uint256(lw) * 2, "wide supply");
        assertEq(
            pm.getPositionLiquidity(C.id, Position.calculatePositionKey(hook, C.wLo, C.wHi, bytes32(0))),
            uint256(lw) * 2,
            "one PoolManager position per range, == shares"
        );

        if (b.exclusive) {
            vm.expectRevert(
                _wrapped(
                    hook,
                    IHooks.beforeAddLiquidity.selector,
                    abi.encodeWithSelector(FablesExclusiveLiquidityV2.LiquidityOnlyViaLedger.selector)
                )
            );
            addLiquidity(C.key, C.nLo, C.nHi, 1e9);
        } else if (!C.key.currency0.isAddressZero()) {
            addLiquidity(C.key, C.nLo, C.nHi, 1e9);
            addLiquidity(C.key, C.nLo, C.nHi, -1e9);
        }
        if (b.eth) {
            (bool ok,) = hook.call{value: 1}("");
            assertFalse(ok, "the hook refuses ETH from anyone but the PoolManager");
        }
    }

    function _baseSwaps() internal {
        for (uint256 i; i < 3; i++) {
            vm.warp(block.timestamp + 17 minutes);
            assertEq(_swap(trader, C.key, true, uint128(SWAP_UNITS * C.u0)), BASE0, "base fee 0->1");
            vm.warp(block.timestamp + 5 minutes);
            assertEq(_swap(trader, C.key, false, uint128(SWAP_UNITS * C.u1)), _base1(), "base fee 1->0");
        }
    }

    function _discount() internal {
        PoolId[] memory ids = new PoolId[](1);
        ids[0] = C.id;
        address exec = address(mmRouter);
        bytes memory grant = abi.encodeCall(
            FablesFeeEngine.setDiscount,
            (ids, exec, 2_000, 1_200, uint8(DiscountLib.DIR_BOTH), uint40(block.timestamp + 30 days))
        );
        bytes32 op = am.hashOperation(discountAdmin, hook, grant);
        vm.prank(discountAdmin);
        vm.expectRevert(abi.encodeWithSignature("AccessManagerNotScheduled(bytes32)", op));
        am.execute(hook, grant);
        _delayed(discountAdmin, hook, grant);
        (, uint64 bloom) = FablesFeeEngine(hook).discountFilter(C.id);
        assertTrue(bloom != 0, "bloom bit set");

        FablesFeeFull f = FablesFeeFull(hook);
        assertEq(f.feeFor(C.id, true, exec), 2_400, "ceil(3000 * 0.8)");
        assertEq(f.feeFor(C.id, false, exec), 2_000, "ceil(2500 * 0.8)");
        assertEq(f.feeFor(C.id, true, address(UR_ADDR)), BASE0, "the router is not discounted");
        assertEq(_swapVia(mmRouter, mm, C.key, true, uint128(SWAP_UNITS * C.u0)), 2_400, "mm pays the discount");
        assertEq(_swapVia(mmRouter, mm, C.key, false, uint128(SWAP_UNITS * C.u1)), 2_000, "both directions");
        assertEq(_swap(trader, C.key, true, uint128(SWAP_UNITS * C.u0)), BASE0, "router flow pays the full fee");

        address[] memory accts = new address[](1);
        accts[0] = exec;
        vm.prank(stranger);
        vm.expectRevert(_unauthorized(stranger));
        FablesFeeEngine(hook).revokeDiscount(ids, accts);
        vm.prank(guardian);
        FablesFeeEngine(hook).revokeDiscount(ids, accts);
        assertEq(_swapVia(mmRouter, mm, C.key, true, uint128(SWAP_UNITS * C.u0)), BASE0, "revoked");

        _delayed(discountAdmin, hook, abi.encodeCall(FablesFeeEngine.setDiscountFilter, (C.id, 9, accts)));
        (uint8 seed, uint64 bloom2) = FablesFeeEngine(hook).discountFilter(C.id);
        assertEq(seed, 9, "reseeded");
        assertEq(bloom2, 0, "rebuilt without the revoked entry");
    }

    function _poke(uint24 f0, uint24 f1, uint40 ttl) internal {
        vm.prank(poker);
        FablesFeeEngine(hook).pokeFee(C.id, f0, f1, ttl);
    }

    function _pokeExpect(uint24 f0, uint24 f1, uint40 ttl, bytes4 err) internal {
        vm.prank(poker);
        vm.expectRevert(err);
        FablesFeeEngine(hook).pokeFee(C.id, f0, f1, ttl);
    }

    function _expectFees(uint24 f0, uint24 f1, string memory what) internal {
        vm.warp(block.timestamp + 1);
        assertEq(_swap(trader, C.key, true, uint128(SWAP_UNITS * C.u0)), f0, string.concat(what, " 0->1"));
        assertEq(_swap(trader, C.key, false, uint128(SWAP_UNITS * C.u1)), f1, string.concat(what, " 1->0"));
    }

    function _pokes() internal {
        uint24 b1 = _base1();
        vm.prank(stranger);
        vm.expectRevert(_unauthorized(stranger));
        FablesFeeEngine(hook).pokeFee(C.id, 3_400, 0, 1 hours);
        vm.prank(multisig);
        vm.expectRevert(_unauthorized(multisig));
        FablesFeeEngine(hook).pokeFee(C.id, 3_400, 0, 1 hours);

        _poke(3_400, 0, 1 hours);
        _expectFees(3_400, b1, "side 0 raised");
        _pokeExpect(3_800, 0, 1 hours, FablesFeeEngine.RaiseTooSoon.selector);
        vm.warp(block.timestamp + 61);
        _pokeExpect(4_000, 0, 1 hours, FablesFeeEngine.RaiseTooLarge.selector);
        _pokeExpect(0, 3_100, 1 hours, FablesFeeEngine.RaiseTooLarge.selector);
        _poke(3_800, 2_900, 1 hours);
        vm.warp(block.timestamp + 10);
        _poke(3_800, 2_900, 2 hours);
        _expectFees(3_800, 2_900, "renewed");
        _poke(1_000, 0, 1 hours);
        _expectFees(1_500, b1, "cut");
        vm.warp(block.timestamp + 1 hours);
        _expectFees(BASE0, b1, "expired");
        _pokeExpect(9_000, 0, 1 hours, FablesFeeEngine.FeeAboveCap.selector);
        _pokeExpect(500, 0, 1 hours, FablesFeeEngine.FeeBelowFloor.selector);
        _pokeExpect(3_200, 0, 0, FablesFeeEngine.InvalidTtl.selector);
        _pokeExpect(3_200, 0, 72 hours + 1, FablesFeeEngine.InvalidTtl.selector);
        _pokeExpect(0, 0, 1 hours, FablesFeeEngine.EmptyPoke.selector);

        vm.warp(block.timestamp + 61);
        _poke(3_400, b1, 1 hours);
        vm.prank(guardian);
        FablesFeeEngine(hook).clearPoke(C.id);
        (uint24 p0, uint24 p1, uint40 exp) = FablesFeeEngine(hook).pokeOf(C.id);
        assertEq(uint256(p0) + p1 + exp, 0, "poke cleared");
        _expectFees(BASE0, b1, "cleared");
    }

    function _continuationFee() internal {
        FablesFeeFull f = FablesFeeFull(hook);
        uint24 b1 = _base1();
        vm.prank(poker);
        vm.expectRevert(FablesFeeEngine.CFNotConfigured.selector);
        f.setCFActive(C.id, true, TickMath.MIN_TICK, TickMath.MAX_TICK, type(uint256).max);

        _admin(hook, abi.encodeCall(FablesFeeEngine.configureCF, (C.id, 0, 256, 2_500, 0, 60, 1)));
        vm.prank(poker);
        f.setCFActive(C.id, true, TickMath.MIN_TICK, TickMath.MAX_TICK, type(uint256).max);
        assertEq(_swap(trader, C.key, true, uint128(8 * SWAP_UNITS * C.u0)), BASE0, "anchored at the tick: no CF yet");
        vm.warp(block.timestamp + 1);
        uint24 cont = f.currentFee(C.id, true);
        assertGt(cont, BASE0, "mode 0 charges the continuation");
        assertEq(f.currentFee(C.id, false), b1, "mode 0 leaves the reversal on base");
        assertEq(_swap(trader, C.key, true, uint128(SWAP_UNITS * C.u0)), cont, "charged == twin view");

        vm.prank(poker);
        f.setCFActive(C.id, false, 0, 0, 0);
        assertEq(f.currentFee(C.id, true), BASE0, "CF off");
        vm.prank(guardian);
        f.killCF(C.id);
        vm.prank(poker);
        vm.expectRevert(FablesFeeEngine.CFNotConfigured.selector);
        f.setCFActive(C.id, true, TickMath.MIN_TICK, TickMath.MAX_TICK, type(uint256).max);

        _admin(hook, abi.encodeCall(FablesFeeEngine.configureCF, (C.id, 1, 256, 2_500, 0, 60, 1)));
        vm.prank(poker);
        f.setCFActive(C.id, true, TickMath.MIN_TICK, TickMath.MAX_TICK, type(uint256).max);
        assertEq(_swap(trader, C.key, true, uint128(8 * SWAP_UNITS * C.u0)), BASE0, "re-armed: no CF yet");
        vm.warp(block.timestamp + 1);
        uint24 rev = f.currentFee(C.id, false);
        assertGt(rev, b1, "mode 1 charges the reversal");
        assertEq(f.currentFee(C.id, true), BASE0, "mode 1 leaves the continuation on base");
        assertEq(_swap(trader, C.key, false, uint128(SWAP_UNITS * C.u1)), rev, "charged == twin view");
        vm.prank(poker);
        f.setCFActive(C.id, false, 0, 0, 0);
        _expectFees(BASE0, b1, "CF off again");
    }

    function _stakeAndClaims() internal {
        FablesLedgerV2 l = FablesLedgerV2(payable(hook));
        uint128 half = uint128(l.balanceOf(alice, C.wideId) / 2);
        vm.prank(alice);
        l.stake(C.key, C.wLo, C.wHi, half, 0);
        assertEq(l.userPosition(C.wideId, alice).staked, half, "staked");
        uint256 tooMany = l.balanceOf(alice, C.wideId) - half + 1;
        vm.prank(alice);
        vm.expectRevert(FablesLedgerV2.InsufficientUnstakedShares.selector);
        l.transfer(bob, C.wideId, tooMany);

        _churn(4);
        uint256[] memory ids = new uint256[](1);
        ids[0] = C.wideId;
        vm.prank(voter);
        l.syncRanges(1, ids);
        assertGt(l.distributorOwed(C.key.currency0) + l.distributorOwed(C.key.currency1), 0, "staked fees banked");

        _claim(alice, C.wLo, C.wHi);
        _claim(bob, C.nLo, C.nHi);
        uint256 third = l.balanceOf(carol, C.wideId) / 3;
        vm.prank(carol);
        l.transfer(dave, C.wideId, third);

        _delayed(revenueOps, hook, abi.encodeCall(FablesLedgerV2.setClaimFeeBps, (C.key, 500)));
        assertEq(l.claimFeeBps(C.id), 500, "REVENUE_OPS rate");
        _churn(2);

        _sweeps();
        assertEq(l.claimFeeOwed(C.key.currency0) + l.claimFeeOwed(C.key.currency1), 0, "claim-fee pot swept");
        assertGt(
            _sinkBal(C.key.currency0, treasury) - sinkStart[treasury][Currency.unwrap(C.key.currency0)],
            0,
            "treasury paid"
        );

        vm.prank(alice);
        l.unstake(C.key, C.wLo, C.wHi, half / 2);
        _churn(2);
    }

    function _churn(uint256 n) internal {
        for (uint256 i; i < n; i++) {
            vm.warp(block.timestamp + 13 minutes);
            _swap(trader, C.key, i % 2 == 0, uint128(SWAP_UNITS * (i % 2 == 0 ? C.u0 : C.u1)));
        }
    }

    function _sweeps() internal {
        FablesLedgerV2 l = FablesLedgerV2(payable(hook));
        vm.startPrank(stranger);
        l.sweepClaimFee(C.key.currency0);
        l.sweepClaimFee(C.key.currency1);
        l.sweepDistributor(C.key.currency0);
        l.sweepDistributor(C.key.currency1);
        vm.stopPrank();
        _assertSettled();
    }

    function _pause() internal {
        FablesLedgerV2 l = FablesLedgerV2(payable(hook));
        vm.prank(guardian);
        l.pause(7 days);
        assertTrue(l.paused(), "paused");
        vm.prank(guardian);
        vm.expectRevert(FablesLedgerV2.PauseTooLong.selector);
        l.pause(1 days);
        vm.prank(guardian);
        vm.expectRevert(_unauthorized(guardian));
        l.setPaused(0);

        uint128 lw = 1e6;
        vm.prank(carol);
        vm.expectRevert(FablesLedgerV2.LedgerPaused.selector);
        l.deposit{value: C.key.currency0.isAddressZero() ? 1 ether : 0}(
            C.key, C.wLo, C.wHi, lw, type(uint128).max, type(uint128).max, block.timestamp
        );
        vm.prank(bob);
        vm.expectRevert(FablesLedgerV2.LedgerPaused.selector);
        l.claimFees(C.key, C.nLo, C.nHi, bob, 2_000);
        vm.prank(carol);
        vm.expectRevert(FablesLedgerV2.LedgerPaused.selector);
        l.transfer(dave, C.wideId, 1);
        vm.expectRevert(FablesLedgerV2.LedgerPaused.selector);
        l.sweepClaimFee(C.key.currency0);

        _withdraw(bob, C.nLo, C.nHi, uint128(l.balanceOf(bob, C.narrowId) / 4));
        _churn(2);

        _admin(hook, abi.encodeCall(FablesLedgerV2.setPaused, (uint256(0))));
        assertFalse(l.paused(), "ADMIN lifted the freeze");

        vm.prank(guardian);
        l.pausePool(C.key, 3 days);
        assertTrue(l.pausedFor(C.id), "pool frozen");
        vm.prank(dave);
        vm.expectRevert(FablesLedgerV2.LedgerPaused.selector);
        l.claimFees(C.key, C.wLo, C.wHi, dave, 2_000);
        _admin(hook, abi.encodeCall(FablesLedgerV2.setPoolPaused, (C.key, uint256(0))));
        assertFalse(l.pausedFor(C.id), "pool unfrozen");
        _churn(2);
    }

    function _exitAll() internal {
        FablesLedgerV2 l = FablesLedgerV2(payable(hook));
        {
            uint128 s = uint128(l.balanceOf(carol, C.wideId));
            (uint256 e0, uint256 e1) = _amountsFor(C.id, C.wLo, C.wHi, s);
            uint256 b0 = _bal(C.key.currency0, carol);
            uint256 b1 = _bal(C.key.currency1, carol);
            vm.prank(carol);
            l.withdrawAndClaim(C.key, C.wLo, C.wHi, s, carol, 0, 0, block.timestamp, 2_000);
            lpFees[Currency.unwrap(C.key.currency0)] += _bal(C.key.currency0, carol) - b0 - e0;
            lpFees[Currency.unwrap(C.key.currency1)] += _bal(C.key.currency1, carol) - b1 - e1;
        }
        _exit(alice, C.wLo, C.wHi, C.wideId);
        _exit(dave, C.wLo, C.wHi, C.wideId);
        _exit(bob, C.nLo, C.nHi, C.narrowId);
        _sweeps();

        assertEq(l.rangeState(C.wideId).totalShares, 0, "wide range empty");
        assertEq(l.rangeState(C.narrowId).totalShares, 0, "narrow range empty");
        assertEq(pm.getLiquidity(C.id), 0, "pool has no liquidity left");
    }

    function _exit(address lp, int24 lo, int24 hi, uint256 rid) internal {
        FablesLedgerV2 l = FablesLedgerV2(payable(hook));
        uint128 s = uint128(l.balanceOf(lp, rid));
        if (s != 0) _withdraw(lp, lo, hi, s);
        assertEq(l.userPosition(rid, lp).staked, 0, "staked shares auto-unstake on exit");
        _claim(lp, lo, hi);
    }

    function _deposit(address lp, int24 lo, int24 hi, uint128 liq) internal returns (uint256 p0, uint256 p1) {
        (uint256 e0, uint256 e1) = _amountsFor(C.id, lo, hi, liq);
        uint128 m0 = uint128(e0 + e0 / 100 + 2);
        uint128 m1 = uint128(e1 + e1 / 100 + 2);
        uint256 b0 = _bal(C.key.currency0, lp);
        uint256 b1 = _bal(C.key.currency1, lp);
        vm.prank(lp);
        FablesLedgerV2(payable(hook)).deposit{value: C.key.currency0.isAddressZero() ? m0 : 0}(
            C.key, lo, hi, liq, m0, m1, block.timestamp
        );
        p0 = b0 - _bal(C.key.currency0, lp);
        p1 = b1 - _bal(C.key.currency1, lp);
        assertApproxEqAbs(p0, e0, 1, "deposit pays the principal (round up) c0");
        assertApproxEqAbs(p1, e1, 1, "deposit pays the principal (round up) c1");
        assertEq(hook.balance, 0, "no ETH parked on the hook");
        _assertSettled();
    }

    function _withdraw(address lp, int24 lo, int24 hi, uint128 liq) internal returns (uint256 r0, uint256 r1) {
        (uint256 e0, uint256 e1) = _amountsFor(C.id, lo, hi, liq);
        uint256 b0 = _bal(C.key.currency0, lp);
        uint256 b1 = _bal(C.key.currency1, lp);
        vm.prank(lp);
        FablesLedgerV2(payable(hook)).withdraw(C.key, lo, hi, liq, lp, 0, 0, block.timestamp);
        r0 = _bal(C.key.currency0, lp) - b0;
        r1 = _bal(C.key.currency1, lp) - b1;
        assertApproxEqAbs(r0, e0, 1, "withdraw pays the principal c0");
        assertApproxEqAbs(r1, e1, 1, "withdraw pays the principal c1");
        assertEq(hook.balance, 0, "no ETH parked on the hook");
        _assertSettled();
    }

    function _claim(address lp, int24 lo, int24 hi) internal {
        FablesLedgerV2 l = FablesLedgerV2(payable(hook));
        uint256 rid = l.rangeId(C.id, lo, hi);
        if (l.balanceOf(lp, rid) == 0) {
            uint256 o0 = l.userPosition(rid, lp).owed0;
            uint256 o1 = l.userPosition(rid, lp).owed1;
            if (o0 == 0 && o1 == 0) {
                vm.prank(lp);
                vm.expectRevert(FablesLedgerV2.NothingToClaim.selector);
                l.claimFees(C.key, lo, hi, lp, 2_000);
                return;
            }
        }
        uint256 b0 = _bal(C.key.currency0, lp);
        uint256 b1 = _bal(C.key.currency1, lp);
        vm.prank(lp);
        l.claimFees(C.key, lo, hi, lp, 2_000);
        lpFees[Currency.unwrap(C.key.currency0)] += _bal(C.key.currency0, lp) - b0;
        lpFees[Currency.unwrap(C.key.currency1)] += _bal(C.key.currency1, lp) - b1;
        assertEq(l.userPosition(rid, lp).owed0 + l.userPosition(rid, lp).owed1, 0, "owed zeroed");
        _assertSettled();
    }

    function _assertConserved() internal view {
        FablesLedgerV2 l = FablesLedgerV2(payable(hook));
        Currency[2] memory cs = [C.key.currency0, C.key.currency1];
        for (uint256 i; i < 2; i++) {
            Currency c = cs[i];
            address a = Currency.unwrap(c);
            uint256 hookClaims = pm.balanceOf(hook, c.toId());
            uint256 paid = lpFees[a] + (_sinkBal(c, treasury) - sinkStart[treasury][a])
                + (_sinkBal(c, address(distributor)) - sinkStart[address(distributor)][a]);
            uint256 tol = 8 * swapsIn[a] + 64;
            assertGt(feesCharged[a], 0, "fees were charged");
            assertApproxEqAbs(paid + hookClaims, feesCharged[a], swapsIn[a] + 16, "fees paid out == fees charged");
            assertLe(hookClaims, 64, "hook keeps only rounding dust as claims");
            assertEq(l.claimFeeOwed(c), 0, "claim-fee pot empty");
            assertEq(l.distributorOwed(c), 0, "distributor pot empty");
            assertEq(_bal(c, hook), 0, "hook holds no tokens");
            uint256 pmBal = _bal(c, PM_ADDR);
            assertGe(pmBal, hookClaims, "claims are backed");
            assertLe(pmBal - hookClaims, tol, "PoolManager keeps only rounding dust");
        }
        assertEq(IERC20(address(weth)).balanceOf(hook), 0, "no WETH on the hook");
        _assertSettled();
    }
}
