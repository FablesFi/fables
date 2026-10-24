// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

/// @notice AccessManager role ids the test fixtures bind on the hooks.
library Roles {
    uint64 internal constant ADMIN = 0;
    uint64 internal constant FEE_POKER = 1;
    uint64 internal constant PAUSER = 4;
    uint64 internal constant POKER_ADMIN = 5;
    uint64 internal constant PAUSER_ADMIN = 6;
    uint64 internal constant REVENUE_OPS = 9;
    uint64 internal constant DISCOUNT_ADMIN = 14;
    uint64 internal constant SEEDER = 15;

    uint32 internal constant DISCOUNT_ADMIN_DELAY = 1 days;
}
