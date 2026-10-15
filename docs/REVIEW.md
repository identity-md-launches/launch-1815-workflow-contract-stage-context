# Builder review and release handoff

This is a source implementation handoff, not an independent security review or a signed
attestation. An independent contributor must review the accepted source together with the later
manifest before release. The builder has not deployed contracts, queried a funded wallet, or
claimed live-chain verification of the supplied IMD contract.

## Review conclusions and assumptions

1. **Authority.** Neither deployment target has ownership, pause, mint-after-construction,
   upgrade, delegatecall, arbitrary-call or selfdestruct entry points. `LaunchToken` mints once
   to its constructor caller as required by the factory. `HongbaoBox` never grants authority to
   that caller; only each packet's creator can reveal that packet. Everyone can relay signed
   grabs and trigger due fallback/refund. No manifest owner/signer argument is needed.
2. **Assets and accounting.** The box accepts only its immutable IMD token. Incoming deposits
   must increase its balance by exactly gross. Outgoing transfers must reduce its balance and
   increase the designated recipient by exactly the owed amount. Fees, silent no-ops and
   false returns cannot consume a slot or create/close a packet. SafeERC20 permits no-return
   tokens when balances move exactly. Burn, payout and refund are denominated in 18-decimal
   minor units. The external IMD token is assumed to keep functioning as a nonrebasing ERC-20.
3. **Reentrancy and atomicity.** Every public mutator shares a ReentrancyGuard. All terminal
   state and per-recipient shares are recorded before payout calls. Incoming balance checks
   necessarily bracket a transferFrom before the new escrow entry; the guard covers that
   transient period. No callbacks can claim incoming deposits or unpaid batch amounts as
   surplus. A failure at any payout/refund rolls back all earlier transfers in that transaction.
4. **Liveness.** Equal funds have an expiry refund path; lucky funds have an unconditional
   equal fallback after the grace period. No reveal secret or creator cooperation is needed for
   fallback. Unsolicited IMD above all liabilities is publicly recoverable, with no privileged
   beneficiary and no claim priority for the direct sender. This auxiliary function does not
   change any packet's budget. Third-party assets/native ETH are not accepted or managed.
5. **External token failure.** An IMD pause, receiver blocklist, rebase, confiscation or upgrade
   can prevent transfers and therefore freeze a batch until resolved externally. The specified
   atomic push payout cannot simultaneously guarantee progress under a permanently blocked
   recipient. No admin bypass, substitute recipient or partial-distribution semantics have been
   introduced. The immutable token address and these external risks require independent review.
6. **Signatures.** OpenZeppelin low-s ECDSA recovery checks the EIP-712 digest, packet id,
   recipient, current chain id and deployment address. Used recipients remain marked forever.
   A copied signature only pays the original recipient. Invalid signatures, zero recipients and
   the box itself cannot consume slots. A smart-wallet recipient needs no custom approval.
7. **Randomness.** The creator knows the secret before creation, can simulate allocations and
   can choose reveal versus equal fallback. Passphrase holders can submit Sybil recipients, and
   the Robinhood sequencer orders transactions. Commit/reveal and rejection sampling make
   allocation reproducible, not unbiased or censorship-resistant. This follows the approved
   design, with these trust assumptions explicitly exposed to users.
8. **Limits and rounding.** At most 200 recipients bound every loop. The minimum-reserving
   cap resolves the double-average/minimum-share conflict. The original net amount never
   changes; independent remaining-liability accounting prevents cross-packet leakage. Full-
   precision `mulDiv` supports extreme amounts. All rounding dust goes to a stated recipient
   or the creator, never an unowned remainder.
9. **Terminal states.** Completed, Revealed, Settled and Refunded each admit no further
   mutation. There is no automatic expiry transition. Timestamp deadlines use `block.timestamp`,
   not L2 block numbers. Fallback starts early when a packet fills; overdue reveal and settle
   race until one succeeds. Best luck is first-in-order on ties and absent on equal fallback.

## Evidence delivered

| Tests | Main evidence |
| --- | --- |
| `LaunchToken.t.sol` | Fixed supply, factory mint, metadata, plain transfer, allowance, rejected admin selectors |
| `HongbaoBox.t.sol` | Burn/net accounting, input bounds, minimum after burn, equal payout/refund, lifecycle, surplus isolation |
| `HongbaoSignatures.t.sol` | Independent typed-data encoding, recipient/id/address/chain binding, duplicates and signature malleability |
| `HongbaoLucky.t.sol` | Partial/full/empty reveal and fallback, deadlines, minimum reserves, exact sums, best luck, maximum integers, published draw vector |
| `HongbaoFailures.t.sol` | Fee/bonus/no-op/false/no-return tokens, transfer rollback/retry, blocked recipients, all mutator reentry, surplus during callbacks |
| `HongbaoInvariant.t.sol` | Random mixed-packet histories, independent liabilities, balance/supply conservation, unique recipients, terminal-state preservation, final drainability |
| `LaunchCompatibility.t.sol` | Empty-chain factory-style constructors, preserved launch supply, EIP-170 sizes and forbidden runtime opcodes |

The supplied protected tests are external verification inputs and are not modified or copied into
the build. Their environment-driven deployment checks run in the verifier; the compatibility
test independently exercises the applicable constraints without using environment variables.

Builds and Foundry tests run with the pinned compiler and the assignment's fuzz seed. No live
fork, Slither, Mythril or independent audit is claimed. Local lint flags time comparisons, bounded
external transfers/reverts in loops, and events near external calls; these are intentional lifecycle
and atomic-payout behavior covered by the guard and failure tests. These notes do not suppress
the warnings or establish that no other defects exist.

The 200-recipient reveal regression measures about **11.7 million gas** with the supplied test
token, including exact balance checks and cold-recipient balance writes. It asserts a ceiling of
15 million gas for that measured call. This is a local cost estimate, not a Robinhood block-limit
or production IMD gas guarantee. Deployment services should verify the actual token and available
transaction gas budget before public use; users pay each create/grab in separate transactions.

## Manifest and service responsibilities

- Include `LaunchToken` as the standard token with no constructor arguments; include only
  `HongbaoBox` as the application, with the exact supplied IMD address as its sole address argument.
  The application has no dependency on `$token`, `$owner`, or another application artifact.
- Confirm the token metadata choice: the workflow's final explicit fields say HONGBAO/HONGBAO;
  the narrative/product/domain use IMD Hongbao. The implementation documents this distinction.
- Preserve the pinned compiler/optimizer/EVM/metadata configuration and use the ABI exports
  produced from the same build. No external library linking, initialization calls or native value
  are required. Do not deploy test mocks or the factory probe.
- Generate and independently review `launch.json`, including the policy-supplied pool parameters.
  Source hashes, policy linkage, signed artifacts, attestation, admission and deployment remain
  service responsibilities. Their later results are not prerequisites for this source assignment.
- Verify the live supplied IMD contract, its 18 decimals and transfer behavior; publish source and
  actual deployment addresses; deliver those addresses and the exact pool key to the frontend.
- Ensure the browser implements the documented packed key encoding, EIP-712 fields, separate
  random secret backup, clear minimum/burn display, recipient confirmation and timeout actions.
  No sample key, test recipient or guessed deployment address belongs in the deployment handoff.
