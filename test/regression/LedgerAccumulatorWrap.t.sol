// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {RangeState, UserPosition, RangeKey, PoolClaimFee} from "../../src/base/LedgerTypesV2.sol";
import {LedgerLibV2} from "../../src/libraries/LedgerLibV2.sol";

/// @notice One ledger range driven through the library (no PoolManager call).
contract AccWrapHarness {
    using PoolIdLibrary for PoolKey;

    uint256 internal constant ID = 1;

    mapping(uint256 => RangeState) internal _ranges;
    mapping(uint256 => RangeKey) internal _rangeKeys;
    mapping(Currency => uint256) public distributorOwed;
    mapping(Currency => uint256) public claimFeeOwed;
    mapping(uint256 => uint64) internal _syncIndex;
    mapping(PoolId => PoolClaimFee) internal _pcf;
    mapping(address => UserPosition) internal _pos;
    mapping(address => uint256) public balanceOf;
    PoolKey internal _key;
    address internal _recipient;

    constructor() {
        _key = PoolKey(Currency.wrap(address(0xA0)), Currency.wrap(address(0xB0)), 0x800000, 60, IHooks(address(this)));
    }

    function currency(bool zero) external view returns (Currency) {
        return zero ? _key.currency0 : _key.currency1;
    }

    function preload(uint256 a0, uint256 a1, uint256 s0, uint256 s1) external {
        RangeState storage r = _ranges[ID];
        (r.accFee0X128, r.accFee1X128, r.accStaked0X128, r.accStaked1X128) = (a0, a1, s0, s1);
    }

    function setClaimFee(uint16 bps) external {
        PoolClaimFee storage pcf = _pcf[_key.toId()];
        _recipient = address(0xFEE5);
        pcf.allTimeMin =
            LedgerLibV2.recordClaimFee(pcf.history, bps, _recipient, address(0), address(0), pcf.allTimeMin);
        pcf.bps = bps;
    }

    function credit(uint128 fee0, uint128 fee1) external {
        LedgerLibV2.creditFees(
            _ranges,
            _rangeKeys,
            distributorOwed,
            claimFeeOwed,
            _syncIndex,
            _pcf,
            IPoolManager(address(0)),
            LedgerLibV2.CreditParams({id: ID, key: _key, fee0: fee0, fee1: fee1, claimFeeRecipient: _recipient}),
            true,
            0,
            0
        );
    }

    function settle(address who) public {
        LedgerLibV2.settleUser(_ranges[ID], _pos[who], balanceOf[who], who, ID);
    }

    function join(address who, uint128 shares) external {
        settle(who);
        balanceOf[who] += shares;
        _ranges[ID].totalShares += shares;
    }

    function leave(address who, uint128 shares) external {
        settle(who);
        require(balanceOf[who] - _pos[who].staked >= shares, "staked");
        balanceOf[who] -= shares;
        _ranges[ID].totalShares -= shares;
    }

    function stake(address who, uint128 shares) external {
        settle(who);
        require(balanceOf[who] - _pos[who].staked >= shares, "free");
        _pos[who].staked += shares;
        _ranges[ID].totalStaked += shares;
    }

    function unstake(address who, uint128 shares) external {
        settle(who);
        _pos[who].staked -= shares;
        _ranges[ID].totalStaked -= shares;
    }

    function claim(address who) external returns (uint128 got0, uint128 got1) {
        settle(who);
        (got0, got1) = (_pos[who].owed0, _pos[who].owed1);
        (_pos[who].owed0, _pos[who].owed1) = (0, 0);
    }

    function position(address who) external view returns (UserPosition memory) {
        return _pos[who];
    }

    function range() external view returns (RangeState memory) {
        return _ranges[ID];
    }
}

/// @notice Per-share fee levels wrap mod 2^256; holders read modular differences.
contract LedgerAccumulatorWrapTest is Test {
    uint256 internal constant Q128 = 1 << 128;
    uint256 internal constant PUMPED = type(uint256).max - Q128 + 1;

    AccWrapHarness internal ref;
    AccWrapHarness internal wrp;
    address[3] internal who = [address(0xA11CE), address(0xB0B), address(0xCA401)];

    function setUp() public {
        ref = new AccWrapHarness();
        wrp = new AccWrapHarness();
    }

    function test_unstakedLevelWraps_owedIsTheModularDifference() public {
        wrp.preload(PUMPED, type(uint256).max, 0, 0);
        uint128 shares = 1e20;
        wrp.join(who[1], shares);
        uint128 fee0 = 4_321e18;
        uint128 fee1 = 7;
        wrp.credit(fee0, fee1);
        RangeState memory r = wrp.range();
        uint256 inc0 = FullMath.mulDiv(fee0, Q128, shares);
        uint256 inc1 = FullMath.mulDiv(fee1, Q128, shares);
        unchecked {
            assertEq(r.accFee0X128, PUMPED + inc0, "the level wraps mod 2^256");
            assertEq(r.accFee1X128, type(uint256).max + inc1, "the level wraps mod 2^256");
        }
        assertLt(r.accFee0X128, PUMPED, "it did cross 2^256");
        (uint128 got0, uint128 got1) = wrp.claim(who[1]);
        assertEq(got0, FullMath.mulDiv(shares, inc0, Q128), "owed0 = shares x (level - checkpoint mod 2^256)");
        assertEq(got1, FullMath.mulDiv(shares, inc1, Q128), "owed1 = shares x (level - checkpoint mod 2^256)");
        assertGe(got0, fee0 - 1, "and that is the fee he earned, less a floor");
        assertLe(got0, fee0);
    }

    function test_stakedLevelWraps_forgoneIsTheModularDifference() public {
        wrp.preload(0, 0, PUMPED, type(uint256).max - 5);
        wrp.join(who[0], 3e18);
        wrp.stake(who[0], 3e18);
        wrp.credit(9e18, 9e18);
        RangeState memory r = wrp.range();
        unchecked {
            assertEq(r.accStaked0X128, PUMPED + 3 * Q128, "the staked level wraps mod 2^256");
            assertEq(r.accStaked1X128, type(uint256).max - 5 + 3 * Q128, "the staked level wraps mod 2^256");
        }
        assertLt(r.accStaked0X128, PUMPED, "crossed 2^256");
        assertLt(r.accStaked1X128, type(uint256).max - 5, "crossed 2^256");
        wrp.settle(who[0]);
        UserPosition memory p = wrp.position(who[0]);
        assertEq(p.forgone0, 9e18, "fully staked: the whole fee is the holder's weight");
        assertEq(p.forgone1, 9e18);
        assertEq(wrp.distributorOwed(wrp.currency(true)), 9e18, "the cut is the whole fee");
    }

    function test_claimFeeAndStakedCutConserveAcrossTheWrap() public {
        AccWrapHarness[2] memory hs = [ref, wrp];
        wrp.preload(PUMPED, PUMPED, PUMPED, PUMPED);
        for (uint256 i; i < 2; ++i) {
            hs[i].settle(who[2]);
            hs[i].setClaimFee(2_000);
            hs[i].join(who[0], 5e17);
            hs[i].join(who[1], 3e17);
            hs[i].stake(who[1], 1e17);
            hs[i].credit(1, 1);
            hs[i].credit(3e18 + 1, 7e17 + 3);
            hs[i].credit(5e18, 11);
            hs[i].settle(who[0]);
            hs[i].settle(who[1]);
        }
        _assertSame();
        for (uint256 z; z < 2; ++z) {
            bool zero = z == 0;
            uint256 collected = zero ? 3e18 + 1 + 5e18 + 1 : 7e17 + 3 + 11 + 1;
            uint256 booked = wrp.distributorOwed(wrp.currency(zero)) + wrp.claimFeeOwed(wrp.currency(zero));
            for (uint256 a; a < 2; ++a) {
                UserPosition memory p = wrp.position(who[a]);
                booked += zero ? p.owed0 : p.owed1;
            }
            assertLe(booked, collected, "never promises more than was collected");
            assertGe(booked + 4, collected, "dust only: one floor per settle and per credit");
            assertGt(wrp.claimFeeOwed(wrp.currency(zero)), 0, "the claim fee was taken across the wrap");
        }
    }

    function testFuzz_wrappedLedgerMatchesTheUnwrappedOne(uint256[4] memory levels, uint256 seed) public {
        for (uint256 i; i < 4; ++i) {
            if (levels[i] % 2 == 0) levels[i] = type(uint256).max - (levels[i] >> 124);
        }
        wrp.preload(levels[0], levels[1], levels[2], levels[3]);
        for (uint256 a; a < 3; ++a) {
            ref.settle(who[a]);
            wrp.settle(who[a]);
        }
        if (seed % 3 == 0) {
            ref.setClaimFee(uint16(seed % 2_001));
            wrp.setClaimFee(uint16(seed % 2_001));
        }
        for (uint256 step; step < 48; ++step) {
            seed = uint256(keccak256(abi.encode(seed, step)));
            _apply(seed);
            _assertSame();
        }
        for (uint256 a; a < 3; ++a) {
            ref.settle(who[a]);
            wrp.settle(who[a]);
        }
        _assertSame();
        RangeState memory r = ref.range();
        RangeState memory w = wrp.range();
        unchecked {
            assertEq(w.accFee0X128, r.accFee0X128 + levels[0], "level = pre-load + increments, mod 2^256");
            assertEq(w.accFee1X128, r.accFee1X128 + levels[1]);
            assertEq(w.accStaked0X128, r.accStaked0X128 + levels[2]);
            assertEq(w.accStaked1X128, r.accStaked1X128 + levels[3]);
        }
    }

    function _apply(uint256 seed) internal {
        address a = who[seed % 3];
        uint256 op = (seed >> 8) % 7;
        uint256 v = seed >> 16;
        AccWrapHarness[2] memory hs = [ref, wrp];
        uint256 bal = ref.balanceOf(a);
        uint256 free = bal - ref.position(a).staked;
        RangeState memory r = ref.range();
        for (uint256 i; i < 2; ++i) {
            if (op == 0 || (op == 1 && free == 0) || (op == 4 && r.totalShares == 0)) {
                hs[i].join(a, uint128(bound(v, 1, 1 << 100)));
            } else if (op == 1) {
                hs[i].leave(a, uint128(bound(v, 1, free)));
            } else if (op == 2 && free != 0) {
                hs[i].stake(a, uint128(bound(v, 1, free)));
            } else if (op == 3 && bal - free != 0) {
                hs[i].unstake(a, uint128(bound(v, 1, bal - free)));
            } else if (op == 4) {
                hs[i].credit(uint128(v % (1 << 100)), uint128((v >> 100) % (1 << 100)));
            } else if (op == 5) {
                hs[i].claim(a);
            } else {
                hs[i].settle(a);
            }
        }
    }

    function _assertSame() internal view {
        RangeState memory r = ref.range();
        RangeState memory w = wrp.range();
        assertEq(w.totalShares, r.totalShares);
        assertEq(w.totalStaked, r.totalStaked);
        assertEq(w.stakedResidual0, r.stakedResidual0, "staked-cut carry");
        assertEq(w.stakedResidual1, r.stakedResidual1, "staked-cut carry");
        for (uint256 z; z < 2; ++z) {
            assertEq(wrp.distributorOwed(wrp.currency(z == 0)), ref.distributorOwed(ref.currency(z == 0)), "pot");
            assertEq(wrp.claimFeeOwed(wrp.currency(z == 0)), ref.claimFeeOwed(ref.currency(z == 0)), "claim-fee pot");
        }
        for (uint256 a; a < 3; ++a) {
            UserPosition memory p = ref.position(who[a]);
            UserPosition memory q = wrp.position(who[a]);
            assertEq(q.owed0, p.owed0, "owed0");
            assertEq(q.owed1, p.owed1, "owed1");
            assertEq(q.forgone0, p.forgone0, "forgone0");
            assertEq(q.forgone1, p.forgone1, "forgone1");
            assertEq(q.staked, p.staked);
            unchecked {
                assertEq(q.checkpoint0X128 - p.checkpoint0X128, w.accFee0X128 - r.accFee0X128, "checkpoint0");
                assertEq(q.checkpoint1X128 - p.checkpoint1X128, w.accFee1X128 - r.accFee1X128, "checkpoint1");
                assertEq(
                    q.stakedCheckpoint0X128 - p.stakedCheckpoint0X128,
                    w.accStaked0X128 - r.accStaked0X128,
                    "stakedCheckpoint0"
                );
                assertEq(
                    q.stakedCheckpoint1X128 - p.stakedCheckpoint1X128,
                    w.accStaked1X128 - r.accStaked1X128,
                    "stakedCheckpoint1"
                );
            }
        }
    }
}
