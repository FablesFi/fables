# gas

Gas and size checks on the Robinhood Chain v4 bytecode, as execution-gas deltas over hookless pools of the same
shape, plus runtime code size against Robinhood Chain's 98,304-byte limit.

```
forge test --match-path "test/gas/**"
forge test --match-path "test/gas/**" --isolate -vv   # whole-transaction gas; prints ROW| lines
```

Tight bounds on deltas are asserted only under `--isolate`.
