// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {LedgerLibV2} from "../../src/libraries/LedgerLibV2.sol";
import {RangeState, RangeKey, UserPosition, PoolClaimFee} from "../../src/base/LedgerTypesV2.sol";

/// @notice LedgerLibV2 on its own storage with raw writers for the per-share levels.
contract LedgerLevelsHarness {
    uint256 internal constant ID = 7;
    mapping(uint256 => RangeState) internal _ranges;
    mapping(uint256 => RangeKey) internal _rangeKeys;
    mapping(Currency => uint256) public distributorOwed;
    mapping(Currency => uint256) public claimFeeOwed;
    mapping(uint256 => uint64) internal _syncIndex;
    mapping(PoolId => PoolClaimFee) internal _poolClaimFee;
    mapping(address => UserPosition) internal _positions;
    PoolKey internal _key;

    constructor(PoolKey memory key_) {
        _key = key_;
        _rangeKeys[ID].key = key_;
        _rangeKeys[ID].set = true;
    }

    function setShares(uint128 total, uint128 staked) external {
        _ranges[ID].totalShares = total;
        _ranges[ID].totalStaked = staked;
    }

    function setLevels(uint256 fee0, uint256 fee1, uint256 staked0, uint256 staked1) external {
        RangeState storage r = _ranges[ID];
        (r.accFee0X128, r.accFee1X128, r.accStaked0X128, r.accStaked1X128) = (fee0, fee1, staked0, staked1);
    }

    function setStaked(address owner, uint128 staked) external {
        _positions[owner].staked = staked;
    }

    function credit(uint128 fee0, uint128 fee1) external {
        LedgerLibV2.creditFees(
            _ranges,
            _rangeKeys,
            distributorOwed,
            claimFeeOwed,
            _syncIndex,
            _poolClaimFee,
            IPoolManager(address(0)),
            LedgerLibV2.CreditParams({id: ID, key: _key, fee0: fee0, fee1: fee1, claimFeeRecipient: address(0)}),
            true,
            0,
            0
        );
    }

    function settle(address owner, uint256 balance) external {
        LedgerLibV2.settleUser(_ranges[ID], _positions[owner], balance, owner, ID);
    }

    function range() external view returns (RangeState memory) {
        return _ranges[ID];
    }

    function position(address owner) external view returns (UserPosition memory) {
        return _positions[owner];
    }
}

/// @notice Wrapping per-share levels against an unwrapped 512-bit model, and staked / unstaked fee conservation.
contract LedgerLevelsFuzzTest is Test {
    uint256 internal constant Q128 = 1 << 128;
    uint128 internal constant MAX_OWED = uint128(type(int128).max);

    LedgerLevelsHarness internal h;
    Currency internal c0 = Currency.wrap(address(0xC0));
    Currency internal c1 = Currency.wrap(address(0xC1));

    function setUp() public {
        h = new LedgerLevelsHarness(PoolKey(c0, c1, 0x800000, 60, IHooks(address(0x2080))));
    }

    struct U512 {
        uint256 hi;
        uint256 lo;
    }

    function _add(U512 memory a, uint256 b) internal pure returns (U512 memory r) {
        unchecked {
            r.lo = a.lo + b;
            r.hi = a.hi + (r.lo < a.lo ? 1 : 0);
        }
    }

    function _sub(U512 memory a, U512 memory b) internal pure returns (uint256 lo, uint256 hi) {
        unchecked {
            lo = a.lo - b.lo;
            hi = a.hi - b.hi - (a.lo < b.lo ? 1 : 0);
        }
    }

    function _incs(uint128[6] memory fees, uint256 shares) internal pure returns (uint256[6] memory inc, uint256 sum) {
        for (uint256 i; i < 6; ++i) {
            inc[i] = FullMath.mulDiv(fees[i], Q128, shares);
            sum += inc[i];
        }
    }

    function _boundFees(uint128[6] memory fees) internal pure returns (uint256 sum) {
        for (uint256 i; i < 6; ++i) {
            fees[i] = uint128(bound(fees[i], 0, type(uint96).max));
            sum += fees[i];
        }
    }

    function _park(uint128[6] memory fees, uint256 shares, uint256 offset) internal pure returns (uint256, uint256) {
        (, uint256 sum) = _incs(fees, shares);
        return (type(uint256).max - bound(offset, 0, sum), sum);
    }

    function _creditTracked(
        uint128[6] memory fees0,
        uint128[6] memory fees1,
        uint256 shares,
        uint256 start,
        bool staked
    ) internal returns (uint256 diff) {
        (uint256[6] memory inc, uint256 sum) = _incs(fees0, shares);
        U512 memory model = U512(0, start);
        for (uint256 i; i < 6; ++i) {
            h.credit(fees0[i], fees1[i]);
            model = _add(model, inc[i]);
            RangeState memory r = h.range();
            assertEq(staked ? r.accStaked0X128 : r.accFee0X128, model.lo, "level == model mod 2^256");
        }
        uint256 hi;
        (diff, hi) = _sub(model, U512(0, start));
        assertEq(hi, 0, "window under 2^256");
        assertEq(diff, sum, "unwrapped difference == sum of increments");
    }

    function _capped(uint256 x) internal pure returns (uint256) {
        return x > MAX_OWED ? MAX_OWED : x;
    }

    /// forge-config: default.fuzz.runs = 512
    /// forge-config: deep.fuzz.runs = 20000
    function testFuzz_unstakedLevelWrapMatchesUnwrappedModel(
        uint128 total,
        uint128 bal,
        uint256 offset,
        uint128[6] memory fees0,
        uint128[6] memory fees1
    ) public {
        total = uint128(bound(total, 1, type(uint64).max));
        bal = uint128(bound(bal, 1, total));
        _boundFees(fees0);
        _boundFees(fees1);
        (uint256 start0, uint256 sum0) = _park(fees0, total, offset);
        (uint256 start1, uint256 sum1) = _park(fees1, total, offset);
        h.setShares(total, 0);
        h.setLevels(start0, start1, 0, 0);
        h.settle(address(0xA), 0);

        assertEq(_creditTracked(fees0, fees1, total, start0, false), sum0);
        h.settle(address(0xA), bal);
        UserPosition memory p = h.position(address(0xA));
        assertEq(p.owed0, _capped(FullMath.mulDiv(bal, sum0, Q128)), "owed0 from the unwrapped window");
        assertEq(p.owed1, _capped(FullMath.mulDiv(bal, sum1, Q128)), "owed1 from the unwrapped window");
        assertEq(p.checkpoint0X128, h.range().accFee0X128, "checkpoint moved to the level");
        h.settle(address(0xA), bal);
        assertEq(h.position(address(0xA)).owed0, p.owed0);
        assertEq(h.position(address(0xA)).owed1, p.owed1);
    }

    function test_unstakedLevelWrapsThroughZero() public {
        h.setShares(1e18, 0);
        h.setLevels(type(uint256).max, type(uint256).max, 0, 0);
        h.settle(address(0xA), 0);
        h.credit(1e18, 3e18);
        uint256 inc = FullMath.mulDiv(1e18, Q128, 1e18);
        assertEq(h.range().accFee0X128, inc - 1, "wrapped through zero");
        h.settle(address(0xA), 5e17);
        assertEq(h.position(address(0xA)).owed0, 5e17, "half the shares, half the fee");
        assertEq(h.position(address(0xA)).owed1, 15e17);
    }

    /// forge-config: default.fuzz.runs = 512
    /// forge-config: deep.fuzz.runs = 20000
    function testFuzz_stakedLevelWrapMatchesUnwrappedModel(
        uint128 total,
        uint128 mine,
        uint256 offset,
        uint128[6] memory fees0
    ) public {
        total = uint128(bound(total, 1, type(uint64).max));
        mine = uint128(bound(mine, 1, total));
        uint256 feeSum = _boundFees(fees0);
        (uint256 start,) = _park(fees0, total, offset);
        h.setShares(total, total);
        h.setLevels(0, 0, start, 0);
        h.setStaked(address(0xB), mine);
        h.settle(address(0xB), mine);

        uint256 diff = _creditTracked(fees0, [uint128(0), 0, 0, 0, 0, 0], total, start, true);
        assertEq(h.distributorOwed(c0), feeSum, "fully staked: the distributor gets every unit");
        assertEq(h.range().accFee0X128, 0, "no unstaked accrual");

        uint256 before = h.position(address(0xB)).forgone0;
        h.settle(address(0xB), mine);
        assertEq(h.position(address(0xB)).forgone0 - before, FullMath.mulDiv(mine, diff, Q128), "forgone");
        assertEq(h.position(address(0xB)).owed0, 0, "staked shares accrue weight, not fees");
    }

    /// forge-config: default.fuzz.runs = 512
    /// forge-config: deep.fuzz.runs = 20000
    function testFuzz_splitConservesAcrossHolders(
        uint128[3] memory unstakedBal,
        uint128 staked,
        uint256 parked,
        uint128[6] memory fees0
    ) public {
        uint128 u;
        for (uint256 i; i < 3; ++i) {
            unstakedBal[i] = uint128(bound(unstakedBal[i], 0, type(uint64).max));
            u += unstakedBal[i];
        }
        vm.assume(u > 0);
        staked = uint128(bound(staked, 0, type(uint64).max));
        h.setShares(u + staked, staked);
        h.setLevels(parked, 0, parked, 0);
        for (uint256 i; i < 3; ++i) {
            h.settle(address(uint160(i + 1)), 0);
        }
        uint256 fees = _boundFees(fees0);
        for (uint256 i; i < 6; ++i) {
            h.credit(fees0[i], 0);
        }
        uint256 paid = _settleAll(unstakedBal) + h.distributorOwed(c0);
        assertLe(paid, fees, "never promises more than the fees");
        assertLe(fees - paid, 3 + 6 + 1, "dust: one per holder floor, one per collection floor, the staked carry");
        if (staked == 0) assertEq(h.distributorOwed(c0), 0, "nothing staked: nothing to the distributor");
    }

    function _settleAll(uint128[3] memory bal) internal returns (uint256 owed) {
        for (uint256 i; i < 3; ++i) {
            h.settle(address(uint160(i + 1)), bal[i]);
            owed += h.position(address(uint160(i + 1))).owed0;
        }
    }

    function test_owedSaturatesAtInt128Max() public {
        h.setShares(1, 0);
        h.settle(address(0xA), 0);
        h.setLevels(type(uint256).max, 0, 0, 0);
        h.settle(address(0xA), 1);
        assertEq(h.position(address(0xA)).owed0, MAX_OWED, "capped");
        h.setLevels(1 << 200, 0, 0, 0);
        h.settle(address(0xA), 1);
        assertEq(h.position(address(0xA)).owed0, MAX_OWED, "still capped, no revert");
    }
}
