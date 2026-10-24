# fork

Read-only Robinhood Chain fork tests on real USDe / USDG: pinned-block facts, a hookless swap through the Universal
Router, and FablesStableHookLite against a hookless pool. They skip unless `RC_RPC_URL` is set. The default pin
needs an archive node; `RC_FORK_BLOCK` overrides it. Nothing is broadcast.

```
RC_RPC_URL=<url> forge test --match-path "test/fork/**" --isolate -vv
```
