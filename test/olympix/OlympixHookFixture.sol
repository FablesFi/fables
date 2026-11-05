// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IERC20Minimal} from "v4-core/src/interfaces/external/IERC20Minimal.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";

import {FablesLedgerV2} from "../../src/base/FablesLedgerV2.sol";
import {FablesFeeEngine} from "../../src/base/FablesFeeEngine.sol";
import {FablesExclusiveLiquidityV2} from "../../src/base/FablesExclusiveLiquidityV2.sol";
import {MockBallotGate} from "../utils/mocks/MockBallotGate.sol";
import {MockDistributor} from "../utils/mocks/MockDistributor.sol";
import {BuildsFixture} from "../utils/BuildsFixture.sol";

/// @notice One FablesHook build with a live ERC-20 pool (plus a native pool on the ETH builds): ledger wired to a
///         distributor and ballot gate, 10% claim fee, two funded LPs (alice deposited; bob deposited and staked half)
///         and one swap each way. The test contract is the AccessManager admin, so it can call every role function.
abstract contract OlympixHookFixture is BuildsFixture {
    using PoolIdLibrary for PoolKey;

    int24 internal constant LO = -600;
    int24 internal constant HI = 600;
    uint128 internal constant LIQ = 1e18;
    uint24 internal constant BASE_FEE = 3000;
    uint24 internal constant POOL_CAP = 50_000;
    uint16 internal constant CLAIM_FEE_BPS = 1000;

    address internal hookAddr;
    FablesLedgerV2 internal ledger;
    FablesFeeEngine internal engine;
    MockBallotGate internal gate;
    PoolId internal poolId;
    uint256 internal rid;
    address internal alice = makeAddr("olympix.alice");
    address internal bob = makeAddr("olympix.bob");
    address internal claimFeeRecipient = makeAddr("olympix.claimFeeRecipient");

    /// @param index Row of `_builds()`: 0 FablesHook, 1 FablesHookETH, 2 FablesHookExclusive, 3 FablesHookETHExclusive.
    function _setUpBuild(uint256 index) internal {
        Build memory b = _builds()[index];
        _setUpStack();
        hookAddr = _deploy(b, 0x01F0);
        ledger = FablesLedgerV2(payable(hookAddr));
        engine = FablesFeeEngine(hookAddr);
        ledger.setDistributor(new Currency[](0), address(new MockDistributor(makeAddr("olympix.fables"))));
        gate = new MockBallotGate();
        ledger.setBallotGate(address(gate));

        key = _erc20Key(hookAddr, 60);
        engine.configurePool(key, CAT, BASE_FEE, BASE_FEE, 0, POOL_CAP);
        _initPool(key, SQRT_PRICE_1_1);
        poolId = key.toId();
        rid = ledger.rangeId(poolId, LO, HI);
        ledger.setClaimFee(key, new Currency[](0), CLAIM_FEE_BPS, claimFeeRecipient);

        _fund(alice);
        _fund(bob);
        vm.prank(alice);
        ledger.deposit(key, LO, HI, LIQ, type(uint128).max, type(uint128).max, block.timestamp);
        vm.startPrank(bob);
        ledger.deposit(key, LO, HI, LIQ, type(uint128).max, type(uint128).max, block.timestamp);
        ledger.stake(key, LO, HI, LIQ / 2, 0);
        vm.stopPrank();

        if (b.eth) {
            nativeKey =
                PoolKey(CurrencyLibrary.ADDRESS_ZERO, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(hookAddr));
            engine.configurePool(nativeKey, CAT, BASE_FEE, BASE_FEE, 0, POOL_CAP);
            _initPool(nativeKey, SQRT_PRICE_1_1);
            vm.prank(alice);
            ledger.deposit{value: 1 ether}(nativeKey, LO, HI, LIQ, 1 ether, type(uint128).max, block.timestamp);
        }

        swap(key, true, -1e15, ZERO_BYTES);
        swap(key, false, -1e15, ZERO_BYTES);
    }

    /// @notice Expects the Exclusive builds' refusal of liquidity added around the ledger.
    function _expectGateRevert() internal {
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                hookAddr,
                IHooks.beforeAddLiquidity.selector,
                abi.encodeWithSelector(FablesExclusiveLiquidityV2.LiquidityOnlyViaLedger.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
    }

    function _fund(address who) internal {
        vm.deal(who, 100 ether);
        IERC20Minimal(Currency.unwrap(currency0)).transfer(who, 1e24);
        IERC20Minimal(Currency.unwrap(currency1)).transfer(who, 1e24);
        vm.startPrank(who);
        IERC20Minimal(Currency.unwrap(currency0)).approve(hookAddr, type(uint256).max);
        IERC20Minimal(Currency.unwrap(currency1)).approve(hookAddr, type(uint256).max);
        vm.stopPrank();
    }
}
