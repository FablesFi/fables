// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {FablesLedgerV2} from "../../../src/base/FablesLedgerV2.sol";
import {FablesHookCore} from "../../../src/base/FablesHookCore.sol";
import {FablesNativeETHV2} from "../../../src/base/FablesNativeETHV2.sol";
import {BuildsFixture} from "../../utils/BuildsFixture.sol";

/// @notice Each build deploys only at its own flag word, reads its immutables back and runs a ledger cycle at its
///         configured fee.
contract BuildsFlagsTest is BuildsFixture {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint128 constant DEPOSIT_LIQ = 1e18;

    function setUp() public {
        _setUpStack();
    }

    function test_everyBuildDeploysAtItsFlagWordAndReadsItsImmutablesBack() public {
        Build[4] memory t = _builds();
        for (uint256 i = 0; i < t.length; i++) {
            address at = _deploy(t[i], uint160(0xB000 + i));
            assertEq(uint160(at) & uint160(Hooks.ALL_HOOK_MASK), t[i].flags, t[i].name);
            assertEq(address(FablesHookCore(at).poolManager()), address(manager), string.concat(t[i].name, " pm"));
            assertEq(FablesHookCore(at).authority(), address(authority), string.concat(t[i].name, " authority"));
            if (t[i].eth) {
                assertEq(
                    address(FablesNativeETHV2(payable(at)).weth()), address(weth), string.concat(t[i].name, " weth")
                );
            }
        }
    }

    function test_everyBuildRefusesEveryOtherFlagWord() public {
        Build[4] memory t = _builds();
        uint160[10] memory words =
            [uint160(0x0000), 0x2000, 0x1000, 0x0080, 0x0800, FULL, FULL_EXCLUSIVE, 0x3000, 0x3800, 0x3FFF];
        uint256 refused;
        for (uint256 i = 0; i < t.length; i++) {
            for (uint256 w = 0; w < words.length; w++) {
                address at = address(uint160((0xBAD0 + i * 16 + w) << 144) | words[w]);
                (bool ok, bytes memory ret) = _tryConstruct(t[i], at, address(weth));
                if (words[w] == t[i].flags) {
                    assertTrue(ok, string.concat(t[i].name, " refused its own flag word"));
                    continue;
                }
                assertFalse(ok, string.concat(t[i].name, " accepted a foreign flag word"));
                assertEq(ret, abi.encodeWithSelector(Hooks.HookAddressNotValid.selector, at), t[i].name);
                refused++;
            }
        }
        assertEq(refused, 4 * 9, "every build refused every other word");
    }

    function test_everyBuildRunsALedgerCycleAtItsConfiguredFee() public {
        Build[4] memory t = _builds();
        for (uint256 i = 0; i < t.length; i++) {
            address at = _deploy(t[i], uint160(0xC0DE + i));
            FablesLedgerV2 hook = FablesLedgerV2(payable(at));
            PoolKey memory k = _erc20Key(at, 60);
            _configureFlat(at, k, 3000);
            _initPool(k, SQRT_PRICE_1_1);
            PoolId id = k.toId();

            hook.deposit(k, -120, 120, DEPOSIT_LIQ, type(uint128).max, type(uint128).max, block.timestamp);
            assertEq(manager.getLiquidity(id), DEPOSIT_LIQ, string.concat(t[i].name, " deposit"));

            vm.recordLogs();
            swap(k, true, -1e15, ZERO_BYTES);
            assertEq(_lastSwapFee(), 3000, string.concat(t[i].name, " fee zeroForOne"));
            vm.recordLogs();
            swap(k, false, -1e15, ZERO_BYTES);
            assertEq(_lastSwapFee(), 3000, string.concat(t[i].name, " fee oneForZero"));

            uint256 b0 = IERC20(Currency.unwrap(currency0)).balanceOf(address(this));
            uint256 b1 = IERC20(Currency.unwrap(currency1)).balanceOf(address(this));
            hook.claimFees(k, -120, 120, address(this), 10_000);
            uint256 claimed = (IERC20(Currency.unwrap(currency0)).balanceOf(address(this)) - b0)
                + (IERC20(Currency.unwrap(currency1)).balanceOf(address(this)) - b1);
            assertGt(claimed, 0, string.concat(t[i].name, " claim paid nothing"));

            hook.withdraw(k, -120, 120, DEPOSIT_LIQ, address(this), 0, 0, block.timestamp);
            assertEq(manager.getLiquidity(id), 0, string.concat(t[i].name, " withdraw"));
            assertEq(hook.balanceOf(address(this), hook.rangeId(id, -120, 120)), 0, string.concat(t[i].name, " shares"));
        }
    }
}
