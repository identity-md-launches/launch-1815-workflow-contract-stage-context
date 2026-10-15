# Compiler ABI exports

- `LaunchToken.json`: the no-argument, fixed-supply HONGBAO ERC-20.
- `HongbaoBox.json`: the one-address-constructor IMD packet application.

These are plain ABI arrays including constructor, functions, events and custom errors. They are
generated from the pinned Solidity 0.8.26 build using `python3 script/export_abi.py` after
`forge build`. Use `python3 script/export_abi.py --check` to detect stale exports.

See [the integration guide](../INTEGRATION.md) for tuple fields, enum values, exact encodings,
signature handling, errors and settlement semantics. ABI files contain no deployment addresses.
