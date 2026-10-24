// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolDonateTest} from "v4-core/src/test/PoolDonateTest.sol";
import {IERC20Minimal} from "v4-core/src/interfaces/external/IERC20Minimal.sol";
import {FablesLedgerV2} from "../../src/base/FablesLedgerV2.sol";
import {RangeState} from "../../src/base/LedgerTypesV2.sol";
import {MockDistributor} from "../utils/mocks/MockDistributor.sol";
import {MockBallotGate} from "../utils/mocks/MockBallotGate.sol";
import {LedgerConservationInvariantBase} from "../invariant/LedgerConservationInvariant.t.sol";
import {LedgerInvariantBase} from "../invariant/LedgerInvariant.t.sol";

/// @notice Pumps an empty range's per-share levels to 2^256 - 2^96 by recycling donations.
library AccumulatorPump {
    uint256 internal constant PUMPED = type(uint256).max - (uint256(1) << 96) + 1;
    uint256 internal constant MAX_DONATION = (uint256(1) << 127) - 1;

    function pumpEverything(
        FablesLedgerV2 hook,
        PoolKey memory key,
        PoolDonateTest donor,
        int24[3] memory lo,
        int24[3] memory hi
    ) internal {
        IERC20Minimal(Currency.unwrap(key.currency0)).approve(address(hook), type(uint256).max);
        IERC20Minimal(Currency.unwrap(key.currency1)).approve(address(hook), type(uint256).max);
        hook.setDistributor(new Currency[](0), address(new MockDistributor(address(0xFF))));
        hook.setBallotGate(address(new MockBallotGate()));
        for (uint256 i; i < 3; ++i) {
            pump(hook, key, donor, lo[i], hi[i], false);
            pump(hook, key, donor, lo[i], hi[i], true);
            RangeState memory r = hook.rangeState(hook.rangeId(PoolIdLibrary.toId(key), lo[i], hi[i]));
            require(r.totalShares == 0, "range left empty");
            require(r.accFee0X128 == PUMPED && r.accFee1X128 == PUMPED, "accFee pumped");
            require(r.accStaked0X128 == PUMPED && r.accStaked1X128 == PUMPED, "accStaked pumped");
        }
    }

    function pump(FablesLedgerV2 hook, PoolKey memory key, PoolDonateTest donor, int24 lo, int24 hi, bool staked)
        internal
    {
        _join(hook, key, lo, hi, 1, staked);
        _window(hook, key, donor, lo, hi, MAX_DONATION, staked);
        _window(hook, key, donor, lo, hi, MAX_DONATION, staked);
        _join(hook, key, lo, hi, (uint128(1) << 40) - 1, staked);
        _window(hook, key, donor, lo, hi, (uint256(1) << 41) - 256, staked);
        if (staked) hook.unstake(key, lo, hi, uint128(1) << 40);
        hook.withdraw(key, lo, hi, uint128(1) << 40, address(this), 0, 0, block.timestamp);
    }

    function _join(FablesLedgerV2 hook, PoolKey memory key, int24 lo, int24 hi, uint128 shares, bool staked) private {
        hook.deposit(key, lo, hi, shares, type(uint128).max, type(uint128).max, block.timestamp);
        if (staked) hook.stake(key, lo, hi, shares, 0);
    }

    function _window(
        FablesLedgerV2 hook,
        PoolKey memory key,
        PoolDonateTest donor,
        int24 lo,
        int24 hi,
        uint256 amount,
        bool staked
    ) private {
        donor.donate(key, amount, amount, "");
        hook.claimFees(key, lo, hi, address(this), 10_000);
        if (staked) {
            hook.sweepDistributor(key.currency0);
            hook.sweepDistributor(key.currency1);
        }
    }
}

/// @notice The ledger conservation suite on pumped ranges.
contract PumpedConservationInvariantTest is LedgerConservationInvariantBase {
    function _beforeSeeding() internal override {
        AccumulatorPump.pumpEverything(hook, key, donateRouter, lo, hi);
    }
}

/// @notice The ledger invariant suite on pumped ranges.
abstract contract PumpedLedgerBase is LedgerInvariantBase {
    function _beforeSeeding() internal override {
        int24[3] memory lo = [int24(-120), -600, -60];
        int24[3] memory hi = [int24(120), 600, 60];
        AccumulatorPump.pumpEverything(hook, key, donateRouter, lo, hi);
    }
}

contract PumpedLedgerInvariantTest is PumpedLedgerBase {}
