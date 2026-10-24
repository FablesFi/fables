// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {FablesHook} from "../../src/FablesHook.sol";
import {FablesHookETH} from "../../src/FablesHookETH.sol";
import {FablesStableHookLite} from "../../src/FablesStableHookLite.sol";
import {FablesStableHookLiteExclusive} from "../../src/FablesStableHookLiteExclusive.sol";
import {Vm} from "forge-std/Vm.sol";

/// @notice Runs `creation ++ args` as the code of `at` (the constructor sees its final address), then installs the
///         returned runtime there. Like forge-std's `deployCodeTo`, but takes the creation code as a value.
library EtchDeploy {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    function to(bytes memory creation, bytes memory args, address at) internal {
        vm.etch(at, abi.encodePacked(creation, args));
        (bool ok, bytes memory runtime) = at.call("");
        require(ok, "EtchDeploy: constructor reverted");
        vm.etch(at, runtime);
    }
}

/// @notice Default vs deep fuzz budget. Deep under `FOUNDRY_PROFILE=deep` or when `FOUNDRY_INVARIANT_RUNS` /
///         `FOUNDRY_INVARIANT_DEPTH` is set; otherwise each handler is capped at `PR_STEPS` actions per run.
library Depth {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    uint256 internal constant PR_STEPS = 6;

    function deep() internal view returns (bool) {
        if (keccak256(bytes(vm.envOr("FOUNDRY_PROFILE", string("")))) == keccak256("deep")) return true;
        return
            vm.envOr("FOUNDRY_INVARIANT_RUNS", uint256(0)) != 0 || vm.envOr("FOUNDRY_INVARIANT_DEPTH", uint256(0)) != 0;
    }

    /// @notice Actions a handler may take per run: unlimited when deep, `prSteps` otherwise.
    function budget(uint256 prSteps) internal view returns (uint256) {
        return deep() ? type(uint256).max : prSteps;
    }
}

/// @notice Creation code of the builds the fuzz suites deploy.
library BuildCode {
    function fablesHook() internal pure returns (bytes memory) {
        return type(FablesHook).creationCode;
    }

    function fablesHookETH() internal pure returns (bytes memory) {
        return type(FablesHookETH).creationCode;
    }

    function fablesStableHookLite() internal pure returns (bytes memory) {
        return type(FablesStableHookLite).creationCode;
    }

    function fablesStableHookLiteExclusive() internal pure returns (bytes memory) {
        return type(FablesStableHookLiteExclusive).creationCode;
    }
}

/// @notice The two Stable Lite builds: FablesStableHookLite (open liquidity, flags 0x2080) and
///         FablesStableHookLiteExclusive (ledger-only liquidity, flags 0x2880).
library StableBuild {
    uint160 internal constant OPEN_FLAGS = 0x2080;
    uint160 internal constant EXCLUSIVE_FLAGS = 0x2880;

    function name(bool exclusive) internal pure returns (string memory) {
        return exclusive ? "FablesStableHookLiteExclusive" : "FablesStableHookLite";
    }

    function artifact(bool exclusive) internal pure returns (string memory) {
        return string.concat(name(exclusive), ".sol:", name(exclusive));
    }

    function flags(bool exclusive) internal pure returns (uint160) {
        return exclusive ? EXCLUSIVE_FLAGS : OPEN_FLAGS;
    }

    function creationCode(bool exclusive) internal pure returns (bytes memory) {
        return exclusive ? BuildCode.fablesStableHookLiteExclusive() : BuildCode.fablesStableHookLite();
    }
}
