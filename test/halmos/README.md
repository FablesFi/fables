# halmos

Symbolic checks (`check_*`) over the pure fee libraries: PoolWordLib, DiscountLib and FeeRef. `forge test` does not
run them. From the repo root:

```
FOUNDRY_SRC=src/libraries FOUNDRY_TEST=test/halmos FOUNDRY_OUT=out/halmos FOUNDRY_CACHE_PATH=cache/halmos \
  halmos --config test/halmos/halmos.toml --forge-build-out out/halmos
```
