# regression

One file per fixed behaviour, named after the behaviour it pins (initializer gate, CF anchor rounding and period,
configure-while-on, discount filter order, stable fee cap, owed saturation, foreign unlock, per-share level wrap and
the pumped-range scenarios).

```
forge test --match-path "test/regression/**"
```
