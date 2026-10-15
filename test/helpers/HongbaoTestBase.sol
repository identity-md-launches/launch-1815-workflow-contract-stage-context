// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {HongbaoBox} from "../../src/HongbaoBox.sol";
import {MockIMD} from "./MockIMD.sol";

abstract contract HongbaoTestBase is Test {
    MockIMD internal imd;
    HongbaoBox internal box;
    address internal creator;
    address internal alice;
    address internal bob;
    address internal carol;
    address internal relayer;
    address internal keyAddress;
    uint256 internal key;
    bytes32 internal constant SECRET = keccak256("test-only reveal secret");
    bytes32 internal constant SALT = keccak256("test-only salt");
    uint256 internal constant MIN = 1e16;

    function setUp() public virtual {
        vm.chainId(4663);
        vm.warp(1_000_000);
        creator = makeAddr("creator");
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        carol = makeAddr("carol");
        relayer = makeAddr("relayer");
        (keyAddress, key) = makeAddrAndKey("passphrase key for tests only");
        imd = new MockIMD();
        box = new HongbaoBox(address(imd));
        imd.mint(creator, 1_000_000 ether);
        vm.prank(creator);
        imd.approve(address(box), type(uint256).max);
    }

    function _create(uint256 gross, uint256 slots, bool lucky) internal returns (uint256 id) {
        return _createWith(box, gross, slots, lucky, 10 minutes, SECRET);
    }

    function _createWith(HongbaoBox target, uint256 gross, uint256 slots, bool lucky, uint256 duration, bytes32 secret)
        internal
        returns (uint256 id)
    {
        vm.prank(creator);
        id = target.create(
            gross, slots, lucky, keyAddress, SALT, duration, lucky ? keccak256(abi.encodePacked(secret)) : bytes32(0)
        );
    }

    /// @dev Build the typed data independently of HongbaoBox.grabDigest to catch encoding mistakes.
    function _digest(HongbaoBox target, uint256 chainId, uint256 id, address recipient)
        internal
        pure
        returns (bytes32)
    {
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("IMD Hongbao"),
                keccak256("1"),
                chainId,
                address(target)
            )
        );
        bytes32 structHash = keccak256(abi.encode(keccak256("Grab(uint256 id,address recipient)"), id, recipient));
        return keccak256(abi.encodePacked(hex"1901", domain, structHash));
    }

    function _sign(HongbaoBox target, uint256 id, address recipient) internal view returns (bytes memory) {
        // External read avoids optimizer reuse of block.chainid across the test's vm.chainId calls.
        (,,, uint256 chainId,,,) = target.eip712Domain();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, _digest(target, chainId, id, recipient));
        return abi.encodePacked(r, s, v);
    }

    function _grab(uint256 id, address recipient) internal {
        bytes memory signature = _sign(box, id, recipient);
        vm.prank(relayer);
        box.grab(id, recipient, signature);
    }

    function _reveal(uint256 id) internal {
        vm.prank(creator);
        box.reveal(id, SECRET);
    }

    function _grossForNet(uint256 net) internal pure returns (uint256) {
        return net + (net - 1) / 199;
    }

    function _assertAccounting() internal view {
        uint256 sum;
        for (uint256 id = 1; id < box.nextPacketId(); ++id) {
            HongbaoBox.Packet memory p = box.packet(id);
            uint256 owed;
            if (p.state == HongbaoBox.State.Open) {
                owed = p.lucky ? p.amount : p.amount - (p.amount / p.slots) * p.grabbed;
            }
            assertEq(box.remaining(id), owed, "per packet liability");
            sum += owed;
        }
        sum += _claimableSum();
        assertEq(box.totalEscrow(), sum, "global liability");
        assertEq(imd.balanceOf(address(box)), sum, "balance equals liabilities");
    }

    /// @dev Deferred credits of every actor these tests pay; the box owes them like open packets.
    function _claimableSum() internal view returns (uint256) {
        return box.claimable(creator) + box.claimable(alice) + box.claimable(bob) + box.claimable(carol)
            + box.claimable(relayer);
    }
}
