// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice Ownerless IMD red packets with recipient-bound passphrase-key signatures.
/// @dev Lucky results use creator commit/reveal, not unbiased public randomness: the creator can
/// choose reveal or equal fallback, and the sequencer controls grab ordering. See docs/INTEGRATION.md.
contract HongbaoBox is EIP712, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant MIN_SHARE = 0.01 ether; // IMD has 18 decimals; this is not native ETH.
    uint256 public constant MAX_SLOTS = 200;
    uint256 public constant MIN_DURATION = 10 minutes;
    uint256 public constant MAX_DURATION = 7 days;
    uint256 public constant REVEAL_GRACE = 24 hours;
    uint256 public constant BURN_DENOMINATOR = 200; // floor(gross / 200) = 0.5%.
    address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;
    bytes32 public constant GRAB_TYPEHASH = keccak256("Grab(uint256 id,address recipient)");

    IERC20 public immutable imd;
    uint256 public nextPacketId = 1;
    /// @notice All IMD the box owes: open packets' remaining amounts plus deferred `claimable` credits.
    /// Unsolicited transfers are excluded and recoverable through `recoverSurplus`.
    uint256 public totalEscrow;

    enum State {
        Open,
        Completed,
        Revealed,
        Settled,
        Refunded
    }

    struct Packet {
        address creator;
        uint256 amount; // Net amount AFTER the burn; immutable for the packet's lifetime.
        uint256 slots;
        uint256 grabbed;
        bool lucky;
        uint256 expiry;
        address keyAddress;
        bytes32 salt;
        State state;
    }

    mapping(uint256 => Packet) private _packets;
    mapping(uint256 => address[]) private _grabbers;
    mapping(uint256 => uint256[]) private _shares;
    mapping(uint256 => mapping(address => bool)) public hasGrabbed;
    mapping(uint256 => bytes32) public revealCommitments;
    mapping(uint256 => uint256) public filledAt;
    mapping(uint256 => uint256) public remaining;
    mapping(uint256 => address) public bestLuck;
    /// @notice IMD owed to an address whose settle or refund transfer did not go through
    /// (for example an IMD-side blocklist). Counted in `totalEscrow`; released through `claim`.
    mapping(address => uint256) public claimable;

    error InvalidToken();
    error InvalidSlots();
    error InvalidDuration();
    error InvalidKey();
    error InvalidCommitment();
    error AmountTooSmall();
    error UnknownPacket();
    error PacketClosed();
    error PacketExpired();
    error PacketFull();
    error InvalidRecipient();
    error AlreadyGrabbed();
    error InvalidSignature();
    error NotLucky();
    error NotEqual();
    error NotCreator();
    error NotReady();
    error WrongSecret();
    error TooEarly(uint256 availableAt);
    error InexactTransfer();
    error NoSurplus();
    error NotRecipient();
    error NothingToClaim();

    event PacketCreated(
        uint256 indexed id,
        address indexed creator,
        uint256 grossAmount,
        uint256 amount,
        uint256 burnAmount,
        uint256 slots,
        bool lucky,
        uint256 expiry,
        address keyAddress,
        bytes32 salt,
        bytes32 revealCommit
    );
    event Grabbed(uint256 indexed id, address indexed recipient, uint256 index, uint256 share);
    event Revealed(
        uint256 indexed id, address indexed bestLuckAddress, uint256 bestShare, uint256 payout, uint256 refundAmount
    );
    event Settled(uint256 indexed id, uint256 payout, uint256 refundAmount);
    event Refunded(uint256 indexed id, address indexed creator, uint256 amount);
    event SurplusRecovered(address indexed recipient, uint256 amount);
    event PayoutDeferred(uint256 indexed id, address indexed recipient, uint256 amount);
    event Claimed(address indexed recipient, address indexed to, uint256 amount);

    /// @param imdAddress The launch's supplied IMD address on Robinhood Chain, not LaunchToken.
    /// @dev No external calls or code-presence requirements during factory deployment.
    constructor(address imdAddress) EIP712("IMD Hongbao", "1") {
        if (imdAddress == address(0) || imdAddress == address(this)) revert InvalidToken();
        imd = IERC20(imdAddress);
    }

    /// @notice Pull gross IMD, burn 0.5%, and open a packet with the net amount.
    /// @dev Lucky packets require keccak256(abi.encodePacked(bytes32 secret)); equal packets use zero.
    function create(
        uint256 amount,
        uint256 slots,
        bool lucky,
        address keyAddress,
        bytes32 salt,
        uint256 duration,
        bytes32 revealCommit
    ) external nonReentrant returns (uint256 id) {
        if (slots == 0 || slots > MAX_SLOTS) revert InvalidSlots();
        if (duration < MIN_DURATION || duration > MAX_DURATION) revert InvalidDuration();
        if (keyAddress == address(0)) revert InvalidKey();
        if (lucky ? revealCommit == bytes32(0) : revealCommit != bytes32(0)) revert InvalidCommitment();
        uint256 burnAmount = amount / BURN_DENOMINATOR;
        uint256 net = amount - burnAmount;
        if (net < slots * MIN_SHARE) revert AmountTooSmall();
        if (address(imd).code.length == 0) revert InvalidToken();

        uint256 beforeBalance = imd.balanceOf(address(this));
        imd.safeTransferFrom(msg.sender, address(this), amount);
        uint256 afterBalance = imd.balanceOf(address(this));
        if (afterBalance < beforeBalance || afterBalance - beforeBalance != amount) revert InexactTransfer();

        id = nextPacketId++;
        uint256 expiry = block.timestamp + duration;
        _packets[id] = Packet(msg.sender, net, slots, 0, lucky, expiry, keyAddress, salt, State.Open);
        remaining[id] = net;
        revealCommitments[id] = revealCommit;
        totalEscrow += net;
        _pay(BURN_ADDRESS, burnAmount);
        emit PacketCreated(
            id, msg.sender, amount, net, burnAmount, slots, lucky, expiry, keyAddress, salt, revealCommit
        );
    }

    /// @notice Anyone can relay a key signature, but only its signed recipient receives the share.
    function grab(uint256 id, address recipient, bytes calldata signature) external nonReentrant {
        Packet storage p = _openPacket(id);
        if (block.timestamp >= p.expiry) revert PacketExpired();
        if (p.grabbed == p.slots) revert PacketFull();
        if (recipient == address(0) || recipient == address(this)) revert InvalidRecipient();
        if (hasGrabbed[id][recipient]) revert AlreadyGrabbed();
        (address signer, ECDSA.RecoverError err,) = ECDSA.tryRecover(grabDigest(id, recipient), signature);
        if (err != ECDSA.RecoverError.NoError || signer != p.keyAddress) revert InvalidSignature();

        hasGrabbed[id][recipient] = true;
        uint256 index = p.grabbed++;
        _grabbers[id].push(recipient);
        if (p.grabbed == p.slots) filledAt[id] = block.timestamp;

        uint256 share = 0;
        if (!p.lucky) {
            share = p.grabbed == p.slots ? remaining[id] : p.amount / p.slots;
            remaining[id] -= share;
            totalEscrow -= share;
            if (p.grabbed == p.slots) p.state = State.Completed;
        }
        _shares[id].push(share);
        emit Grabbed(id, recipient, index, share);
        if (share != 0) _pay(recipient, share);
    }

    /// @notice Creator opens a full or expired lucky packet and atomically pays all recorded grabbers.
    /// @dev A reveal remains possible after the grace period until a settle transaction wins the race.
    /// If IMD refuses any recipient the reveal reverts; `settle` then pays the rest and credits that one.
    function reveal(uint256 id, bytes32 secret) external nonReentrant {
        Packet storage p = _openPacket(id);
        if (!p.lucky) revert NotLucky();
        if (msg.sender != p.creator) revert NotCreator();
        if (p.grabbed != p.slots && block.timestamp < p.expiry) revert NotReady();
        if (keccak256(abi.encodePacked(secret)) != revealCommitments[id]) revert WrongSecret();
        bytes32 seed = keccak256(abi.encode(secret, id, _grabbers[id]));
        _finishLucky(id, p, true, seed);
    }

    /// @notice After 24 hours from filling or expiry, anyone can trigger an equal fallback payout.
    /// @dev Never blocked by one recipient: a share IMD refuses to deliver is credited in `claimable`.
    function settle(uint256 id) external nonReentrant {
        Packet storage p = _openPacket(id);
        if (!p.lucky) revert NotLucky();
        uint256 availableAt = (p.grabbed == p.slots ? filledAt[id] : p.expiry) + REVEAL_GRACE;
        if (block.timestamp < availableAt) revert TooEarly(availableAt);
        _finishLucky(id, p, false, bytes32(0));
    }

    /// @notice After expiry, anyone can return an equal packet's unpaid amount to its creator.
    /// @dev Always reaches the terminal state: a refund IMD refuses to deliver is credited in `claimable`.
    function refund(uint256 id) external nonReentrant {
        Packet storage p = _openPacket(id);
        if (p.lucky) revert NotEqual();
        if (block.timestamp < p.expiry) revert TooEarly(p.expiry);
        uint256 amount = remaining[id];
        remaining[id] = 0;
        totalEscrow -= amount;
        p.state = State.Refunded;
        emit Refunded(id, p.creator, amount);
        _payOrCredit(id, p.creator, amount);
    }

    /// @notice Release a deferred credit. Anyone may pay it out to its recipient; only the recipient
    /// may redirect it to another address, for example when IMD refuses transfers to the original one.
    function claim(address recipient, address to) external nonReentrant returns (uint256 amount) {
        if (to == address(0) || to == address(this)) revert InvalidRecipient();
        if (msg.sender != recipient && to != recipient) revert NotRecipient();
        amount = claimable[recipient];
        if (amount == 0) revert NothingToClaim();
        claimable[recipient] = 0;
        totalEscrow -= amount;
        emit Claimed(recipient, to, amount);
        _pay(to, amount);
    }

    /// @notice Return the specified nine packet fields. Reverts for an unknown id.
    function packet(uint256 id) external view returns (Packet memory) {
        return _knownPacket(id);
    }

    /// @notice Grab order and final shares; lucky shares remain zero until reveal or settle succeeds.
    function grabbers(uint256 id) external view returns (address[] memory recipients, uint256[] memory shares) {
        _knownPacket(id);
        return (_grabbers[id], _shares[id]);
    }

    /// @notice EIP-712 digest for the current chain id and this deployment.
    function grabDigest(uint256 id, address recipient) public view returns (bytes32) {
        return _hashTypedDataV4(keccak256(abi.encode(GRAB_TYPEHASH, id, recipient)));
    }

    function DOMAIN_SEPARATOR() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    /// @notice Earliest equal fallback time; filling early starts the grace period early.
    function settlementTime(uint256 id) external view returns (uint256) {
        Packet storage p = _knownPacket(id);
        if (!p.lucky) revert NotLucky();
        return (p.grabbed == p.slots ? filledAt[id] : p.expiry) + REVEAL_GRACE;
    }

    /// @notice Unsolicited IMD is unassigned and recoverable by anyone. Never send IMD directly.
    /// @dev This avoids stranded IMD without giving anyone power over packet funds.
    function recoverSurplus() external nonReentrant returns (uint256 amount) {
        uint256 balance = imd.balanceOf(address(this));
        if (balance <= totalEscrow) revert NoSurplus();
        amount = balance - totalEscrow;
        emit SurplusRecovered(msg.sender, amount);
        _pay(msg.sender, amount);
    }

    function _finishLucky(uint256 id, Packet storage p, bool randomize, bytes32 seed) private {
        uint256 count = p.grabbed;
        // Full precision: p.amount * count may overflow even when the quotient fits.
        uint256 payout = Math.mulDiv(p.amount, count, p.slots);
        uint256 refundAmount = p.amount - payout;
        uint256 rest = payout;
        uint256 largest = 0;
        address winner = address(0);

        p.state = randomize ? State.Revealed : State.Settled;
        totalEscrow -= remaining[id];
        remaining[id] = 0;
        // Record every share before the first external interaction.
        for (uint256 i; i < count; ++i) {
            uint256 left = count - i;
            uint256 share;
            if (left == 1) {
                share = rest;
            } else if (randomize) {
                uint256 upper = Math.min(Math.mulDiv(rest, 2, left), rest - MIN_SHARE * (left - 1));
                share = MIN_SHARE + _uniform(seed, i, upper - MIN_SHARE + 1);
            } else {
                share = payout / count;
            }
            rest -= share;
            _shares[id][i] = share;
            if (share > largest) {
                largest = share;
                winner = _grabbers[id][i];
            }
        }

        if (randomize) {
            bestLuck[id] = winner; // No grabbers means no winner; ties favor the first grabber.
            emit Revealed(id, winner, largest, payout, refundAmount);
        } else {
            emit Settled(id, payout, refundAmount);
        }
        // Reveal keeps the brief's all-or-nothing payout: a lucky result is never partially paid.
        // Settle is the permissionless fallback, so it must finish even if IMD refuses a recipient.
        for (uint256 i; i < count; ++i) {
            if (randomize) _pay(_grabbers[id][i], _shares[id][i]);
            else _payOrCredit(id, _grabbers[id][i], _shares[id][i]);
        }
        if (randomize) {
            if (refundAmount != 0) _pay(p.creator, refundAmount);
        } else {
            _payOrCredit(id, p.creator, refundAmount);
        }
    }

    /// @dev Rejection sampling avoids modulo bias in the inclusive draw range. Hash inputs are
    /// abi.encode(seed, grabberIndex, attempt), starting at attempt zero. No block data is used.
    function _uniform(bytes32 seed, uint256 index, uint256 range) private pure returns (uint256) {
        uint256 threshold;
        unchecked {
            threshold = (0 - range) % range;
        }
        uint256 attempt = 0;
        uint256 word = uint256(keccak256(abi.encode(seed, index, attempt)));
        while (word < threshold) {
            word = uint256(keccak256(abi.encode(seed, index, ++attempt)));
        }
        return word % range;
    }

    /// @dev Protect both escrow and recipients from fees, silent no-ops, or sender-side surcharges.
    /// Reverts roll back the whole operation. Used where a single recipient is being paid.
    function _pay(address recipient, uint256 amount) private {
        uint256 beforeBox = imd.balanceOf(address(this));
        uint256 beforeRecipient = imd.balanceOf(recipient);
        imd.safeTransfer(recipient, amount);
        uint256 afterBox = imd.balanceOf(address(this));
        uint256 afterRecipient = imd.balanceOf(recipient);
        if (!_exact(beforeBox, afterBox, beforeRecipient, afterRecipient, amount)) revert InexactTransfer();
    }

    /// @dev Best-effort payout for the permissionless fallbacks. A transfer IMD refuses (revert, false
    /// return or silent no-op, with no balance moving) becomes a `claimable` credit that stays inside
    /// `totalEscrow`, so one unreachable recipient cannot strand the others or the creator. A
    /// transfer that moves balances inexactly still reverts the whole batch, as before.
    function _payOrCredit(uint256 id, address recipient, uint256 amount) private {
        if (amount == 0) return;
        uint256 beforeBox = imd.balanceOf(address(this));
        uint256 beforeRecipient = imd.balanceOf(recipient);
        (bool ok, bytes memory data) = address(imd).call(abi.encodeCall(IERC20.transfer, (recipient, amount)));
        bool returnedTrue = ok && (data.length == 0 || (data.length >= 32 && abi.decode(data, (uint256)) == 1));
        uint256 afterBox = imd.balanceOf(address(this));
        uint256 afterRecipient = imd.balanceOf(recipient);
        if (returnedTrue && _exact(beforeBox, afterBox, beforeRecipient, afterRecipient, amount)) return;
        if (afterBox != beforeBox || afterRecipient != beforeRecipient) revert InexactTransfer();
        claimable[recipient] += amount;
        totalEscrow += amount;
        emit PayoutDeferred(id, recipient, amount);
    }

    function _exact(
        uint256 beforeBox,
        uint256 afterBox,
        uint256 beforeRecipient,
        uint256 afterRecipient,
        uint256 amount
    ) private pure returns (bool) {
        return afterBox <= beforeBox && beforeBox - afterBox == amount && afterRecipient >= beforeRecipient
            && afterRecipient - beforeRecipient == amount;
    }

    function _knownPacket(uint256 id) private view returns (Packet storage p) {
        p = _packets[id];
        if (p.creator == address(0)) revert UnknownPacket();
    }

    function _openPacket(uint256 id) private view returns (Packet storage p) {
        p = _knownPacket(id);
        if (p.state != State.Open) revert PacketClosed();
    }
}
