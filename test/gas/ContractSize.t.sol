// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";

/// @notice Every build's runtime code is under Robinhood Chain's 98,304-byte limit.
contract ContractSizeTest is Test {
    uint256 internal constant RUNTIME_CODE_LIMIT = 98_304;

    function test_everyBuildIsWithinTheRuntimeLimit() public view {
        string[6] memory builds = [
            "FablesHook.sol:FablesHook",
            "FablesHookETH.sol:FablesHookETH",
            "FablesHookExclusive.sol:FablesHookExclusive",
            "FablesHookETHExclusive.sol:FablesHookETHExclusive",
            "FablesStableHookLite.sol:FablesStableHookLite",
            "FablesStableHookLiteExclusive.sol:FablesStableHookLiteExclusive"
        ];
        for (uint256 i = 0; i < builds.length; i++) {
            uint256 size = vm.getDeployedCode(builds[i]).length;
            console2.log(string.concat(builds[i], " runtime bytes: ", vm.toString(size)));
            assertGt(size, 0, builds[i]);
            assertLt(size, RUNTIME_CODE_LIMIT, builds[i]);
        }
    }
}
