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
invalid signatures, time boundaries, exact transfers, rollback/retry, reentrancy, 200-recipient
settlement, arithmetic extremes, lucky distributions, and stateful fund accounting. The configured
campaign uses 512 runs per fuzz test and 128 invariant runs of 96 actions each. Invariant teardown
expires every remaining packet and empties escrow through public timeout paths.

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

The factory retains the entire launch-token supply during construction and subsequently distributes
10% to its MerkleDistributor, 88% to pool liquidity and 2% to the paying wallet (or the policy's
treasury fallback). No HONGBAO is reserved for or sent to `HongbaoBox` at launch. Application
funding comes only from later IMD deposits. Factory infrastructure, supply distribution, guard and
pool creation are not reimplemented here.

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
know their secrets and can model outcomes; passphrase holders can use multiple addresses. It is
the specified lucky-money mechanism, not a lottery oracle or fairness guarantee.

Every outgoing transfer is checked at both sender and recipient. A failed token transfer rolls
back the entire operation, including earlier recipients in a lucky batch. Recovery requires a
retry when IMD permits the transfer. The contract cannot override an external token pause,
blocklist, confiscation, rebase or malicious upgrade.

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

**Do not transfer IMD directly to the box.** Direct transfers are not packets and cannot identify
an intended beneficiary. `recoverSurplus()` lets anyone recover only the balance above
`totalEscrow`; packet funds are always reserved. The extra recovery path prevents unassigned IMD
from being permanently stranded, but gives the original direct sender no priority over others.
For normal packet operations, `IMD.balanceOf(box) == totalEscrow == sum(open packet liabilities)`;
with an unsolicited transfer the balance includes recoverable surplus until it is collected.

An independent adversarial review remains a release responsibility. Local tests and the builder's
review notes are evidence for that review, not an independent audit or a deployment attestation.
