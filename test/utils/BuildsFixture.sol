// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {FablesFeeEngine} from "../../src/base/FablesFeeEngine.sol";
import {MockWETH9} from "./mocks/MockWETH9.sol";

/// @notice The four FablesHook builds as a table, with flag-address deployment, a raw constructor probe and a Swap-
///         event fee reader.
abstract contract BuildsFixture is Test, Deployers {
    struct Build {
        string name;
        uint160 flags;
        bool eth;
        bool exclusive;
    }

    uint8 internal constant CAT = 1;
    uint160 internal constant FULL = 0x2080;
    uint160 internal constant FULL_EXCLUSIVE = 0x2880;
    bytes32 internal constant SWAP_TOPIC =
        keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");

    AccessManager internal authority;
    MockWETH9 internal weth;

    function _builds() internal pure returns (Build[4] memory t) {
        t[0] = Build("FablesHook", FULL, false, false);
        t[1] = Build("FablesHookETH", FULL, true, false);
        t[2] = Build("FablesHookExclusive", FULL_EXCLUSIVE, false, true);
        t[3] = Build("FablesHookETHExclusive", FULL_EXCLUSIVE, true, true);
    }

    function _artifactOf(Build memory b) internal pure returns (string memory) {
        return string.concat(b.name, ".sol:", b.name);
    }

    function _ctorArgs(Build memory b, address weth_) internal view returns (bytes memory) {
        return b.eth ? abi.encode(manager, address(authority), weth_) : abi.encode(manager, address(authority));
    }

    function _setUpStack() internal {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();
        authority = new AccessManager(address(this));
        weth = new MockWETH9();
    }

    function _deploy(Build memory b, uint160 prefix) internal returns (address at) {
        at = address(uint160(prefix << 144) | b.flags);
        deployCodeTo(_artifactOf(b), _ctorArgs(b, address(weth)), at);
        FablesFeeEngine(at).setCategory(CAT, 0, 100_000, 100_000, "ANY");
        IERC20(Currency.unwrap(currency0)).approve(at, type(uint256).max);
        IERC20(Currency.unwrap(currency1)).approve(at, type(uint256).max);
    }

    function _tryConstruct(Build memory b, address at, address weth_) internal returns (bool ok, bytes memory ret) {
        vm.etch(at, abi.encodePacked(vm.getCode(_artifactOf(b)), _ctorArgs(b, weth_)));
        (ok, ret) = at.call("");
        if (ok) vm.etch(at, ret);
    }

    function _erc20Key(address hook, int24 spacing) internal view returns (PoolKey memory) {
        return PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, spacing, IHooks(hook));
    }

    function _configureFlat(address hook, PoolKey memory k, uint24 base) internal {
        FablesFeeEngine(hook).configurePool(k, CAT, base, base, 0, 50_000);
    }

    function _initPool(PoolKey memory key, uint160 sqrtPriceX96) internal {
        FablesFeeEngine(address(key.hooks)).initializePool(key, sqrtPriceX96);
    }

    function _lastSwapFee() internal view returns (uint24 fee) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool seen;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(manager) && logs[i].topics[0] == SWAP_TOPIC) {
                (,,,,, fee) = abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
                seen = true;
            }
        }
        assertTrue(seen, "no Swap event");
    }
}
