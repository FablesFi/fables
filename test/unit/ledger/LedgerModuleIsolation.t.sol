// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IERC20Minimal} from "v4-core/src/interfaces/external/IERC20Minimal.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";

import {FablesLedgerV2} from "../../../src/base/FablesLedgerV2.sol";
import {FablesFeeEngine} from "../../../src/base/FablesFeeEngine.sol";
import {MockDistributor} from "../../utils/mocks/MockDistributor.sol";
import {MockBallotGate} from "../../utils/mocks/MockBallotGate.sol";
import {LedgerFixture} from "../../utils/LedgerFixture.sol";

/// @notice No ledger entry point reads or writes the fee engine's module storage, and withdraw gas does not depend on
///         it.
abstract contract LedgerModuleIsolationBase is LedgerFixture {
    using PoolIdLibrary for PoolKey;

    uint256 constant MAXFEE_SLOT = 1;
    uint256 constant WORD_SLOT = 2;
    uint256 constant CF_SLOT = 3;
    uint256 constant ENTRY_SLOT = 4;
    uint256 constant CATEGORIES_SLOT = 5;
    uint256 constant META_SLOT = 6;

    FablesLedgerV2 hook;
    FablesFeeEngine engine;
    address hookAddr;
    PoolId poolId;
    uint256 rid;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();
        AccessManager authority = new AccessManager(address(this));
        hookAddr = _deployBuild(0x4812, address(authority));
        hook = FablesLedgerV2(hookAddr);
        engine = FablesFeeEngine(hookAddr);
        hook.setDistributor(new Currency[](0), address(new MockDistributor(makeAddr("ff"))));
        hook.setBallotGate(address(new MockBallotGate()));

        key = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(hookAddr));
        _configureFlat(hookAddr, key, 3000, 0, 50_000);
        poolId = key.toId();
        rid = hook.rangeId(poolId, -120, 120);
        _initPool(key, SQRT_PRICE_1_1);
        hook.setClaimFee(key, new Currency[](0), 500, makeAddr("sink"));

        address[2] memory who = [alice, bob];
        for (uint256 i = 0; i < 2; i++) {
            assertTrue(IERC20Minimal(Currency.unwrap(currency0)).transfer(who[i], 1e21));
            assertTrue(IERC20Minimal(Currency.unwrap(currency1)).transfer(who[i], 1e21));
            vm.startPrank(who[i]);
            IERC20Minimal(Currency.unwrap(currency0)).approve(hookAddr, type(uint256).max);
            IERC20Minimal(Currency.unwrap(currency1)).approve(hookAddr, type(uint256).max);
            vm.stopPrank();
        }
        vm.prank(alice);
        hook.deposit(key, -120, 120, 1e18, type(uint128).max, type(uint128).max, block.timestamp);
        vm.prank(bob);
        hook.deposit(key, -120, 120, 1e18, type(uint128).max, type(uint128).max, block.timestamp);
        vm.prank(bob);
        hook.stake(key, -120, 120, 5e17, 0);
        swap(key, true, -1e15, ZERO_BYTES);
        swap(key, false, -1e15, ZERO_BYTES);
    }

    function _mapSlot(bytes32 k, uint256 slot) internal pure returns (bytes32) {
        return keccak256(abi.encode(k, slot));
    }

    function _entrySlot(PoolId id, address account) internal pure returns (bytes32) {
        return keccak256(abi.encode(account, _mapSlot(PoolId.unwrap(id), ENTRY_SLOT)));
    }

    function _forbidden() internal view returns (bytes32[] memory f) {
        f = new bytes32[](6);
        f[0] = _mapSlot(PoolId.unwrap(poolId), WORD_SLOT);
        f[1] = _mapSlot(PoolId.unwrap(poolId), CF_SLOT);
        f[2] = _entrySlot(poolId, alice);
        f[3] = _entrySlot(poolId, bob);
        f[4] = _mapSlot(bytes32(uint256(CAT)), CATEGORIES_SLOT);
        f[5] = _mapSlot(PoolId.unwrap(poolId), META_SLOT);
    }

    function _contains(bytes32[] memory xs, bytes32 x) internal pure returns (bool) {
        for (uint256 i = 0; i < xs.length; i++) {
            if (xs[i] == x) return true;
        }
        return false;
    }

    function _assertNoModuleAccess(string memory door, bool expectsMarker) internal view {
        (bytes32[] memory reads, bytes32[] memory writes) = vm.accesses(hookAddr);
        bytes32[] memory f = _forbidden();
        for (uint256 i = 0; i < f.length; i++) {
            assertFalse(_contains(reads, f[i]), string.concat(door, ": read engine module slot ", vm.toString(i)));
            assertFalse(_contains(writes, f[i]), string.concat(door, ": wrote engine module slot ", vm.toString(i)));
        }
        if (expectsMarker) {
            assertTrue(
                _contains(reads, _mapSlot(PoolId.unwrap(poolId), MAXFEE_SLOT)), string.concat(door, ": no reads")
            );
        }
    }

    function _armModules() internal {
        PoolId[] memory ids = new PoolId[](1);
        ids[0] = poolId;
        engine.setDiscount(ids, alice, 1000, 0, 3, uint40(block.timestamp + 1 days));
        engine.setDiscount(ids, bob, 500, 0, 3, uint40(block.timestamp + 1 days));
        engine.configureCF(poolId, 0, 128, 1000, 0, 60, 10);
        engine.setCFActive(poolId, true);
    }

    function test_theForbiddenSlotsAreTheEnginesRealSlots() public {
        _armModules();
        bytes32[] memory f = _forbidden();
        assertTrue(vm.load(hookAddr, f[0]) != bytes32(0), "pool word slot");
        assertTrue(vm.load(hookAddr, f[4]) != bytes32(0), "category slot");
        assertTrue(vm.load(hookAddr, f[5]) != bytes32(0), "meta slot");
        assertTrue(vm.load(hookAddr, f[1]) != bytes32(0), "CF slot");
        assertTrue(vm.load(hookAddr, f[2]) != bytes32(0), "alice's entry slot");
        assertTrue(vm.load(hookAddr, f[3]) != bytes32(0), "bob's entry slot");
    }

    function test_ledgerDoorsReadNoEngineModuleState() public {
        _armModules();
        swap(key, true, -1e15, ZERO_BYTES);

        vm.record();
        vm.prank(alice);
        hook.deposit(key, -120, 120, 1e17, type(uint128).max, type(uint128).max, block.timestamp);
        _assertNoModuleAccess("deposit", true);

        vm.record();
        vm.prank(alice);
        hook.stake(key, -120, 120, 1e17, 0);
        _assertNoModuleAccess("stake", true);

        vm.record();
        vm.prank(alice);
        hook.unstake(key, -120, 120, 1e17);
        _assertNoModuleAccess("unstake", true);

        vm.record();
        vm.prank(alice);
        hook.transfer(bob, rid, 1e16);
        _assertNoModuleAccess("transfer", false);

        vm.record();
        vm.prank(alice);
        hook.claimFees(key, -120, 120, alice, 10_000);
        _assertNoModuleAccess("claimFees", true);

        vm.record();
        vm.prank(alice);
        hook.withdraw(key, -120, 120, 1e17, alice, 0, 0, block.timestamp);
        _assertNoModuleAccess("withdraw", true);

        swap(key, false, -1e15, ZERO_BYTES);
        vm.record();
        vm.prank(alice);
        hook.withdrawAndClaim(key, -120, 120, 1e17, alice, 0, 0, block.timestamp, 10_000);
        _assertNoModuleAccess("withdrawAndClaim", true);

        uint256[] memory ids = new uint256[](1);
        ids[0] = rid;
        vm.record();
        hook.syncRanges(1, ids);
        _assertNoModuleAccess("syncRanges", false);

        vm.record();
        hook.sweepDistributor(currency0);
        _assertNoModuleAccess("sweepDistributor", false);

        vm.record();
        hook.sweepClaimFee(currency0);
        _assertNoModuleAccess("sweepClaimFee", false);

        vm.record();
        hook.setClaimFee(key, new Currency[](0), 700, makeAddr("sink"));
        _assertNoModuleAccess("setClaimFee", true);
    }
}

contract LedgerModuleIsolationTest is LedgerModuleIsolationBase {
    function test_withdrawGasIsIdenticalWithModulesOnAndOff() public {
        uint256 snap = vm.snapshotState();
        uint256 off = _measureWithdraw();
        vm.revertToState(snap);

        _armModules();
        uint256 on = _measureWithdraw();
        assertGt(off, 0, "no gas measured");
        assertEq(on, off, "withdraw gas moved with the CF / discount state");
    }

    function _measureWithdraw() internal returns (uint256 used) {
        vm.prank(alice);
        hook.deposit(key, -120, 120, 1e16, type(uint128).max, type(uint128).max, block.timestamp);
        vm.prank(alice);
        uint256 g = gasleft();
        hook.withdraw(key, -120, 120, 5e17, alice, 0, 0, block.timestamp);
        used = g - gasleft();
    }
}
