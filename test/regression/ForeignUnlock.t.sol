// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FablesLedgerV2} from "../../src/base/FablesLedgerV2.sol";
import {MockDistributor} from "../utils/mocks/MockDistributor.sol";
import {MockBallotGate} from "../utils/mocks/MockBallotGate.sol";
import {LedgerFixture} from "../utils/LedgerFixture.sol";

/// @notice Integrator making one ledger call, directly or from inside its own unlock.
contract ForeignUnlocker is IUnlockCallback {
    IPoolManager internal immutable pm;

    constructor(IPoolManager pm_) {
        pm = pm_;
    }

    function inUnlock(address target, bytes calldata data) external {
        pm.unlock(abi.encode(target, data));
    }

    function direct(address target, bytes memory data) public {
        (bool ok, bytes memory r) = target.call(data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(r, 32), mload(r))
            }
        }
    }

    function unlockCallback(bytes calldata raw) external returns (bytes memory) {
        (address target, bytes memory data) = abi.decode(raw, (address, bytes));
        direct(target, data);
        return "";
    }
}

/// @notice Every ledger entry point reverts inside a foreign PoolManager unlock and works when called directly.
abstract contract ForeignUnlockBase is LedgerFixture {
    using PoolIdLibrary for PoolKey;

    int24 internal constant LO = -600;
    int24 internal constant HI = 600;

    FablesLedgerV2 internal hook;
    PoolKey internal k;
    uint256 internal rid;
    ForeignUnlocker internal zap;
    address internal bob = makeAddr("bob");

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();
        address h = _deployBuild(0x12E2, address(new AccessManager(address(this))));
        hook = FablesLedgerV2(payable(h));
        k = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(h));
        _configureFlat(h, k, 3_000, 0, 10_000);
        _initPool(k, SQRT_PRICE_1_1);
        rid = hook.rangeId(k.toId(), LO, HI);
        hook.setDistributor(new Currency[](0), address(new MockDistributor(makeAddr("ff"))));
        hook.setBallotGate(address(new MockBallotGate()));
        hook.setClaimFee(k, new Currency[](0), 1_000, makeAddr("claimFeeRecipient"));

        zap = new ForeignUnlocker(manager);
        currency0.transfer(address(zap), 1e24);
        currency1.transfer(address(zap), 1e24);
        vm.startPrank(address(zap));
        IERC20(Currency.unwrap(currency0)).approve(h, type(uint256).max);
        IERC20(Currency.unwrap(currency1)).approve(h, type(uint256).max);
        vm.stopPrank();
        zap.direct(h, abi.encodeCall(hook.deposit, (k, LO, HI, 1e18, type(uint128).max, type(uint128).max, 1e10)));
        zap.direct(h, abi.encodeCall(hook.stake, (k, LO, HI, 1e17, 0)));
        donateRouter.donate(k, 1e18, 1e18, "");
        zap.direct(h, abi.encodeCall(hook.unstake, (k, LO, HI, 1)));
        assertGt(hook.distributorOwed(currency0), 0);
        assertGt(hook.claimFeeOwed(currency0), 0);
    }

    function _doors() internal view returns (bytes[] memory d) {
        uint256[] memory ids = new uint256[](1);
        ids[0] = rid;
        d = new bytes[](11);
        d[0] = abi.encodeCall(hook.deposit, (k, LO, HI, 1e15, type(uint128).max, type(uint128).max, 1e10));
        d[1] = abi.encodeCall(hook.withdraw, (k, LO, HI, 1e15, address(zap), 0, 0, 1e10));
        d[2] = abi.encodeCall(hook.withdrawAndClaim, (k, LO, HI, 1e15, address(zap), 0, 0, 1e10, 10_000));
        d[3] = abi.encodeCall(hook.claimFees, (k, LO, HI, address(zap), 10_000));
        d[4] = abi.encodeCall(hook.transfer, (bob, rid, 1));
        d[5] = abi.encodeCall(hook.transferFrom, (address(zap), bob, rid, 1));
        d[6] = abi.encodeCall(hook.stake, (k, LO, HI, 1e15, 0));
        d[7] = abi.encodeCall(hook.unstake, (k, LO, HI, 1e15));
        d[8] = abi.encodeCall(hook.syncRanges, (0, ids));
        d[9] = abi.encodeCall(hook.sweepDistributor, (currency0));
        d[10] = abi.encodeCall(hook.sweepClaimFee, (currency0));
    }

    function test_everyDoorRevertsInsideAForeignUnlock_landsDirectly() public {
        bytes[] memory d = _doors();
        for (uint256 i; i < d.length; ++i) {
            vm.expectRevert(IPoolManager.AlreadyUnlocked.selector);
            zap.inUnlock(address(hook), d[i]);
            zap.direct(address(hook), d[i]);
        }
        assertEq(hook.distributorOwed(currency0), 0, "the direct sweep paid");
        assertEq(hook.claimFeeOwed(currency0), 0, "the direct sweep paid");
    }
}

contract ForeignUnlockTest is ForeignUnlockBase {}
