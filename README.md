# IMD Hongbao contracts

An ownerless red-packet application for IMD on Robinhood Chain (chain id **4663**).
This contribution supplies Solidity contracts, tests, ABI exports and the contract integration
handoff. Source publication, independent review, `launch.json`, deployment and the Chinese-first
`imd-hongbao` website are subsequent workflow responsibilities.

- [`src/LaunchToken.sol`](src/LaunchToken.sol): the standard fixed-supply launch token, **HONGBAO**.
- [`src/HongbaoBox.sol`](src/HongbaoBox.sol): equal and lucky packets denominated exclusively in
  the immutable **IMD** token. It has no owner, administrator, pause, upgrade or initialization calls.
- [`docs/INTEGRATION.md`](docs/INTEGRATION.md): exact amounts, timing, signature/key encoding,
  views, events, states and browser responsibilities.
- [`docs/abi/`](docs/abi/): complete compiler-generated ABI arrays for both deployed contracts.
- [`docs/REVIEW.md`](docs/REVIEW.md): builder's security notes and independent-review handoff.

## Build and check

Run at the repository root with Foundry and Solidity **0.8.26** available:

```sh
forge build
forge test --fuzz-seed 0x7671605db5f5d95e927e9bd5e10d79de9f0baa55b6ba2a823655046e469faf5c
forge fmt --check
python3 script/export_abi.py --check
```

`foundry.toml` pins `solc = "0.8.26"`, Paris EVM bytecode, the IR pipeline, optimizer runs 200,
and `bytecode_hash = "none"`. It enables neither FFI nor filesystem permissions. OpenZeppelin
Contracts v5.0.2 (only the transitive source subset) and forge-std v1.9.7 are ordinary files under
`lib/`, with licenses and archive checksums in `lib/DEPENDENCIES.json`. Building/testing uses no
network, environment configuration, forks, keys, submodules or package-install steps. The compiler
is supplied by the verifier, not vendored.

Tests cover success and failure paths, EIP-712 replay across recipients/packets/contracts/chains,
invalid signatures, time boundaries, exact transfers, rollback/retry, blocked recipients and
deferred credits, reentrancy, 200-recipient settlement, arithmetic extremes, lucky distributions,
and stateful fund accounting. The configured campaign uses 512 runs per fuzz test and 128
invariant runs of 96 actions each, with a modelled IMD blocklist among the actions. Invariant
teardown expires every remaining packet and empties escrow through public timeout paths and claims.

After changing interfaces, run `forge build` and `python3 script/export_abi.py` to refresh exports.

## Deployment parameters

Only these two artifacts are deployment targets; test contracts and libraries are not targets.

| Artifact | Constructor arguments | Meaning |
| --- | --- | --- |
| `src/LaunchToken.sol:LaunchToken` | None | Mints `1000000000000000000000000000` units once to its factory caller |
| `src/HongbaoBox.sol:HongbaoBox` | `address imdAddress` = `0x5f7bb59365ce557c26dbcaa4ee9d39a4b95b7127` | Requester-supplied IMD on chain 4663, 18 decimals |

`HongbaoBox` does not depend on the HONGBAO address. Constructors are nonpayable, make no
external calls, and work on an empty chain. IMD code is checked on first `create()` use.
There is no privileged owner argument, backend signer, oracle subscription or unresolved external
configuration. The passphrase signer and reveal commitment are chosen separately for each packet.

The workflow's final explicit token metadata fields say name **HONGBAO**, symbol **HONGBAO**;
these are used for `LaunchToken`. **IMD Hongbao** remains the product name and EIP-712 domain
name, matching the narrative. Both tokens have 18 decimals, but they are separate assets.

The factory retains the entire launch-token supply during construction and distributes it
afterwards. Nothing in this tree decides or records that split: it is the launch policy's. This
launch's assignment terms ("This launch" in the contributor brief) state 10% to the swarm's
MerkleDistributor, 88% to pool liquidity and 2% to the wallet that paid for the launch (or the
chain's treasury when nobody paid); the generic project default would be 80% to the pool with the
rest to the requester's wallet. The manifest and site contributors should take the figures from the
launch terms they are given, not from here. No HONGBAO is reserved for or sent to `HongbaoBox` at
launch. Application funding comes only from later IMD deposits. Factory infrastructure, supply
distribution, guard and pool creation are not reimplemented here.

The manifest contribution uses the supplied IMD pair, pool fee **12500 (1.25%)**, tick spacing
**60**, and policy manifest initial-price value `79228162514264337593543950336`. The deployment
service derives the actual opening price from the policy's 2,500 IMD opening market cap and token
ordering. The packet's 0.5% burn is separate from that pool trading fee; HONGBAO has no transfer tax.
The independent manifest assignment creates `launch.json` after source acceptance.

## Packet economics and lifecycle

The creator approves the **gross** IMD amount to `HongbaoBox` and calls `create()`. The contract
measures the exact amount received, sends `floor(gross / 200)` to the specified
`0x000000000000000000000000000000000000dEaD` sink, and escrows the net remainder. This is an
economic burn by transfer; it does not call IMD's mint/burn machinery or reduce IMD `totalSupply()`.

Named constants fix 1–200 slots, a minimum **0.01 IMD per slot after burn**, durations from 10
minutes through 7 days, and a **24-hour** reveal grace period. Amounts use integer minor units.
`packet(id).amount` is always the original **net** amount, not gross or remaining escrow.

Anyone can relay a passphrase-key signature that names a recipient. Each recipient can grab once
per packet. The recipient gets the IMD regardless of who pays gas. Grabs must arrive strictly
before expiry. Equal packets pay immediately, with the final slot receiving division dust; anyone
can refund the ungrabbed balance to the creator at expiry.

Lucky packets record recipients without paying. The creator can reveal once full or at expiry.
For `g` grabbed slots out of `s`, the payout is `floor(net * g / s)` and the remainder returns to the
creator. Draws use a deterministic double-average range, capped to preserve 0.01 IMD for every
remaining grabber. The last grabber receives the remaining payout. A largest-share tie favors the
first grabber. Revealing an empty packet refunds all net IMD and has no best-luck recipient.

Anyone can call `settle()` after 24 hours from the last grab that filled a lucky packet, or from
expiry if it never filled. Settlement splits the same proportional payout equally among actual
grabbers, gives the final grabber division dust, and refunds the ungrabbed portion. Lost secrets
therefore do not strand packet funds. Reveal remains allowed until a terminal transaction succeeds,
including after the fallback deadline. Terminal states cannot be changed or paid twice.

**The creator can choose between revealing and allowing an equal fallback. Robinhood Chain's
sequencer orders transactions.** This commit/reveal scheme is not unbiased randomness: creators
know their secrets and can model outcomes; passphrase holders can use multiple addresses. **The two
combine: a creator who also holds the passphrase can steer the lucky result.** Shares are a
deterministic function of the secret, the packet id and the ordered grabber list, so before the last
slot fills the creator can evaluate the draw offline for many addresses they control, submit the one
that gives the real grabbers the least (every recipient still gets at least 0.01 IMD), then reveal and
be recorded as best luck. This only affects the creator's own gift and the creator still paid the
0.5% burn, but the site must not present 拼手气 as a fair or verifiable draw: say plainly that the
sender can influence who gets how much. It is the specified lucky-money mechanism, not a lottery
oracle or fairness guarantee.

Every outgoing transfer is checked at both sender and recipient. A token transfer that moves
balances by the wrong amount rolls back the entire operation. A transfer that IMD simply refuses
(a reverting, false-returning or no-op `transfer`, with no balance moving) is handled by path:

- `grab` on an equal packet and `reveal` on a lucky packet stay all-or-nothing. A refused recipient
  makes that call revert; nothing is consumed and the call can be retried or the fallback used.
- `settle` and `refund`, the permissionless fallbacks the liveness guarantee rests on, always reach
  their terminal state. A share or refund IMD refuses to deliver is recorded in `claimable(address)`
  and emitted as `PayoutDeferred`. Credits stay inside `totalEscrow`, so `recoverSurplus()` can
  never take them. `claim(recipient, to)` releases a credit later: anyone may pay it to its
  recipient, and only the recipient may redirect it to another address, which is how an address the
  IMD owner has blocklisted still gets its money out.

The live IMD token is owner-controlled and exposes a recipient blocklist, so a planted or newly
blocked address is a realistic case, not a hypothetical. The contract cannot override an external
token pause, blocklist, confiscation, rebase or malicious upgrade: if IMD refuses the box itself as
sender, or disables transfers globally, every payout waits until the IMD owner lifts that.

## After launch

There are **no owner settings** or initialization transactions. Services publish and attest accepted
source, independently review the source plus manifest, admit and deploy through the factory, and
provide the actual deployment addresses to the frontend. This contribution neither broadcasts
transactions nor supplies placeholder deployment addresses.

The website must read its HongbaoBox/LaunchToken addresses from the deployment handoff, verify
chain 4663 and `imd()`, and use the exact pool key from that handoff if it exposes trading. It must
approve IMD, not HONGBAO. Users need the chain's gas asset; any friend/relayer may submit a signed
grab. There is no relayer fee or compensation built into these contracts.

The browser generates a random packet salt and a separate random 32-byte reveal secret; it stores
the latter locally and shows it once for backup. Never put the reveal secret in a share link or
derive it from the shared passphrase. Keep the passphrase off chain, warn about short/common
phrases, and show reveal, settle and refund actions at the times documented in the integration
guide. The creator submits reveal; anyone may pay gas for due settlement/refund. No keeper is
required for correctness, but users or a volunteer keeper must actually submit those transactions.
When a reveal fails because IMD refuses one recipient, tell the creator that `settle` will pay
everyone else after the grace period. On the result page, show `claimable(address)` for the
connected wallet with a claim button, and explain a `PayoutDeferred` entry as "IMD refused this
address; claim later or redirect to another address".

**Do not transfer IMD directly to the box.** Direct transfers are not packets and cannot identify
an intended beneficiary. `recoverSurplus()` lets anyone recover only the balance above
`totalEscrow`; packet funds and deferred credits are always reserved. The extra recovery path
prevents unassigned IMD from being permanently stranded, but gives the original direct sender no
priority over others. For normal packet operations,
`IMD.balanceOf(box) == totalEscrow == sum(open packet liabilities) + sum(claimable)`; with an
unsolicited transfer the balance includes recoverable surplus until it is collected.

An independent adversarial review remains a release responsibility. Local tests and the builder's
review notes are evidence for that review, not an independent audit or a deployment attestation.
