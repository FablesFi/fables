// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";

import {FablesLedgerV2} from "../../../src/base/FablesLedgerV2.sol";
import {FablesHookCore} from "../../../src/base/FablesHookCore.sol";
import {FablesNativeETHV2} from "../../../src/base/FablesNativeETHV2.sol";
import {MockERC20} from "../../utils/mocks/MockERC20.sol";
import {BuildsFixture} from "../../utils/BuildsFixture.sol";

/// @notice ETH builds take native currency0 (refunding the excess); ERC20-only builds refuse it.
contract BuildsNativeTest is BuildsFixture {
    using PoolIdLibrary for PoolKey;

    function setUp() public {
        _setUpStack();
        vm.deal(address(this), 100 ether);
    }

    function _nativeKey(address hook) internal view returns (PoolKey memory) {
        return PoolKey(CurrencyLibrary.ADDRESS_ZERO, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(hook));
    }

    function test_ethBuildsAcceptNativeCurrency0() public {
        Build[4] memory t = _builds();
        uint256 covered;
        for (uint256 i = 0; i < t.length; i++) {
            if (!t[i].eth) continue;
            address at = _deploy(t[i], uint160(0xE700 + i));
            FablesLedgerV2 hook = FablesLedgerV2(payable(at));
            PoolKey memory k = _nativeKey(at);
            _configureFlat(at, k, 3000);
            _initPool(k, SQRT_PRICE_1_1);

            uint256 before = address(this).balance;
            hook.deposit{value: 0.05 ether}(k, -600, 600, 1e18, 0.05 ether, type(uint128).max, block.timestamp);
            uint256 spent = before - address(this).balance;
            assertGt(spent, 0, string.concat(t[i].name, " spent no ETH"));
            assertLt(spent, 0.05 ether, string.concat(t[i].name, " kept the unspent prepay"));
            assertEq(at.balance, 0, string.concat(t[i].name, " holds ETH between transactions"));

            before = address(this).balance;
            hook.withdraw(k, -600, 600, 1e18, address(this), 0, 0, block.timestamp);
            assertGt(address(this).balance, before, string.concat(t[i].name, " returned no ETH"));
            assertEq(at.balance, 0, string.concat(t[i].name, " holds ETH after a withdrawal"));
            covered++;
        }
        assertEq(covered, 2, "two ETH builds");
    }

    function test_erc20OnlyBuildsRefuseNativeCurrency0() public {
        Build[4] memory t = _builds();
        uint256 covered;
        for (uint256 i = 0; i < t.length; i++) {
            if (t[i].eth) continue;
            address at = _deploy(t[i], uint160(0xE800 + i));
            PoolKey memory k = _nativeKey(at);
            _configureFlat(at, k, 3000);

            vm.expectRevert(FablesHookCore.NativeNotSupported.selector);
            _initPool(k, SQRT_PRICE_1_1);

            vm.expectRevert(FablesHookCore.NativeNotSupported.selector);
            FablesLedgerV2(at).deposit(k, -600, 600, 1e18, 1, 1, block.timestamp);
            covered++;
        }
        assertEq(covered, 2, "two ERC20-only builds");
    }

    function test_ethBuildsRefuseANonWrapperAtConstruction() public {
        MockERC20 token = new MockERC20("Not WETH", "NW", 18);
        token.mint(address(this), 1e18);
        Build[4] memory t = _builds();
        for (uint256 i = 0; i < t.length; i++) {
            if (!t[i].eth) continue;
            address at = address(uint160((0xE900 + i) << 144) | t[i].flags);
            (bool ok, bytes memory ret) = _tryConstruct(t[i], at, address(0));
            assertFalse(ok, string.concat(t[i].name, " accepted a codeless WETH"));
            assertEq(bytes4(ret), FablesLedgerV2.ZeroAddress.selector, t[i].name);
            (ok, ret) = _tryConstruct(t[i], at, address(token));
            assertFalse(ok, string.concat(t[i].name, " accepted a plain ERC20 as WETH"));
            assertEq(bytes4(ret), FablesNativeETHV2.NotWrappedEther.selector, t[i].name);
        }
    }
}
