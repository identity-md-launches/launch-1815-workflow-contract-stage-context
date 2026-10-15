# Additional adversarial tests

Run from the repository root:

```sh
forge build
FOUNDRY_FUZZ_SEED=0x7671605db5f5d95e927e9bd5e10d79de9f0baa55b6ba2a823655046e469faf5c forge test
```

These tests supplement the accepted suite without changing its fixtures or production contracts.

| File | Additional evidence |
| --- | --- |
| `HongbaoAtomicity.t.sol` | All 24 combinations of six payout paths (grab, reveal, settle, refund, surplus recovery, claim) and four outbound token faults. Faults that move balances inexactly, and every fault on grab/reveal/recovery/claim, revert; snapshots prove balances, packet fields, shares, replay flags, credits and liabilities are unchanged, and retrying after the fault succeeds. Refused transfers (false return, silent no-op) on settle/refund finish the packet, credit each recipient exactly what it was owed, stay outside surplus recovery and pay out through `claim`. Separate regressions fail the creator's recipient transfer and the final creator refund after earlier reveal payouts. |
| `HongbaoArithmetic.t.sol` | 1,000 full-width amount cases and 1,000 funding-threshold cases. Explicit maximum-uint256 tests cover a 200-recipient reveal, a 199-of-200 fallback and an empty reveal. The proportional-payout oracle uses quotient/remainder decomposition rather than the production `mulDiv` implementation. |
| `HongbaoLedgerInvariant.t.sol` | Six funded actors serve as creators, recipients and relayers across mixed equal/lucky packets. An independent ledger checks every actor's exact IMD balance, packet obligations and metadata, burn accounting, unsolicited transfers and surplus recovery. Invalid grabs and terminal mutators are interleaved with valid calls. Teardown settles/refunds every open packet without using reveal secrets. |
| `LaunchTokenInvariant.t.sol` | Four holders run transfers, self-transfers, arbitrary approvals, revocations, delegated transfers and expected failures. A separate balance/allowance ledger checks fixed supply, finite allowance consumption, infinite allowances and rollback on failure. |

Both added invariant campaigns specify 256 sequences of 96 handler calls in inline Foundry
configuration, with unexpected reverts treated as failures. Deterministic handler tests exercise
the terminal paths and allowance boundaries even before random generation. The Hongbao ledger
funds actors only during setup; packet operations cannot hide losses through balance top-ups.
Random lucky shares are checked for minimum, double-average/reserve ceilings, exact sum and best
luck, and reconciled against actual token balances. The existing published draw vector separately
checks the exact deterministic RNG output.

The suite runs offline against local ERC-20 fixtures. It does not establish the current behavior,
code or gas costs of the requester-supplied IMD contract on Robinhood Chain. Live integration
verification against that token remains outstanding. Exact accounting and drainability assume
a functioning, nonrebasing IMD token; failure-path tests prove atomic rollback and retry, or deferral to
`claimable` credits on the fallback paths, rather than assuming a paused or blocklisted token can be overridden.
