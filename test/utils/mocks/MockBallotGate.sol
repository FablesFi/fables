// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {PoolId} from "v4-core/src/types/PoolId.sol";

/// @notice Ballot gate stand-in with switchable answers.
contract MockBallotGate {
    bool public allow = true;

    address public ve;

    constructor() {
        ve = address(new MockEscrowRef(address(this)));
    }

    function setAllow(bool allow_) external {
        allow = allow_;
    }

    bool public killed;

    function setKilled(bool killed_) external {
        killed = killed_;
    }

    bool public live = true;

    function setLive(bool live_) external {
        live = live_;
    }

    function ballotBacks(address, uint256, PoolId) external view returns (bool) {
        return allow;
    }

    function isGaugeKilled(PoolId) external view returns (bool) {
        return killed;
    }

    function isGaugeEarning(PoolId poolId) external view returns (bool) {
        return this.isGaugeLive(poolId) && !noVotes;
    }

    bool public noVotes;

    function setNoVotes(bool value) external {
        noVotes = value;
    }

    function isGaugeLive(PoolId) external view returns (bool) {
        return live && !killed;
    }

    function gaugeWeightNow(PoolId) external pure returns (uint256) {
        return type(uint128).max;
    }
}

/// @notice Escrow stub that names its gate.
contract MockEscrowRef {
    address public voter;

    constructor(address voter_) {
        voter = voter_;
    }

    function point(address voter_) external {
        voter = voter_;
    }
}
