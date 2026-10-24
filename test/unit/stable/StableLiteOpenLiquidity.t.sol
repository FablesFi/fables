// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import "../../utils/StableTestBase.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {PoolDonateTest} from "v4-core/src/test/PoolDonateTest.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FablesHookCore} from "../../../src/base/FablesHookCore.sol";
import {FablesLedgerV2} from "../../../src/base/FablesLedgerV2.sol";
import {MockBallotGate} from "../../utils/mocks/MockBallotGate.sol";

/// @notice Opens its own PoolManager unlock and tries to reach the ledger's position and the hook's claims.
contract PositionThief is IUnlockCallback {
    IPoolManager internal immutable pm;

    constructor(IPoolManager pm_) {
        pm = pm_;
    }

    /// @notice Removes `liquidity` from the range at salt 0 (its own position), or burns 1 unit of `hook`'s claims.
    function attempt(PoolKey memory key, int24 lo, int24 hi, uint128 liquidity, address hook)
        external
        returns (bool ok)
    {
        try pm.unlock(abi.encode(key, lo, hi, liquidity, hook)) {
            ok = true;
        } catch {}
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(pm), "pm");
        (PoolKey memory key, int24 lo, int24 hi, uint128 liquidity, address hook) =
            abi.decode(data, (PoolKey, int24, int24, uint128, address));
        if (liquidity != 0) {
            pm.modifyLiquidity(key, IPoolManager.ModifyLiquidityParams(lo, hi, -int256(uint256(liquidity)), 0), "");
        } else {
            pm.burn(hook, key.currency0.toId(), 1);
            pm.take(key.currency0, address(this), 1);
        }
        return "";
    }
}

/// @notice FablesStableHookLite with outside LPs next to the ledger in the same pool and in same or overlapping ranges:
///         pro-rata fees, ledger outcomes equal to a ledger-only run, no access to ledger positions or fees, and a
///         hook pause that stops the ledger only.
contract StableLiteOpenLiquidityTest is StableTestBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint256 internal constant Q128 = 1 << 128;
    int24 internal constant SPACING = 10;
    // ledger ranges A (alice, bob) and B (carol); outside LPs on A itself and on X, which overlaps both
    int24 internal constant A_LO = INIT_TICK - 200;
    int24 internal constant A_HI = INIT_TICK + 200;
    int24 internal constant B_LO = INIT_TICK - 100;
    int24 internal constant B_HI = INIT_TICK + 300;
    int24 internal constant X_LO = INIT_TICK - 300;
    int24 internal constant X_HI = INIT_TICK + 100;
    uint128 internal constant LA = 3e23;
    uint128 internal constant LB = 2e23;
    uint128 internal constant LC = 4e23;
    uint128 internal constant LX_A = 5e23;
    uint128 internal constant LX_X = 25e22;
    uint16 internal constant CLAIM_BPS = 1_000;
    /// @dev Per-LP slack between the two runs (wei): v4 rounds each swap step's fee and growth, the ledger each split.
    uint256 internal constant TOL = 16;

    address internal lite;
    PoolKey internal key;
    PoolId internal id;
    SeqSwapper internal sw;
    PoolDonateTest internal donor;
    address internal alice = makeAddr("ol.alice");
    address internal bob = makeAddr("ol.bob");
    address internal carol = makeAddr("ol.carol");
    address internal mallory = makeAddr("ol.mallory");
    address internal treasury = makeAddr("ol.treasury");

    struct LpOut {
        uint256 receipts;
        uint256 fee0;
        uint256 fee1;
        uint256 principal0;
        uint256 principal1;
    }

    struct Outcome {
        LpOut[3] lp;
        uint256 dist0;
        uint256 dist1;
        uint256 claimFee0;
        uint256 claimFee1;
        uint24[12] fees;
        uint160 sqrtP;
    }

    function setUp() public {
        setUpChain();
        lite = _deployLite("ol-lite");
        key = PoolKey(c0, c1, DYN, SPACING, IHooks(lite));
        id = key.toId();
        (StableFeeConfig memory c, uint160 p0) = _cfgIn();
        _createPool(lite, key, p0, c);
        FablesLedgerV2(payable(lite)).setClaimFee(key, new Currency[](0), CLAIM_BPS, treasury);
        FablesLedgerV2(payable(lite)).setBallotGate(address(new MockBallotGate()));
        sw = new SeqSwapper(pm);
        donor = new PoolDonateTest(pm);
        address[4] memory who = [alice, bob, carol, address(sw)];
        for (uint256 i; i < who.length; i++) {
            MockERC20(Currency.unwrap(c0)).mint(who[i], BIG);
            MockERC20(Currency.unwrap(c1)).mint(who[i], BIG);
            vm.startPrank(who[i]);
            IERC20(Currency.unwrap(c0)).approve(lite, type(uint256).max);
            IERC20(Currency.unwrap(c1)).approve(lite, type(uint256).max);
            vm.stopPrank();
        }
        IERC20(Currency.unwrap(c0)).approve(address(donor), type(uint256).max);
        IERC20(Currency.unwrap(c1)).approve(address(donor), type(uint256).max);
    }

    function _ledger() internal view returns (FablesLedgerV2) {
        return FablesLedgerV2(payable(lite));
    }

    function _deposit(address who, int24 lo, int24 hi, uint128 l) internal {
        vm.prank(who);
        _ledger().deposit(key, lo, hi, l, type(uint128).max, type(uint128).max, block.timestamp);
    }

    function _bal(address who) internal view returns (uint256 b0, uint256 b1) {
        b0 = IERC20(Currency.unwrap(c0)).balanceOf(who);
        b1 = IERC20(Currency.unwrap(c1)).balanceOf(who);
    }

    /// @notice Fees the PoolManager holds for a position, not yet collected.
    function _pending(address owner, int24 lo, int24 hi, bytes32 salt) internal view returns (uint256 f0, uint256 f1) {
        (uint128 l, uint256 last0, uint256 last1) = pm.getPositionInfo(id, owner, lo, hi, salt);
        (uint256 g0, uint256 g1) = pm.getFeeGrowthInside(id, lo, hi);
        unchecked {
            f0 = FullMath.mulDiv(g0 - last0, l, Q128);
            f1 = FullMath.mulDiv(g1 - last1, l, Q128);
        }
    }

    /// @notice Swaps until the price is exactly at `tick`; returns the charged fee (0 if already there).
    function _swapTo(int24 tick) internal returns (uint24 fee) {
        (uint160 p,,,) = pm.getSlot0(id);
        uint160 target = TickMath.getSqrtPriceAtTick(tick);
        if (target == p) return 0;
        bool zfo = target < p;
        vm.recordLogs();
        (bool ok, bytes memory err) = sw.swap(key, zfo, -1e30, target);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(err, 0x20), mload(err))
            }
        }
        bool found;
        (found, fee) = _swapEventFee(vm.getRecordedLogs(), id);
        require(found, "no Swap event");
        (p,,,) = pm.getSlot0(id);
        assertEq(p, target, "the swap stops at the target price");
    }

    function _path() internal pure returns (int24[12] memory to, uint8[12] memory gap) {
        to = [int24(-60), 40, 150, -150, 90, -20, 170, -170, 0, 120, -90, 30];
        gap = [uint8(1), 0, 2, 5, 1, 3, 0, 1, 7, 2, 1, 4];
    }

    function _claim(address who, int24 lo, int24 hi) internal returns (uint256 f0, uint256 f1) {
        (uint256 b0, uint256 b1) = _bal(who);
        vm.prank(who);
        _ledger().claimFees(key, lo, hi, who, 10_000);
        (uint256 a0, uint256 a1) = _bal(who);
        (f0, f1) = (a0 - b0, a1 - b1);
    }

    function _exit(address who, int24 lo, int24 hi, LpOut memory o) internal {
        o.receipts = _ledger().balanceOf(who, _ledger().rangeId(id, lo, hi));
        (uint256 b0, uint256 b1) = _bal(who);
        vm.prank(who);
        _ledger().withdraw(key, lo, hi, uint128(o.receipts), who, 0, 0, block.timestamp);
        (uint256 a0, uint256 a1) = _bal(who);
        (o.principal0, o.principal1) = (a0 - b0, a1 - b1);
    }

    /// @notice One run: three ledger LPs (bob stakes half), a 10% claim fee, a fixed price path; outside positions on
    ///         range A and on range X when `outside`.
    function _run(bool outside) internal returns (Outcome memory o) {
        _deposit(alice, A_LO, A_HI, LA);
        _deposit(bob, A_LO, A_HI, LB);
        vm.prank(bob);
        _ledger().stake(key, A_LO, A_HI, LB / 2, 0);
        _deposit(carol, B_LO, B_HI, LC);
        if (outside) {
            _addDirect(key, A_LO, A_HI, LX_A);
            addLiquidityViaRouter(key, X_LO, X_HI, int256(uint256(LX_X)), bytes32(uint256(1)));
        }
        (int24[12] memory to, uint8[12] memory gap) = _path();
        for (uint256 i; i < 12; i++) {
            _rollClock(gap[i]);
            o.fees[i] = _swapTo(INIT_TICK + to[i]);
        }
        (o.sqrtP,,,) = pm.getSlot0(id);
        if (outside) _checkProRataOnRangeA();
        (o.lp[0].fee0, o.lp[0].fee1) = _claim(alice, A_LO, A_HI);
        (o.lp[1].fee0, o.lp[1].fee1) = _claim(bob, A_LO, A_HI);
        (o.lp[2].fee0, o.lp[2].fee1) = _claim(carol, B_LO, B_HI);
        (o.dist0, o.dist1) = (_ledger().distributorOwed(c0), _ledger().distributorOwed(c1));
        (o.claimFee0, o.claimFee1) = (_ledger().claimFeeOwed(c0), _ledger().claimFeeOwed(c1));
        _exit(alice, A_LO, A_HI, o.lp[0]);
        _exit(bob, A_LO, A_HI, o.lp[1]);
        _exit(carol, B_LO, B_HI, o.lp[2]);
    }

    /// @dev The ledger's and the outside LP's positions on range A earn the same fee per unit of liquidity;
    ///      the ledger then pays out exactly what its position earned, less split dust.
    function _checkProRataOnRangeA() internal {
        (uint256 h0, uint256 h1) = _pending(lite, A_LO, A_HI, 0);
        (uint256 x0, uint256 x1) = _pending(address(liq), A_LO, A_HI, 0);
        assertGt(h0, 0, "ledger earned currency0");
        assertGt(h1, 0, "ledger earned currency1");
        _assertProRata(h0, uint256(LA) + LB, x0, LX_A, "currency0 split pro rata");
        _assertProRata(h1, uint256(LA) + LB, x1, LX_A, "currency1 split pro rata");
        BalanceDelta collected = _addDirect(key, A_LO, A_HI, 0);
        assertEq(uint128(collected.amount0()), x0, "outside LP collects its own share");
        assertEq(uint128(collected.amount1()), x1, "outside LP collects its own share");
        uint256 snap = vm.snapshotState();
        (uint256 out0, uint256 out1) = _claim(alice, A_LO, A_HI);
        (x0, x1) = _claim(bob, A_LO, A_HI);
        out0 += x0 + _ledger().distributorOwed(c0) + _ledger().claimFeeOwed(c0);
        out1 += x1 + _ledger().distributorOwed(c1) + _ledger().claimFeeOwed(c1);
        assertLe(out0, h0, "currency0: the ledger owes no more than its position earned");
        assertLe(out1, h1, "currency1: the ledger owes no more than its position earned");
        assertLe(h0 - out0, 3, "currency0: split dust");
        assertLe(h1 - out1, 3, "currency1: split dust");
        vm.revertToState(snap);
    }

    function _assertProRata(uint256 a, uint256 la, uint256 b, uint256 lb, string memory what) internal pure {
        uint256 l = a * lb;
        uint256 r = b * la;
        assertLe(l > r ? l - r : r - l, la + lb, what);
    }

    function test_ledgerOutcomesMatchALedgerOnlyRun_withOutsideLpsInSameAndOverlappingRanges() public {
        uint256 snap = vm.snapshotState();
        Outcome memory base = _run(false);
        vm.revertToState(snap);
        Outcome memory with = _run(true);

        assertEq(with.sqrtP, base.sqrtP, "same price path");
        for (uint256 i; i < 12; i++) {
            assertEq(with.fees[i], base.fees[i], "same stable fee with outside liquidity");
        }
        assertGt(base.fees[0] + base.fees[2] + base.fees[4], 0, "the path pays fees");
        for (uint256 i; i < 3; i++) {
            assertEq(with.lp[i].receipts, base.lp[i].receipts, "receipts");
            assertEq(with.lp[i].principal0, base.lp[i].principal0, "principal0");
            assertEq(with.lp[i].principal1, base.lp[i].principal1, "principal1");
            assertApproxEqAbs(with.lp[i].fee0, base.lp[i].fee0, TOL, "fee0");
            assertApproxEqAbs(with.lp[i].fee1, base.lp[i].fee1, TOL, "fee1");
            assertGt(base.lp[i].fee0 + base.lp[i].fee1, 0, "each LP earned");
        }
        assertApproxEqAbs(with.dist0, base.dist0, TOL, "staking split currency0");
        assertApproxEqAbs(with.dist1, base.dist1, TOL, "staking split currency1");
        assertGt(base.dist0 + base.dist1, 0, "bob's staked half routes fees");
        assertApproxEqAbs(with.claimFee0, base.claimFee0, TOL, "claim fee currency0");
        assertApproxEqAbs(with.claimFee1, base.claimFee1, TOL, "claim fee currency1");
        assertGt(base.claimFee0 + base.claimFee1, 0, "claim fee charged");
    }

    function test_outsideLpCannotMoveOrTakeLedgerPositionsOrFees() public {
        _deposit(alice, A_LO, A_HI, LA);
        _addDirect(key, A_LO, A_HI, LX_A);
        uint256 rid = _ledger().rangeId(id, A_LO, A_HI);
        _rollClock(1);
        _swapTo(INIT_TICK - 120);
        _rollClock(1);
        _swapTo(INIT_TICK + 80);
        vm.prank(alice);
        _ledger().claimFees(key, A_LO, A_HI, alice, 10_000);
        _rollClock(1);
        assertGt(_swapTo(INIT_TICK - 40), 0, "fees accrue after the claim");
        (uint256 h0, uint256 h1) = _pending(lite, A_LO, A_HI, 0);
        uint256 claims0 = pm.balanceOf(lite, c0.toId());
        assertGt(claims0, 0, "the hook holds synced fees as claims");

        PositionThief thief = new PositionThief(pm);
        assertFalse(thief.attempt(key, A_LO, A_HI, LA, lite), "remove the ledger's liquidity");
        assertFalse(thief.attempt(key, A_LO, A_HI, 0, lite), "burn the hook's claims");
        vm.prank(mallory);
        vm.expectRevert();
        pm.transferFrom(lite, mallory, c0.toId(), 1);
        vm.prank(mallory);
        vm.expectRevert();
        lpRouter.modifyLiquidity(key, IPoolManager.ModifyLiquidityParams(A_LO, A_HI, -int256(uint256(LA)), 0), "");
        vm.expectRevert();
        _removeDirect(key, A_LO, A_HI, LX_A + 1);

        vm.startPrank(mallory);
        vm.expectRevert();
        _ledger().withdraw(key, A_LO, A_HI, LA, mallory, 0, 0, block.timestamp);
        vm.expectRevert(FablesLedgerV2.NothingToClaim.selector);
        _ledger().claimFees(key, A_LO, A_HI, mallory, 10_000);
        vm.expectRevert();
        _ledger().transferFrom(alice, mallory, rid, 1);
        vm.expectRevert(FablesHookCore.NotPoolManager.selector);
        _ledger().unlockCallback("");
        vm.stopPrank();

        _removeDirect(key, A_LO, A_HI, LX_A);
        (uint128 l,,) = pm.getPositionInfo(id, lite, A_LO, A_HI, 0);
        assertEq(l, LA, "the ledger's position is untouched");
        (uint256 g0, uint256 g1) = _pending(lite, A_LO, A_HI, 0);
        assertEq(abi.encode(g0, g1), abi.encode(h0, h1), "the ledger's pending fees are untouched");
        assertEq(pm.balanceOf(lite, c0.toId()), claims0, "the hook's claims are untouched");
        assertEq(_ledger().balanceOf(alice, rid), LA, "alice's receipts are untouched");
        (uint256 f0, uint256 f1) = _claim(alice, A_LO, A_HI);
        assertApproxEqAbs(f0, h0 - h0 * CLAIM_BPS / 10_000, 2, "alice is paid what her range earned (0)");
        assertApproxEqAbs(f1, h1 - h1 * CLAIM_BPS / 10_000, 2, "alice is paid what her range earned (1)");
        assertGt(f0 + f1, 0, "alice is paid");
        LpOut memory o;
        _exit(alice, A_LO, A_HI, o);
        assertEq(o.receipts, LA, "alice exits in full");
    }

    struct Probe {
        int24 lo;
        int24 hi;
        uint128 lh;
        uint256 h0;
        uint256 h1;
        uint256 p0;
        uint256 p1;
    }

    struct OutsidePos {
        int24 lo;
        int24 hi;
        uint128 l;
        bytes32 salt;
    }

    /// @notice Between swaps, outside adds and removes leave every ledger range's owed fees unchanged, a donation
    ///         raises them by their pro-rata share, and a swap pays them what an outside LP on the same range earns
    ///         per unit of liquidity.
    /// forge-config: default.fuzz.runs = 128
    function testFuzz_outsideAddRemoveDonateBetweenSwaps_ledgerOwedMovesOnlyByItsShare(uint256 seed) public {
        _deposit(alice, A_LO, A_HI, LA);
        _deposit(carol, B_LO, B_HI, LC);
        // probe positions (salt 0) on the ledger's exact ranges
        _addDirect(key, A_LO, A_HI, 1e22);
        _addDirect(key, B_LO, B_HI, 3e22);
        Probe[2] memory pr;
        pr[0] = Probe(A_LO, A_HI, LA, 0, 0, 0, 0);
        pr[1] = Probe(B_LO, B_HI, LC, 0, 0, 0, 0);
        OutsidePos[] memory pos = new OutsidePos[](16);
        uint256 n;
        for (uint256 s; s < 16; s++) {
            uint256 x = uint256(keccak256(abi.encode(seed, s)));
            _snapProbes(pr);
            uint256 a = x % 4;
            if (a == 0) {
                _rollClock((x >> 8) % 3);
                _swapTo(INIT_TICK + int24(int256((x >> 16) % 501)) - 250);
                _checkProbes(pr, 1, 0, 0);
            } else if (a == 1 && n < pos.length) {
                int24 lo = INIT_TICK + (int24(int256((x >> 8) % 81)) - 40) * SPACING;
                int24 hi = lo + int24(int256(1 + (x >> 16) % 40)) * SPACING;
                uint128 l = uint128(1e20 + (x >> 32) % 1e24);
                pos[n] = OutsidePos(lo, hi, l, bytes32(n + 1));
                liq.modify(key, lo, hi, int256(uint256(l)), pos[n].salt);
                n++;
                _checkProbes(pr, 0, 0, 0);
            } else if (a == 2 && n > 0 && pos[(x >> 8) % n].l != 0) {
                OutsidePos memory p = pos[(x >> 8) % n];
                uint128 cut = uint128(1 + (x >> 16) % p.l);
                liq.modify(key, p.lo, p.hi, -int256(uint256(cut)), p.salt);
                p.l -= cut;
                _checkProbes(pr, 0, 0, 0);
            } else if (a == 3 && pm.getLiquidity(id) != 0) {
                uint256 d0 = (x >> 8) % 1e20;
                uint256 d1 = (x >> 80) % 1e20;
                donor.donate(key, d0, d1, "");
                _checkProbes(pr, 2, d0, d1);
            }
        }
        _snapProbes(pr);
        (uint256 f0, uint256 f1) = _claim(alice, A_LO, A_HI);
        assertLe(f0, pr[0].h0, "alice: no more than her range earned (0)");
        assertLe(f1, pr[0].h1, "alice: no more than her range earned (1)");
        assertLe(pr[0].h0 - f0, 2 + pr[0].h0 / 10, "alice: paid her range's fees less the claim fee (0)");
        assertLe(pr[0].h1 - f1, 2 + pr[0].h1 / 10, "alice: paid her range's fees less the claim fee (1)");
    }

    function _snapProbes(Probe[2] memory pr) internal view {
        for (uint256 i; i < 2; i++) {
            (pr[i].h0, pr[i].h1) = _pending(lite, pr[i].lo, pr[i].hi, 0);
            (pr[i].p0, pr[i].p1) = _pending(address(liq), pr[i].lo, pr[i].hi, 0);
        }
    }

    /// @param kind 0: outside add/remove (no change); 1: swap (pro rata with the probe); 2: donation of (d0, d1).
    function _checkProbes(Probe[2] memory pr, uint256 kind, uint256 d0, uint256 d1) internal view {
        for (uint256 i; i < 2; i++) {
            Probe memory q = pr[i];
            (uint256 h0, uint256 h1) = _pending(lite, q.lo, q.hi, 0);
            (h0, h1) = (h0 - q.h0, h1 - q.h1);
            if (kind == 0) {
                assertEq(h0, 0, "an outside add or remove moved ledger fees (0)");
                assertEq(h1, 0, "an outside add or remove moved ledger fees (1)");
            } else if (kind == 1) {
                (uint256 p0, uint256 p1) = _pending(address(liq), q.lo, q.hi, 0);
                (uint128 lp,,) = pm.getPositionInfo(id, address(liq), q.lo, q.hi, 0);
                _assertProRata(h0, q.lh, p0 - q.p0, lp, "swap fees: ledger vs outside on the range (0)");
                _assertProRata(h1, q.lh, p1 - q.p1, lp, "swap fees: ledger vs outside on the range (1)");
            } else {
                _assertDonationShare(q, h0, d0, "currency0");
                _assertDonationShare(q, h1, d1, "currency1");
            }
        }
    }

    /// @dev A donation of `d` raised the range's ledger fees by `dh`: its share of the in-range liquidity, or 0.
    function _assertDonationShare(Probe memory q, uint256 dh, uint256 d, string memory what) internal view {
        (, int24 tick,,) = pm.getSlot0(id);
        uint256 e = q.lo <= tick && tick < q.hi ? FullMath.mulDiv(d, q.lh, pm.getLiquidity(id)) : 0;
        assertLe(dh, e + 1, string.concat("donation above the ledger's share: ", what));
        assertGe(dh + 2, e, string.concat("donation below the ledger's share: ", what));
    }

    function test_hookPauseStopsLedgerOnly_outsideLpsStillAddAndRemove() public {
        _deposit(alice, A_LO, A_HI, LA);
        _addDirect(key, A_LO, A_HI, LX_A);
        _rollClock(1);
        _swapTo(INIT_TICK - 50);
        uint256 rid = _ledger().rangeId(id, A_LO, A_HI);
        for (uint256 mode; mode < 2; mode++) {
            uint256 snap = vm.snapshotState();
            if (mode == 0) _ledger().pause(1 days);
            else _ledger().pausePool(key, 1 days);
            assertTrue(_ledger().pausedFor(id), "paused");

            vm.startPrank(alice);
            vm.expectRevert(FablesLedgerV2.LedgerPaused.selector);
            _ledger().deposit(key, A_LO, A_HI, 1e18, type(uint128).max, type(uint128).max, block.timestamp);
            vm.expectRevert(FablesLedgerV2.LedgerPaused.selector);
            _ledger().claimFees(key, A_LO, A_HI, alice, 10_000);
            vm.expectRevert(FablesLedgerV2.LedgerPaused.selector);
            _ledger().transfer(bob, rid, 1);
            vm.expectRevert(FablesLedgerV2.LedgerPaused.selector);
            _ledger().stake(key, A_LO, A_HI, 1, 0);
            _ledger().withdraw(key, A_LO, A_HI, LA / 2, alice, 0, 0, block.timestamp);
            vm.stopPrank();

            _addDirect(key, A_LO, A_HI, 1e21);
            addLiquidityViaRouter(key, X_LO, X_HI, 1e21, bytes32(uint256(9)));
            _rollClock(1);
            assertGt(_swapTo(INIT_TICK + 60), 0, "swaps keep paying the stable fee");
            donor.donate(key, 1e15, 1e15, "");
            _removeDirect(key, A_LO, A_HI, LX_A + 1e21);
            addLiquidityViaRouter(key, X_LO, X_HI, -1e21, bytes32(uint256(9)));
            (uint128 l,,) = pm.getPositionInfo(id, address(liq), A_LO, A_HI, 0);
            assertEq(l, 0, "the outside LP left during the pause");
            assertEq(pm.getLiquidity(id), LA - LA / 2, "only the ledger's liquidity is left");
            vm.revertToState(snap);
        }
    }
}
