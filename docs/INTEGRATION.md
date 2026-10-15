# HongbaoBox ABI and integration

`abi/HongbaoBox.json` and `abi/LaunchToken.json` are the canonical ABI arrays exported from
Solidity 0.8.26 artifacts. Their corresponding Solidity source names are the deployment identifiers.
No calls accept native ETH. Application amounts are 18-decimal IMD minor units.

## Calls

| Call | Caller and result |
| --- | --- |
| `create(uint256 amount,uint256 slots,bool lucky,address keyAddress,bytes32 salt,uint256 duration,bytes32 revealCommit) returns (uint256 id)` | Creator approves/pays gross IMD; returns the next id, beginning at 1 |
| `grab(uint256 id,address recipient,bytes signature)` | Anyone relays a 65-byte ECDSA signature; pays only its recipient for an equal packet |
| `reveal(uint256 id,bytes32 secret)` | Packet creator only; full or expired lucky packet; pays all grabbers and refunds remainder atomically, reverting if IMD refuses any of them |
| `settle(uint256 id)` | Anyone; open lucky packet at or after `settlementTime(id)`; equal fallback; a refused recipient is credited, never blocking |
| `refund(uint256 id)` | Anyone; open equal packet at or after expiry; remainder goes to creator, or is credited if IMD refuses the creator |
| `claim(address recipient,address to) returns (uint256 amount)` | Pays `claimable(recipient)` to `to`; anyone when `to == recipient`, only `recipient` otherwise |
| `recoverSurplus() returns (uint256 amount)` | Anyone; transfers only unsolicited IMD above `totalEscrow` to the caller |

`create` requires `net = amount - floor(amount / 200) >= slots * 10^16`.
For a target net `n > 0`, the smallest sufficient gross is `n + floor((n - 1) / 199)`.
Use a nonzero passphrase-derived `keyAddress`. Salts need not be unique on chain, but the browser
should generate a fresh cryptographically random `bytes32` salt for each packet. Equal packets
must supply zero `revealCommit`; lucky packets must supply a nonzero commitment. Duration is
seconds, inclusive bounds `[600, 604800]`. Zero and the box itself are invalid grab recipients.
An ordinary contract address can be a recipient without receiving a callback from HongbaoBox.

`revealCommit = keccak256(secretBytes)`, where `secretBytes` is exactly 32 random bytes.
Equivalently in Solidity: `keccak256(abi.encodePacked(bytes32(secret)))`.
Do not hash the UTF-8 representation of a hex string. A bytes32 all-zero secret would still have a
valid nonzero commitment, but browser software must use cryptographic randomness.

## Passphrase key derivation

Use this precise browser-side encoding consistently when creating and grabbing:

1. Concatenate UTF-8 bytes of `imd-hongbao`, the chain id as a **32-byte unsigned big-endian
   integer**, the HongbaoBox address as **20 raw bytes**, the **32 raw salt bytes**, then the
   passphrase as UTF-8 bytes. This is Solidity packed encoding of
   `(string,uint256,address,bytes32,string)`.
2. Hash with Ethereum Keccak-256. Interpret the digest as an unsigned big-endian integer `h`.
3. Use `privateKey = (h mod (N - 1)) + 1`, where
   `N = 0xfffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141` is the secp256k1
   curve order. Encode the resulting scalar as 32 bytes.
4. Obtain the Ethereum address from the derived secp256k1 public key. Store this as `keyAddress`.

These choices resolve the brief's unspecified scalar-reduction and binary-encoding details.
Do not trim, lowercase or silently normalize the passphrase: use exactly the UTF-8 text the
creator shared. If a UI offers normalization, it must do it explicitly before creation and share
that same text. Always compare the locally derived address with `packet(id).keyAddress` before
signing. These temporary derived keys should never be funded or reused as personal wallets.

The published salt and key address allow **offline passphrase guessing**. A passphrase shared
with anyone also authorizes them to sign for arbitrary new recipient addresses. One grab per
recipient prevents replay, not Sybil participation. Strong passphrases and application warnings
are essential; the on-chain signature cannot enforce one human per packet.

## EIP-712 signing

```text
domain:
  name: "IMD Hongbao"
  version: "1"
  chainId: connected chain id (4663 for this launch)
  verifyingContract: deployed HongbaoBox address

primaryType: "Grab"
types.Grab:
  - { name: "id", type: "uint256" }
  - { name: "recipient", type: "address" }
message:
  id: packet id
  recipient: connected wallet or explicitly pasted recipient
```

The exact type hash is `keccak256("Grab(uint256 id,address recipient)")`, with no spaces after
the comma. The signature is `r || s || v`, 65 bytes, with low `s` and `v` 27 or 28. EIP-2098
compact signatures, `personal_sign` signatures and contract-wallet EIP-1271 signatures are not
used: the signing key is the browser-derived EOA. The recipient may itself be a smart wallet.

`grabDigest(id, recipient)` returns the final EIP-712 digest. `DOMAIN_SEPARATOR()` and the
inherited `eip712Domain()` are available for integration validation. The domain incorporates the
live chain id; it is rebuilt on a chain-id change. The signed id prevents cross-packet replay,
`hasGrabbed` prevents recipient reuse, and expiry/terminal-state checks limit validity. Anyone
copying a transaction may get it mined sooner but cannot redirect the payout.

The passphrase and private key stay in browser memory. A share link contains only `#/p/<id>`;
the copy-ready share message supplies the passphrase separately. The reveal secret must remain
separate even from the shared passphrase and its derived signing key.

## Views and time boundaries

`packet(id)` returns a struct (ABI tuple) with these fields **in this order**:

| Field | Solidity type | Meaning |
| --- | --- | --- |
| `creator` | `address` | Creator and refund beneficiary |
| `amount` | `uint256` | Original net packet amount after burn |
| `slots` | `uint256` | Original capacity, 1–200 |
| `grabbed` | `uint256` | Recorded recipient count |
| `lucky` | `bool` | Lucky versus immediate equal payout |
| `expiry` | `uint256` | Unix timestamp in seconds |
| `keyAddress` | `address` | ECDSA signer derived from the passphrase |
| `salt` | `bytes32` | Public per-packet key-derivation salt |
| `state` | `uint8` | Enum value below |

| State | Value | Transition from Open |
| --- | --- | --- |
| `Open` | 0 | Created; may already be full/expired while awaiting terminal action |
| `Completed` | 1 | Final equal grab paid |
| `Revealed` | 2 | Lucky creator reveal and all transfers succeeded |
| `Settled` | 3 | Lucky equal fallback; every share paid, or credited in `claimable` where IMD refused |
| `Refunded` | 4 | Expired equal packet's remainder returned to the creator, or credited where IMD refused |

Unknown ids revert from `packet`, `grabbers`, `settlementTime`, and packet-mutating calls. A
default-zero mapping value does not prove a packet exists. All terminal transitions are final.
There is no automatic transaction at expiry and no separate `Expired` state.

Other views:

- `grabbers(id)` returns parallel `address[] recipients, uint256[] shares` in grab order. Lucky
  shares stay zero while Open, including after a reverted reveal. Equal shares are immediately final.
- `hasGrabbed(id, recipient)` records duplicate prevention; a failed transaction does not set it.
- `remaining(id)` is a packet's unpaid liability, zero after a terminal state.
- `claimable(address)` is IMD a settle or refund could not deliver to that address. It is released
  by `claim`, never by `recoverSurplus`.
- `totalEscrow()` is the sum of all remaining liabilities plus all `claimable` credits, not the raw
  token balance.
- `filledAt(id)` is the timestamp of the final grab, or zero before filling.
- `settlementTime(id)` is `filledAt + 86400` if full, otherwise `expiry + 86400`, for lucky
  packets. It can move earlier when the final slot is grabbed. It does not imply the packet is Open.
- `revealCommitments(id)` returns the stored commitment; equal packets store zero.
- `bestLuck(id)` returns the winning address after reveal; it is zero for no grabbers, fallback,
  equal packets, and unrevealed packets. The first recipient wins a tied largest share.
- `imd()`, `nextPacketId()` and the named public constants support display and validation.

Grabs require `now < expiry`. Refund and expiry-based reveal permit `now >= expiry`.
Fallback permits `now >= settlementTime`. Filling early enables immediate reveal and starts
the fallback clock at the final grab, without waiting for expiry. After the grace period the
creator can still reveal if `settle` has not succeeded; transaction ordering determines which
terminal action executes. Frontends must refresh state after submitting or observing another action.

## Lucky allocation algorithm

For net `A`, original slots `s`, actual grabbers `g`, allocate `P = floor(A * g / s)` and refund
`A - P`. This computation uses full-precision multiplication/division. If `g == 0`, skip all
draws and refund `A`. Otherwise:

```text
seed = keccak256(abi.encode(secretBytes32, idUint256, grabbersAddressArray))
remaining = P
for i in [0, g):
    left = g - i
    if left == 1:
        share = remaining
    else:
        upper = min(floor(2 * remaining / left), remaining - 10^16 * (left - 1))
        range = upper - 10^16 + 1
        threshold = (2^256) mod range
        attempt = 0
        word = uint256(keccak256(abi.encode(seedBytes32, iUint256, attemptUint256)))
        while word < threshold:
            attempt += 1
            word = uint256(keccak256(abi.encode(seedBytes32, iUint256, attemptUint256)))
        share = 10^16 + word mod range
    remaining -= share
```

The seed uses standard ABI encoding (including the address-array offset and length), **not packed
encoding**. Rejection sampling removes integer-modulo bias under the hash-randomness model.
This does not remove creator choice, knowledge of the secret, or ordering influence. In particular
the creator, who knows the secret and the passphrase, can grind the last grabber address: evaluate
this algorithm offline for many addresses of their own and submit the one that minimises the real
grabbers' shares before revealing. The site copy and result page must not describe the lucky split as
fair or unbiased; present it as the sender's draw.

## Deferred payouts

`reveal` and an equal `grab` are all-or-nothing: if IMD refuses one recipient's transfer, the whole
call reverts and nothing is recorded. `settle` and `refund` must always finish, so there each
transfer is attempted and, if IMD refuses it (the `transfer` call reverts, returns false or moves
nothing), the amount is added to `claimable(recipient)` and `PayoutDeferred(id, recipient, amount)`
is emitted after the `Settled` or `Refunded` event. The packet is terminal and `grabbers(id)`
shows the credited share like any other. A transfer that moves balances by the wrong amount is a
broken token, not a refusal, and still reverts the whole call with `InexactTransfer`.

`claim(recipient, to)` releases a credit. With `to == recipient` anyone may call it (a friend can
pay the gas, the IMD only reaches the recipient). With a different `to` the caller must be the
recipient, which lets an address the IMD owner blocklisted move its credit to another address. It
reverts with `NothingToClaim` when the credit is zero, `NotRecipient` for a third party redirecting,
`InvalidRecipient` for a zero or box destination, and with the IMD error if IMD still refuses `to`;
a failed claim keeps the credit. Credits are counted in `totalEscrow`, so `recoverSurplus` cannot
touch them.

For the frontend: after `Settled`/`Refunded`, read `claimable` for the connected wallet (and the
creator) and offer a claim button when it is nonzero. A reveal that fails with the IMD blocklist
error means one recipient is refused; the creator should wait for `settlementTime(id)` and anyone
can then `settle`.

The reserve cap is necessary to satisfy the minimum: drawing from an uncapped double-average
range could give all of a 0.02 IMD two-slot packet to the first recipient and leave the last with
zero. The implemented inclusive range preserves the requested 0.01 IMD minimum for every
recipient. Payout plus refund equals net exactly; the last share takes any remainder.

For fallback, all but the final actual grabber receive `floor(P / g)` and the final grabber gets
the remaining payout. Best luck is recorded only for reveal, not fallback.

The regression vector below uses **test-only inputs**, not any deployment key or address:

```text
secret: 0x2dbfcf76fa35fc4acad2ed1c0b4af5ee5fa41be91e0b9c08498035dd960d7cb2
id: 1
grabbers: [0x0000000000000000000000000000000000001000,
           0x0000000000000000000000000000000000001001,
           0x0000000000000000000000000000000000001002]
gross: 1000000000000000000
net:    995000000000000000
seed: 0xa0c443f753eaf2bc2a47cfd08e25b6312f7fe987904c24a357f8f87f9888c9fc
shares: [70586284642358507, 548424350498568867, 375989364859072626]
bestLuck: second grabber
```

## Events and errors

All events are in the ABI, including their indexed fields. Application events are:

| Event | Interpretation |
| --- | --- |
| `PacketCreated` | Indexed id/creator; gross, net (`amount`), burn, slots, mode, expiry, key, salt and commitment |
| `Grabbed` | Indexed id/recipient; zero-based grab index and immediate share (zero for lucky) |
| `Revealed` | Indexed id/best-luck address; best share, total payout and creator refund |
| `Settled` | Indexed id; total fallback payout and creator refund |
| `Refunded` | Indexed id/creator; expired equal packet refund |
| `SurplusRecovered` | Indexed caller/recipient and unassigned amount recovered |
| `PayoutDeferred` | Indexed id/recipient; amount a settle or refund could not deliver, now in `claimable` |
| `Claimed` | Indexed recipient/destination; credit released by `claim` |

For lucky allocations, refetch `grabbers(id)` after `Revealed` or `Settled` to obtain final shares.
`Refunded` is the equal-packet terminal event; lucky refunds are included in `Revealed`/`Settled`.
`Grabbed` for the final equal slot implies `Completed`. Failed transactions retain no logs.
`PayoutDeferred` follows `Settled` or `Refunded` in the same transaction, one per refused address.

User-facing error groups:

- Invalid creation: `InvalidToken`, `InvalidSlots`, `InvalidDuration`, `InvalidKey`,
  `InvalidCommitment`, `AmountTooSmall`.
- Claim failures: `UnknownPacket`, `PacketClosed`, `PacketExpired`, `PacketFull`,
  `InvalidRecipient`, `AlreadyGrabbed`, `InvalidSignature`.
- Lifecycle failures: `NotLucky`, `NotEqual`, `NotCreator`, `NotReady`, `WrongSecret`,
  `TooEarly(availableAt)`.
- Asset failures: `InexactTransfer`, `NoSurplus`, underlying ERC-20 errors, or SafeERC20 errors.
- Claim failures: `NothingToClaim`, `NotRecipient`, `InvalidRecipient`.
- A reentrant state change fails with OpenZeppelin `ReentrancyGuardReentrantCall`.

`PacketClosed` takes precedence over mode/timing errors on terminal packets. Recovery UI should
not retry blindly: refresh packet state, chain and IMD approval/balance, then interpret the error.
