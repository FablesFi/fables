// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IERC20Minimal} from "v4-core/src/interfaces/external/IERC20Minimal.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";

import {FablesLedgerV2} from "../../src/base/FablesLedgerV2.sol";
import {UserPosition} from "../../src/base/LedgerTypesV2.sol";
import {MockDistributor} from "../utils/mocks/MockDistributor.sol";
import {MockBallotGate} from "../utils/mocks/MockBallotGate.sol";
import {LedgerFixture} from "../utils/LedgerFixture.sol";
import {ConservationHandler} from "./LedgerConservationInvariant.t.sol";

/// @notice Random 20-action ledger sequences with per-action neutrality and conservation checks.
abstract contract LedgerSequenceFuzzBase is LedgerFixture {
    using PoolIdLibrary for PoolKey;

    FablesLedgerV2 internal hook;
    ConservationHandler internal handler;
    PoolId internal poolId;
    address[3] internal actors;
    int24[3] internal lo = [int24(-120), -600, -60];
    int24[3] internal hi = [int24(120), 600, 60];

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();
        AccessManager authority = new AccessManager(address(this));
        address hookAddr = _deployBuild(0xC14C, address(authority));
        hook = FablesLedgerV2(payable(hookAddr));
        key = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(hookAddr));
        _configureFlat(hookAddr, key, 3000, 3000, 10_000);
        poolId = key.toId();
        vm.warp(1785859200);
        _initPool(key, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(key, LIQUIDITY_PARAMS, ZERO_BYTES);

        actors = [makeAddr("edge.alice"), makeAddr("edge.bob"), makeAddr("edge.carol")];
        for (uint256 i = 0; i < 4; i++) {
            address who = i < 3 ? actors[i] : address(0x5AA9);
            IERC20Minimal(Currency.unwrap(currency0)).transfer(who, 1e21);
            IERC20Minimal(Currency.unwrap(currency1)).transfer(who, 1e21);
            vm.startPrank(who);
            IERC20Minimal(Currency.unwrap(currency0)).approve(address(hook), type(uint256).max);
            IERC20Minimal(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);
            IERC20Minimal(Currency.unwrap(currency0)).approve(address(swapRouter), type(uint256).max);
            IERC20Minimal(Currency.unwrap(currency1)).approve(address(swapRouter), type(uint256).max);
            vm.stopPrank();
        }
        address distributor = address(new MockDistributor(makeAddr("edge.ff")));
        hook.setDistributor(new Currency[](0), distributor);
        hook.setBallotGate(address(new MockBallotGate()));
        for (uint256 i = 0; i < 3; i++) {
            vm.startPrank(actors[0]);
            hook.deposit(key, lo[i], hi[i], 1e17, type(uint128).max, type(uint128).max, block.timestamp);
            hook.stake(key, lo[i], hi[i], 5e16, 0);
            vm.stopPrank();
        }
        handler = new ConservationHandler(hook, manager, swapRouter, key, actors, distributor);
    }

    function _act(uint256 seed) internal {
        uint256 a = uint256(keccak256(abi.encode(seed, 1)));
        uint256 b = uint256(keccak256(abi.encode(seed, 2)));
        uint256 c = uint256(keccak256(abi.encode(seed, 3)));
        uint256 op = seed % 14;
        if (op == 0) handler.deposit(a, b, uint128(c));
        else if (op == 1) handler.withdraw(a, b, uint128(c), c % 5 == 0);
        else if (op == 2) handler.withdrawAndClaim(a, b, uint128(c), uint16(c >> 128));
        else if (op == 3) handler.withdrawAndClaimPreSynced(a, b, uint128(c));
        else if (op == 4) handler.stake(a, b, uint128(c), c % 3 == 0);
        else if (op == 5) handler.unstake(a, b, uint128(c));
        else if (op == 6) handler.transfer(a, b, c, c >> 8);
        else if (op == 7) handler.claim(a, b);
        else if (op == 8) handler.setClaimFee(a);
        else if (op == 9) handler.sweep(a);
        else if (op == 10) handler.pauseFor(a % 4 == 0 ? a : 0, b % 2 == 0);
        else if (op == 11) handler.warp(a);
        else handler.swapAround(a, uint128(b));
    }

    function _checkStep() internal view {
        assertLe(handler.promisedQ(currency0, true), handler.potQ(currency0), "currency0: promised more than held");
        assertLe(handler.promisedQ(currency1, false), handler.potQ(currency1), "currency1: promised more than held");
        assertGe(handler.slackQ(currency0, true), handler.preSlackQ0(), "currency0: slack fell");
        assertGe(handler.slackQ(currency1, false), handler.preSlackQ1(), "currency1: slack fell");
        assertGe(
            hook.distributorOwed(currency0) + handler.distributorSwept0(), handler.preDistAccrued0(), "voters clawed"
        );
        uint256 exemptId = handler.claimingId();
        address exempt = handler.claimingActor();
        for (uint256 i = 0; i < 3; i++) {
            uint256 id = hook.rangeId(poolId, lo[i], hi[i]);
            for (uint256 j = 0; j < 3; j++) {
                if (id == exemptId && actors[j] == exempt) continue;
                (uint256 e0, uint256 e1) = handler.entitlementOf(id, actors[j]);
                assertGe(e0, handler.preEnt0(id, actors[j]), "currency0: a holder was diluted");
                assertGe(e1, handler.preEnt1(id, actors[j]), "currency1: a holder was diluted");
            }
        }
    }

    function _sequence(uint256[20] memory seeds) internal {
        for (uint256 i; i < 20; ++i) {
            _act(seeds[i]);
            _checkStep();
        }
        _exitAll();
    }

    function test_sequenceDecodingReachesFeesAndExits() public {
        uint8[8] memory ops = [12, 13, 0, 0, 0, 12, 13, 11];
        for (uint256 i; i < ops.length; ++i) {
            _act(uint256(ops[i]) + 14 * (i + 1));
            _checkStep();
        }
        assertEq(handler.depositsLanded(), 3, "deposits land");
        assertEq(handler.swapsLanded(), 4, "swaps land");
        assertGt(handler.potQ(currency0) + handler.potQ(currency1), 0, "fees reached the pot");
        _exitAll();
    }

    function _exitAll() internal {
        vm.warp(block.timestamp + 8 days);
        for (uint256 i = 0; i < 3; i++) {
            uint256 id = hook.rangeId(poolId, lo[i], hi[i]);
            for (uint256 j = 0; j < 3; j++) {
                _exitOne(id, i, actors[j]);
            }
        }
        assertEq(
            handler.promisedQ(currency0, true),
            (hook.distributorOwed(currency0) + hook.claimFeeOwed(currency0)) << 128,
            "currency0: holder entitlement left after a full exit"
        );
        assertLe(handler.promisedQ(currency0, true), handler.potQ(currency0), "pots still covered");
        assertLe(handler.promisedQ(currency1, false), handler.potQ(currency1), "pots still covered");
    }

    function _exitOne(uint256 id, uint256 r, address actor) internal {
        (uint256 owed0, uint256 owed1) = handler.entitlementOf(id, actor);
        uint256 staked = hook.userPosition(id, actor).staked;
        vm.startPrank(actor);
        if (staked != 0) hook.unstake(key, lo[r], hi[r], uint128(staked));
        uint256 bal = hook.balanceOf(actor, id);
        if (bal != 0) hook.withdraw(key, lo[r], hi[r], uint128(bal), actor, 0, 0, block.timestamp);
        uint256 got0 = IERC20Minimal(Currency.unwrap(currency0)).balanceOf(actor);
        uint256 got1 = IERC20Minimal(Currency.unwrap(currency1)).balanceOf(actor);
        UserPosition memory p = hook.userPosition(id, actor);
        if (p.owed0 != 0 || p.owed1 != 0) hook.claimFees(key, lo[r], hi[r], actor, 10_000);
        vm.stopPrank();
        assertGe(IERC20Minimal(Currency.unwrap(currency0)).balanceOf(actor) - got0, owed0, "currency0: exit short");
        assertGe(IERC20Minimal(Currency.unwrap(currency1)).balanceOf(actor) - got1, owed1, "currency1: exit short");
        (uint256 e0, uint256 e1) = handler.entitlementOf(id, actor);
        assertEq(e0 + e1, 0, "fees stranded on an exited position");
    }
}

contract LedgerSequenceFuzzTest is LedgerSequenceFuzzBase {
    /// forge-config: default.fuzz.runs = 64
    /// forge-config: deep.fuzz.runs = 2000
    function testFuzz_randomSequenceConservesAndExitsWhole(uint256[20] memory seeds) public {
        _sequence(seeds);
    }
}
