// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {IERC20Minimal} from "v4-core/src/interfaces/external/IERC20Minimal.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";

import {FablesLedgerV2} from "../../../src/base/FablesLedgerV2.sol";
import {FablesFeeEngine} from "../../../src/base/FablesFeeEngine.sol";
import {FablesHookCore} from "../../../src/base/FablesHookCore.sol";
import {FablesNativeETHV2} from "../../../src/base/FablesNativeETHV2.sol";
import {ClaimFeeChange} from "../../../src/base/LedgerTypesV2.sol";
import {LedgerLibV2} from "../../../src/libraries/LedgerLibV2.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "v4-core/src/libraries/SqrtPriceMath.sol";
import {MockDistributor} from "../../utils/mocks/MockDistributor.sol";
import {MockWETH9} from "../../utils/mocks/MockWETH9.sol";

/// @notice Ballot gate whose every probe can be broken.
contract KnobGate {
    bool public revertBallot;
    bool public revertEarning;
    bool public revertWeight;
    bool public revertVe;
    bool public allow = true;
    bool public earning = true;
    uint256 public weight = 1e18;
    address public veAddr;

    function set(bool b, bool e, bool w, bool v) external {
        (revertBallot, revertEarning, revertWeight, revertVe) = (b, e, w, v);
    }

    function setState(bool allow_, bool earning_, uint256 weight_) external {
        (allow, earning, weight) = (allow_, earning_, weight_);
    }

    function setVe(address v) external {
        veAddr = v;
    }

    function ballotBacks(address, uint256, PoolId) external view returns (bool) {
        require(!revertBallot, "ballot");
        return allow;
    }

    function isGaugeEarning(PoolId) external view returns (bool) {
        require(!revertEarning, "earning");
        return earning;
    }

    function gaugeWeightNow(PoolId) external view returns (uint256) {
        require(!revertWeight, "weight");
        return weight;
    }

    function ve() external view returns (address) {
        require(!revertVe, "ve");
        return veAddr;
    }
}

/// @notice Escrow stub for `KnobGate`.
contract KnobEscrow {
    uint8 public mode;
    address public v;

    function setVoter(address voter_, uint8 mode_) external {
        (v, mode) = (voter_, mode_);
    }

    fallback(bytes calldata) external returns (bytes memory) {
        if (mode == 1) revert("escrow");
        if (mode == 2) return hex"01";
        return abi.encode(v);
    }
}

/// @notice Receiver that rejects ETH.
contract RejectsETH {
    function depositInto(FablesLedgerV2 hook, PoolKey calldata key, uint128 liq) external payable {
        hook.deposit{value: msg.value}(key, -600, 600, liq, uint128(msg.value), type(uint128).max, block.timestamp);
    }

    receive() external payable {
        revert("no ETH");
    }
}

/// @notice FablesLedgerV2 refusal branches: claim-fee and sink validation, gate probes, payout sentinels, deadlines,
///         native refunds, staking and transfer guards, pause bounds and sweeps.
contract LedgerEdgesTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;

    uint8 internal constant CAT = 1;
    FablesLedgerV2 internal hook;
    address internal hookAddr;
    MockWETH9 internal weth;
    KnobGate internal gate;
    KnobEscrow internal escrow;
    PoolKey internal nkey;
    PoolId internal id;
    uint256 internal rid;
    address internal alice = makeAddr("lg.alice");
    address internal sink = makeAddr("lg.sink");
    address internal ffSink = makeAddr("lg.ffSink");
    MockDistributor internal dist;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();
        AccessManager am = new AccessManager(address(this));
        weth = new MockWETH9();
        hookAddr = address(uint160(0x4C47 << 144) | uint160(0x2080));
        deployCodeTo("FablesHookETH.sol:FablesHookETH", abi.encode(manager, address(am), address(weth)), hookAddr);
        hook = FablesLedgerV2(payable(hookAddr));
        FablesFeeEngine(hookAddr).setCategory(CAT, 0, 100_000, 100_000, "ANY");
        key = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(hookAddr));
        nkey = PoolKey(CurrencyLibrary.ADDRESS_ZERO, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(hookAddr));
        FablesFeeEngine(hookAddr).configurePool(key, CAT, 3000, 3000, 0, 50_000);
        FablesFeeEngine(hookAddr).configurePool(nkey, CAT, 3000, 3000, 0, 50_000);
        FablesFeeEngine(hookAddr).initializePool(key, SQRT_PRICE_1_1);
        FablesFeeEngine(hookAddr).initializePool(nkey, SQRT_PRICE_1_1);
        id = key.toId();
        rid = hook.rangeId(id, -600, 600);

        gate = new KnobGate();
        escrow = new KnobEscrow();
        escrow.setVoter(address(gate), 0);
        gate.setVe(address(escrow));
        dist = new MockDistributor(makeAddr("lg.ff"));

        IERC20Minimal(Currency.unwrap(currency0)).transfer(alice, 1e24);
        IERC20Minimal(Currency.unwrap(currency1)).transfer(alice, 1e24);
        vm.deal(alice, 1e24);
        vm.startPrank(alice);
        IERC20Minimal(Currency.unwrap(currency0)).approve(hookAddr, type(uint256).max);
        IERC20Minimal(Currency.unwrap(currency1)).approve(hookAddr, type(uint256).max);
        vm.stopPrank();
        IERC20Minimal(Currency.unwrap(currency1)).approve(hookAddr, type(uint256).max);
    }

    function _deposit(address who, uint128 liq) internal {
        vm.prank(who);
        hook.deposit(key, -600, 600, liq, type(uint128).max, type(uint128).max, block.timestamp);
    }

    function _fees() internal {
        swap(key, true, -1e16, ZERO_BYTES);
        swap(key, false, -1e16, ZERO_BYTES);
    }

    function test_setClaimFee_validation() public {
        Currency[] memory none = new Currency[](0);
        vm.expectRevert(FablesLedgerV2.InvalidClaimFee.selector);
        hook.setClaimFee(key, none, 2_001, sink);
        vm.expectRevert(FablesLedgerV2.InvalidClaimFee.selector);
        hook.setClaimFee(key, none, 100, address(0));
        vm.expectRevert(FablesLedgerV2.InvalidClaimFee.selector);
        hook.setClaimFee(key, none, 100, hookAddr);
        vm.expectRevert(FablesLedgerV2.InvalidSink.selector);
        hook.setClaimFee(key, none, 100, address(manager));
        vm.expectRevert(FablesLedgerV2.InvalidClaimFee.selector);
        hook.setClaimFeeBps(key, 100);

        PoolKey memory bad = key;
        bad.tickSpacing = 10;
        vm.expectRevert(FablesHookCore.PoolNotConfigured.selector);
        hook.setClaimFee(bad, none, 100, sink);

        hook.setDistributor(none, address(dist));
        vm.expectRevert(FablesLedgerV2.InvalidClaimFee.selector);
        hook.setClaimFee(key, none, 100, address(dist));
        hook.setFFFeeSink(none, ffSink);
        vm.expectRevert(FablesLedgerV2.InvalidClaimFee.selector);
        hook.setClaimFee(key, none, 100, ffSink);

        hook.setClaimFee(key, none, 0, address(0));
        hook.setClaimFee(key, none, 300, sink);
        vm.expectRevert(FablesLedgerV2.InvalidClaimFee.selector);
        hook.setClaimFee(key, none, 0, address(0));
        hook.setClaimFeeBps(key, 100);
        assertEq(hook.claimFeeBps(id), 100);
        assertEq(hook.claimFeeAllTimeMin(id), 0);
        assertEq(hook.claimFeeHistoryLength(id), 3);
        ClaimFeeChange memory c = hook.claimFeeChangeAt(id, 1);
        assertEq(c.bps, 300);
    }

    function test_setFFFeeSink_lattice() public {
        Currency[] memory none = new Currency[](0);
        hook.setDistributor(none, address(dist));
        hook.setClaimFee(key, none, 100, sink);
        vm.expectRevert(FablesLedgerV2.InvalidSink.selector);
        hook.setFFFeeSink(none, address(dist));
        vm.expectRevert(FablesLedgerV2.InvalidSink.selector);
        hook.setFFFeeSink(none, sink);
        vm.expectRevert(FablesLedgerV2.InvalidSink.selector);
        hook.setFFFeeSink(none, hookAddr);
        vm.expectRevert(FablesLedgerV2.InvalidSink.selector);
        hook.setFFFeeSink(none, address(manager));
        hook.setFFFeeSink(none, ffSink);
        hook.setFFFeeSink(none, address(0));
        assertEq(hook.ffFeeSink(), address(0));
    }

    function test_setDistributor_probes() public {
        Currency[] memory none = new Currency[](0);
        vm.expectRevert(FablesLedgerV2.DistributorNotFablesAware.selector);
        hook.setDistributor(none, makeAddr("eoa"));
        vm.expectRevert(FablesLedgerV2.DistributorNotFablesAware.selector);
        hook.setDistributor(none, address(gate));
        MockDistributor zeroFF = new MockDistributor(address(0));
        vm.expectRevert(FablesLedgerV2.DistributorNotFablesAware.selector);
        hook.setDistributor(none, address(zeroFF));
        vm.expectRevert(FablesLedgerV2.InvalidSink.selector);
        hook.setDistributor(none, address(manager));
        vm.expectRevert(FablesLedgerV2.InvalidSink.selector);
        hook.setDistributor(none, hookAddr);
        hook.setClaimFee(key, none, 100, address(dist));
        vm.expectRevert(FablesLedgerV2.InvalidSink.selector);
        hook.setDistributor(none, address(dist));
        MockDistributor d2 = new MockDistributor(makeAddr("ff2"));
        hook.setFFFeeSink(none, address(d2));
        vm.expectRevert(FablesLedgerV2.InvalidSink.selector);
        hook.setDistributor(none, address(d2));
        hook.setDistributor(none, address(0));
        assertEq(hook.distributorFF(), address(0));
    }

    function test_setBallotGate_probes() public {
        vm.expectRevert(FablesLedgerV2.InvalidBallotGate.selector);
        hook.setBallotGate(makeAddr("eoa"));
        bool[4] memory f;
        for (uint256 i; i < 4; i++) {
            f = [false, false, false, false];
            f[i] = true;
            gate.set(f[0], f[1], f[2], f[3]);
            vm.expectRevert(FablesLedgerV2.InvalidBallotGate.selector);
            hook.setBallotGate(address(gate));
        }
        gate.set(false, false, false, false);
        gate.setVe(address(0));
        vm.expectRevert(FablesLedgerV2.InvalidBallotGate.selector);
        hook.setBallotGate(address(gate));
        gate.setVe(makeAddr("codeless"));
        vm.expectRevert(FablesLedgerV2.InvalidBallotGate.selector);
        hook.setBallotGate(address(gate));
        gate.setVe(address(escrow));
        for (uint8 m = 1; m <= 2; m++) {
            escrow.setVoter(address(gate), m);
            vm.expectRevert(FablesLedgerV2.InvalidBallotGate.selector);
            hook.setBallotGate(address(gate));
        }
        escrow.setVoter(makeAddr("other voter"), 0);
        vm.expectRevert(FablesLedgerV2.InvalidBallotGate.selector);
        hook.setBallotGate(address(gate));
        escrow.setVoter(address(gate), 0);
        hook.setBallotGate(address(gate));
        hook.setBallotGate(address(0));
        assertEq(hook.ballotGate(), address(0));
    }

    function test_stake_and_sync_gates() public {
        _deposit(alice, 1e18);
        vm.prank(alice);
        vm.expectRevert(FablesLedgerV2.ZeroShares.selector);
        hook.stake(key, -600, 600, 0, 0);
        vm.prank(alice);
        vm.expectRevert(FablesLedgerV2.GaugeNotEarning.selector);
        hook.stake(key, -600, 600, 1, 0);

        uint256[] memory ids = new uint256[](1);
        ids[0] = rid;
        vm.expectRevert(FablesLedgerV2.BallotGateUnset.selector);
        hook.syncRanges(1, ids);

        hook.setBallotGate(address(gate));
        gate.setState(true, false, 1e18);
        vm.prank(alice);
        vm.expectRevert(FablesLedgerV2.GaugeNotEarning.selector);
        hook.stake(key, -600, 600, 1, 0);
        gate.setState(true, true, 1e18);
        vm.prank(alice);
        vm.expectRevert(FablesLedgerV2.GaugeBelowMinWeight.selector);
        hook.stake(key, -600, 600, 1, 2e18);
        vm.prank(alice);
        vm.expectRevert(FablesLedgerV2.InsufficientUnstakedShares.selector);
        hook.stake(key, -600, 600, 1e18 + 1, 0);

        hook.syncRanges(1, ids);
        vm.prank(alice);
        hook.stake(key, -600, 600, 5e17, 1e18);
        _fees();
        gate.setState(false, true, 1e18);
        vm.expectRevert(FablesLedgerV2.NotAVoterOfThisPool.selector);
        hook.syncRanges(1, ids);
        gate.setState(true, true, 1e18);
        hook.syncRanges(1, ids);
        assertGt(hook.distributorOwed(currency0) + hook.distributorOwed(currency1), 0, "staked fees banked");

        hook.setClaimFee(key, new Currency[](0), 500, sink);
        assertEq(hook.effectiveClaimFee(rid), 0, "backlog opened before any rate: free");
        hook.syncRanges(1, ids);
        assertEq(hook.effectiveClaimFee(rid), 500);
        vm.prank(alice);
        hook.stake(key, -600, 600, 5e17, 0);
        assertEq(hook.effectiveClaimFee(rid), 0, "fully staked range: no claim fee");

        vm.prank(alice);
        vm.expectRevert(FablesLedgerV2.ZeroShares.selector);
        hook.unstake(key, -600, 600, 0);
        vm.prank(alice);
        vm.expectRevert();
        hook.unstake(key, -600, 600, 1e18 + 1);
        vm.prank(alice);
        hook.unstake(key, -600, 600, 1e18);
    }

    function test_withdraw_and_claim_guards() public {
        _deposit(alice, 1e18);
        _fees();
        vm.startPrank(alice);
        vm.expectRevert(FablesLedgerV2.ZeroLiquidity.selector);
        hook.withdraw(key, -600, 600, 0, alice, 0, 0, block.timestamp);
        vm.expectRevert(FablesLedgerV2.ZeroAddress.selector);
        hook.withdraw(key, -600, 600, 1, address(0), 0, 0, block.timestamp);
        vm.expectRevert(FablesLedgerV2.InvalidSink.selector);
        hook.withdraw(key, -600, 600, 1, hookAddr, 0, 0, block.timestamp);
        vm.expectRevert(FablesLedgerV2.InvalidSink.selector);
        hook.withdraw(key, -600, 600, 1, address(manager), 0, 0, block.timestamp);
        vm.expectRevert(FablesLedgerV2.DeadlineExpired.selector);
        hook.withdraw(key, -600, 600, 1, alice, 0, 0, block.timestamp - 1);
        vm.expectRevert(FablesLedgerV2.ZeroAddress.selector);
        hook.claimFees(key, -600, 600, address(0), 0);
        vm.expectRevert(FablesLedgerV2.InvalidSink.selector);
        hook.claimFees(key, -600, 600, address(manager), 0);
        vm.stopPrank();

        vm.prank(makeAddr("nobody"));
        vm.expectRevert(FablesLedgerV2.NothingToClaim.selector);
        hook.claimFees(key, -600, 600, alice, 0);

        hook.setClaimFee(key, new Currency[](0), 500, sink);
        _fees();
        vm.prank(alice);
        hook.claimFees(key, -600, 600, alice, 2_000);
        _fees();
        vm.startPrank(alice);
        vm.expectRevert(FablesLedgerV2.ClaimFeeAboveMax.selector);
        hook.claimFees(key, -600, 600, alice, 499);
        vm.expectRevert(FablesLedgerV2.ClaimFeeAboveMax.selector);
        hook.withdrawAndClaim(key, -600, 600, 1, alice, 0, 0, block.timestamp, 499);
        hook.claimFees(key, -600, 600, alice, 2_000);
        hook.withdrawAndClaim(key, -600, 600, 1e17, alice, 0, 0, block.timestamp, 2_000);
        vm.stopPrank();
    }

    function test_principalBounds() public {
        (uint256 e0,) = _quote(1e18);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(LedgerLibV2.PrincipalAboveMax.selector, e0, e0 - 1));
        hook.deposit(key, -600, 600, 1e18, uint128(e0 - 1), type(uint128).max, block.timestamp);
        _deposit(alice, 1e18);
        (, uint256 d0) = _quote(1e18);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(LedgerLibV2.PrincipalBelowMin.selector, d0, d0 + 1));
        hook.withdraw(key, -600, 600, 1e18, alice, uint128(d0 + 1), 0, block.timestamp);
    }

    function _quote(uint128 liq) internal pure returns (uint256 up, uint256 down) {
        uint160 sqrtP = 79_228_162_514_264_337_593_543_950_336;
        uint160 sqrtHi = TickMath.getSqrtPriceAtTick(600);
        up = SqrtPriceMath.getAmount0Delta(sqrtP, sqrtHi, liq, true);
        down = SqrtPriceMath.getAmount0Delta(sqrtP, sqrtHi, liq, false);
    }

    function test_oneSidedRange_zeroLeg() public {
        uint256 b1 = IERC20Minimal(Currency.unwrap(currency1)).balanceOf(alice);
        vm.prank(alice);
        hook.deposit(key, 600, 1200, 1e18, type(uint128).max, type(uint128).max, block.timestamp);
        assertEq(IERC20Minimal(Currency.unwrap(currency1)).balanceOf(alice), b1, "no currency1 in");
        vm.prank(alice);
        hook.withdraw(key, 600, 1200, 1e18, alice, 0, 0, block.timestamp);
        assertEq(IERC20Minimal(Currency.unwrap(currency1)).balanceOf(alice), b1, "no currency1 out");
    }

    function test_nativeDeposit_exactValue_noRefund() public {
        (uint256 up,) = _quote(1e18);
        uint256 before = alice.balance;
        vm.prank(alice);
        hook.deposit{value: up}(nkey, -600, 600, 1e18, uint128(up), type(uint128).max, block.timestamp);
        assertEq(before - alice.balance, up, "exact payment");
        assertEq(hookAddr.balance, 0);
    }

    function test_deposit_guards() public {
        vm.startPrank(alice);
        vm.expectRevert(FablesLedgerV2.ZeroLiquidity.selector);
        hook.deposit(key, -600, 600, 0, 1, 1, block.timestamp);
        vm.expectRevert(FablesLedgerV2.DeadlineExpired.selector);
        hook.deposit(key, -600, 600, 1, 1, 1, block.timestamp - 1);
        vm.expectRevert(FablesLedgerV2.InvalidMsgValue.selector);
        hook.deposit{value: 1}(key, -600, 600, 1e9, type(uint128).max, type(uint128).max, block.timestamp);
        vm.expectRevert(FablesLedgerV2.InvalidMsgValue.selector);
        hook.deposit{value: 1}(nkey, -600, 600, 1e9, 2, type(uint128).max, block.timestamp);
        vm.stopPrank();
    }

    function test_native_refundFailed_and_ethGate() public {
        RejectsETH r = new RejectsETH();
        IERC20Minimal(Currency.unwrap(currency1)).transfer(address(r), 1e21);
        vm.prank(address(r));
        IERC20Minimal(Currency.unwrap(currency1)).approve(hookAddr, type(uint256).max);
        vm.expectRevert(FablesLedgerV2.RefundFailed.selector);
        r.depositInto{value: 1 ether}(hook, nkey, 1e15);

        (bool ok, bytes memory ret) = hookAddr.call{value: 1}("");
        assertFalse(ok);
        assertEq(bytes4(ret), FablesNativeETHV2.UnauthorizedETHSender.selector);
    }

    function test_transfer_guards() public {
        hook.setBallotGate(address(gate));
        _deposit(alice, 1e18);
        address bob = makeAddr("lg.bob");
        vm.startPrank(alice);
        vm.expectRevert(FablesLedgerV2.ZeroShares.selector);
        hook.transfer(bob, rid, 0);
        vm.expectRevert(FablesLedgerV2.ZeroShares.selector);
        hook.transferFrom(alice, bob, rid, 0);
        hook.stake(key, -600, 600, 6e17, 0);
        vm.expectRevert(FablesLedgerV2.InsufficientUnstakedShares.selector);
        hook.transfer(bob, rid, 5e17);
        hook.setOperator(bob, true);
        vm.stopPrank();
        vm.prank(bob);
        vm.expectRevert(FablesLedgerV2.InsufficientUnstakedShares.selector);
        hook.transferFrom(alice, bob, rid, 5e17);
        vm.prank(bob);
        hook.transferFrom(alice, bob, rid, 4e17);
        assertEq(hook.balanceOf(bob, rid), 4e17);
    }

    function test_pause_bounds() public {
        uint256 maxP = hook.MAX_PAUSE();
        vm.expectRevert(FablesLedgerV2.PauseTooLong.selector);
        hook.setPaused(maxP + 1);
        vm.expectRevert(FablesLedgerV2.PauseTooLong.selector);
        hook.pause(0);
        vm.expectRevert(FablesLedgerV2.PauseTooLong.selector);
        hook.pause(maxP + 1);
        vm.expectRevert(FablesLedgerV2.PauseTooLong.selector);
        hook.setPoolPaused(key, maxP + 1);
        vm.expectRevert(FablesLedgerV2.PauseTooLong.selector);
        hook.pausePool(key, 0);
        hook.pausePool(key, 2 days);
        vm.expectRevert(FablesLedgerV2.PauseTooLong.selector);
        hook.pausePool(key, 1 days);
        hook.setPoolPaused(key, 0);
        assertFalse(hook.pausedFor(id));
        hook.setPaused(1 days);
        assertTrue(hook.paused());
    }

    function test_claimFeeWalkCap_fallsBackToAllTimeMin() public {
        Currency[] memory none = new Currency[](0);
        hook.setClaimFee(key, none, 400, sink);
        _deposit(alice, 1e18);
        hook.setClaimFeeBps(key, 50);
        uint256 walk = hook.MAX_CLAIM_FEE_WALK();
        for (uint256 i; i < walk + 2; i++) {
            hook.setClaimFeeBps(key, uint16(300 + i));
        }
        uint64 since = hook.claimFeeSyncIndex(rid);
        assertEq(hook.claimFeeFor(id, since), 50, "walk capped: the all-time minimum");
        assertEq(hook.claimFeeFor(id, uint64(hook.claimFeeHistoryLength(id))), 300 + walk + 1, "fresh window");
        assertEq(hook.claimFeeFor(id, 0), 0, "never synced: free");
    }

    function test_sweeps_noopAndFFRoute() public {
        Currency[] memory none = new Currency[](0);
        hook.setBallotGate(address(gate));
        _deposit(alice, 1e18);
        vm.prank(alice);
        hook.stake(key, -600, 600, 1e18, 0);
        _fees();
        uint256[] memory ids = new uint256[](1);
        ids[0] = rid;
        hook.syncRanges(1, ids);
        uint256 owed0 = hook.distributorOwed(currency0);
        assertGt(owed0, 0);
        hook.sweepDistributor(currency0);
        hook.sweepClaimFee(currency0);
        assertEq(hook.distributorOwed(currency0), owed0);

        MockDistributor d = new MockDistributor(Currency.unwrap(currency0));
        hook.setDistributor(none, address(d));
        hook.sweepDistributor(currency0);
        assertEq(hook.distributorOwed(currency0), owed0);
        Currency[] memory settle = new Currency[](1);
        settle[0] = currency0;
        hook.setFFFeeSink(settle, ffSink);
        uint256 before = IERC20Minimal(Currency.unwrap(currency0)).balanceOf(ffSink);
        hook.sweepDistributor(currency0);
        assertEq(IERC20Minimal(Currency.unwrap(currency0)).balanceOf(ffSink) - before, owed0);
        uint256 owed1 = hook.distributorOwed(currency1);
        Currency[] memory c1s = new Currency[](1);
        c1s[0] = currency1;
        hook.setDistributor(c1s, address(new MockDistributor(makeAddr("ff3"))));
        assertEq(hook.distributorOwed(currency1), 0);
        assertEq(IERC20Minimal(Currency.unwrap(currency1)).balanceOf(address(d)), owed1);
    }

    function test_nativeSweeps_waitThenWrap() public {
        Currency[] memory none = new Currency[](0);
        hook.setBallotGate(address(gate));
        hook.setClaimFee(nkey, none, 1_000, sink);
        vm.prank(alice);
        hook.deposit{value: 10 ether}(nkey, -600, 600, 1e18, 10 ether, type(uint128).max, block.timestamp);
        vm.prank(alice);
        hook.stake(nkey, -600, 600, 5e17, 0);
        swap(nkey, true, -1e16, ZERO_BYTES);
        uint256[] memory ids = new uint256[](1);
        ids[0] = hook.rangeId(nkey.toId(), -600, 600);
        hook.syncRanges(1, ids);
        Currency eth = CurrencyLibrary.ADDRESS_ZERO;
        uint256 dOwed = hook.distributorOwed(eth);
        uint256 cOwed = hook.claimFeeOwed(eth);
        assertGt(dOwed, 0);
        assertGt(cOwed, 0);
        hook.sweepDistributor(eth);
        assertEq(hook.distributorOwed(eth), dOwed);
        hook.sweepClaimFee(eth);
        assertEq(weth.balanceOf(sink), cOwed, "claim fee wrapped");
        hook.sweepClaimFee(eth);
        MockDistributor d = new MockDistributor(makeAddr("ffn"));
        hook.setDistributor(none, address(d));
        hook.sweepDistributor(eth);
        assertEq(weth.balanceOf(address(d)), dOwed, "distributor revenue wrapped");
        hook.sweepDistributor(eth);
        assertEq(hookAddr.balance, 0);
    }

    function test_views_unsetRange() public view {
        (uint256 g0, uint256 g1) = hook.rangeGrowth(12345);
        assertEq(g0 + g1, 0);
        (,,, bool set) = hook.rangeKey(12345);
        assertFalse(set);
        assertFalse(hook.isSettling());
    }
}
