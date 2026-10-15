// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HongbaoTestBase} from "./helpers/HongbaoTestBase.sol";
import {HongbaoBox} from "../src/HongbaoBox.sol";

contract HongbaoSignaturesTest is HongbaoTestBase {
    function testDigestMatchesIndependentTypedDataEncoding() public view {
        assertEq(box.grabDigest(41, alice), _digest(box, 4663, 41, alice));
    }

    function testRecipientBindingAndCopiedSignatureOnlyPaysOriginalRecipient() public {
        uint256 id = _create(1 ether, 3, false);
        bytes memory sig = _sign(box, id, alice);
        vm.expectRevert(HongbaoBox.InvalidSignature.selector);
        vm.prank(bob);
        box.grab(id, bob, sig);
        vm.prank(bob);
        box.grab(id, alice, sig);
        assertGt(imd.balanceOf(alice), 0);
        assertEq(imd.balanceOf(bob), 0);
        vm.expectRevert(HongbaoBox.AlreadyGrabbed.selector);
        box.grab(id, alice, sig);
        _assertAccounting();
    }

    function testSignatureCannotReplayAcrossPacketsEvenWithSameKeyAndSalt() public {
        uint256 first = _create(1 ether, 3, true);
        uint256 second = _create(1 ether, 3, true);
        bytes memory sig = _sign(box, first, alice);
        vm.expectRevert(HongbaoBox.InvalidSignature.selector);
        box.grab(second, alice, sig);
        box.grab(first, alice, sig);
        _grab(second, alice);
        assertTrue(box.hasGrabbed(first, alice));
        assertTrue(box.hasGrabbed(second, alice));
    }

    function testSignatureCannotReplayAcrossContractsWithSamePacketId() public {
        uint256 id = _create(1 ether, 3, false);
        HongbaoBox other = new HongbaoBox(address(imd));
        vm.prank(creator);
        imd.approve(address(other), 1 ether);
        assertEq(_createWith(other, 1 ether, 3, false, 10 minutes, SECRET), id);
        bytes memory sig = _sign(box, id, alice);
        vm.expectRevert(HongbaoBox.InvalidSignature.selector);
        other.grab(id, alice, sig);
        other.grab(id, alice, _sign(other, id, alice));
        box.grab(id, alice, sig);
        assertEq(imd.balanceOf(alice), 2 * (box.packet(id).amount / 3));
    }

    function testSignatureCannotReplayAcrossChainsAndDomainUpdatesAfterFork() public {
        uint256 id = _create(1 ether, 3, false);
        bytes memory sig = _sign(box, id, alice);
        bytes32 originalDomain = box.DOMAIN_SEPARATOR();
        vm.chainId(4664);
        assertNotEq(box.DOMAIN_SEPARATOR(), originalDomain);
        assertEq(box.grabDigest(id, alice), _digest(box, 4664, id, alice));
        vm.expectRevert(HongbaoBox.InvalidSignature.selector);
        box.grab(id, alice, sig);
        _grab(id, alice);
        vm.chainId(4663);
        assertEq(box.DOMAIN_SEPARATOR(), originalDomain);
        vm.expectRevert(HongbaoBox.AlreadyGrabbed.selector);
        box.grab(id, alice, sig);
    }

    function testWrongKeyMalformedAndMalleableSignaturesFail() public {
        uint256 id = _create(1 ether, 3, true);
        (, uint256 wrongKey) = makeAddrAndKey("wrong key");
        bytes32 digest = _digest(box, 4663, id, alice);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(wrongKey, digest);
        vm.expectRevert(HongbaoBox.InvalidSignature.selector);
        box.grab(id, alice, abi.encodePacked(r, s, v));
        vm.expectRevert(HongbaoBox.InvalidSignature.selector);
        box.grab(id, alice, "");
        vm.expectRevert(HongbaoBox.InvalidSignature.selector);
        box.grab(id, alice, new bytes(65));
        (v, r, s) = vm.sign(key, digest);
        vm.expectRevert(HongbaoBox.InvalidSignature.selector);
        box.grab(id, alice, abi.encodePacked(r, s, uint8(1)));
        uint256 curveOrder = 0xfffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141;
        bytes32 highS = bytes32(curveOrder - uint256(s));
        vm.expectRevert(HongbaoBox.InvalidSignature.selector);
        box.grab(id, alice, abi.encodePacked(r, highS, v == 27 ? uint8(28) : uint8(27)));
        assertEq(box.packet(id).grabbed, 0);
        _assertAccounting();
    }

    function testPersonalSignAndWrongDomainAreRejected() public {
        uint256 id = _create(1 ether, 2, true);
        bytes32 digest = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", _digest(box, 4663, id, alice)));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        vm.expectRevert(HongbaoBox.InvalidSignature.selector);
        box.grab(id, alice, abi.encodePacked(r, s, v));
        digest = keccak256(abi.encode(id, alice));
        (v, r, s) = vm.sign(key, digest);
        vm.expectRevert(HongbaoBox.InvalidSignature.selector);
        box.grab(id, alice, abi.encodePacked(r, s, v));
    }

    function testFuzzSignatureCannotChangeRecipient(address different) public {
        vm.assume(different != alice && different != address(0) && different != address(box));
        uint256 id = _create(1 ether, 1, true);
        bytes memory sig = _sign(box, id, alice);
        vm.expectRevert(HongbaoBox.InvalidSignature.selector);
        box.grab(id, different, sig);
        assertFalse(box.hasGrabbed(id, different));
    }
}
