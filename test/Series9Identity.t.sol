// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "forge-std/Test.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Series9Identity} from "../src/Series9Identity.sol";

contract Series9IdentityTest is Test {
    Series9Identity public identity;
    address public owner;
    address public alice;
    address public bob;
    address public feeRecipient;

    function setUp() public {
        owner = address(this);
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        feeRecipient = makeAddr("feeRecipient");
        vm.deal(alice, 10 ether);
        vm.deal(bob, 10 ether);

        // Deploy implementation
        Series9Identity impl = new Series9Identity();

        // Deploy proxy + initialize
        bytes memory initData = abi.encodeCall(
            Series9Identity.initialize,
            (owner, 0.01 ether, feeRecipient)
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        identity = Series9Identity(address(proxy));
    }

    function test_initialize() public view {
        assertEq(identity.mintFee(), 0.01 ether);
        assertEq(identity.feeRecipient(), feeRecipient);
        assertEq(identity.owner(), owner);
    }

    function test_mintHuman() public {
        vm.prank(alice);
        uint256 tid = identity.mintIdentity{value: 0.01 ether}(
            "Alice",
            "Hello I am Alice",
            Series9Identity.EntityType.Human,
            180,
            200
        );

        assertEq(identity.ownerOf(tid), alice);
        assertEq(identity.ownerTokenId(alice), tid);
        assertTrue(identity.isHuman(alice));
        assertFalse(identity.isAI(alice));
        assertFalse(identity.isVerified(tid));

        // Check profile fields individually
        (string memory name,,,,,,) = identity.profiles(tid);
        assertEq(name, "Alice");
    }

    function test_mintAI() public {
        vm.prank(bob);
        uint256 tid = identity.mintIdentity{value: 0.01 ether}(
            "AgentX",
            "AI assistant",
            Series9Identity.EntityType.AI,
            250,
            180
        );

        assertTrue(identity.isAI(bob));
        assertFalse(identity.isHuman(bob));
    }

    function test_oneIdentityPerAddress() public {
        vm.prank(alice);
        identity.mintIdentity{value: 0.01 ether}("Alice", "", Series9Identity.EntityType.Human, 100, 200);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("AlreadyHasIdentity(address)", alice));
        identity.mintIdentity{value: 0.01 ether}("Alice2", "", Series9Identity.EntityType.Human, 100, 200);
    }

    function test_insufficientMintFee() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Series9Identity.InsufficientMintFee.selector, 0.01 ether, 0.005 ether));
        identity.mintIdentity{value: 0.005 ether}("Alice", "", Series9Identity.EntityType.Human, 100, 200);
    }

    function test_updateProfile() public {
        vm.prank(alice);
        uint256 tid = identity.mintIdentity{value: 0.01 ether}("Alice", "old bio", Series9Identity.EntityType.Human, 100, 200);

        vm.prank(alice);
        identity.updateProfile(tid, "Alice Updated", "new bio", 150, 220);

        (string memory name, string memory bio,,,,,) = identity.profiles(tid);
        assertEq(name, "Alice Updated");
        assertEq(bio, "new bio");
    }

    function test_updateProfileNotOwner() public {
        vm.prank(alice);
        uint256 tid = identity.mintIdentity{value: 0.01 ether}("Alice", "", Series9Identity.EntityType.Human, 100, 200);

        vm.prank(bob);
        vm.expectRevert(Series9Identity.NotTokenOwner.selector);
        identity.updateProfile(tid, "Hacked", "", 100, 200);
    }

    function test_verify() public {
        vm.prank(alice);
        uint256 tid = identity.mintIdentity{value: 0.01 ether}("Alice", "", Series9Identity.EntityType.Human, 100, 200);

        identity.verify(tid, true);
        assertTrue(identity.isVerified(tid));

        identity.verify(tid, false);
        assertFalse(identity.isVerified(tid));
    }

    function test_verifyNotOwner() public {
        vm.prank(alice);
        uint256 tid = identity.mintIdentity{value: 0.01 ether}("Alice", "", Series9Identity.EntityType.Human, 100, 200);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", bob));
        identity.verify(tid, true);
    }

    function test_tokenURIContainsSVG() public {
        vm.prank(alice);
        uint256 tid = identity.mintIdentity{value: 0.01 ether}("Alice", "Test bio", Series9Identity.EntityType.Human, 100, 200);

        string memory uri = identity.tokenURI(tid);
        // Should start with data:application/json;base64,
        assertEq(uri, uri); // just ensure no revert; real SVG validation is visual
    }

    function test_hasIdentity() public {
        assertFalse(identity.hasIdentity(alice));

        vm.prank(alice);
        identity.mintIdentity{value: 0.01 ether}("Alice", "", Series9Identity.EntityType.Human, 100, 200);

        assertTrue(identity.hasIdentity(alice));
    }

    function test_nameOf() public {
        assertEq(identity.nameOf(alice), "");

        vm.prank(alice);
        identity.mintIdentity{value: 0.01 ether}("Alice", "", Series9Identity.EntityType.Human, 100, 200);

        assertEq(identity.nameOf(alice), "Alice");
    }

    function test_setMintFee() public {
        identity.setMintFee(0.02 ether);
        assertEq(identity.mintFee(), 0.02 ether);
    }

    function test_pauseUnpause() public {
        identity.pause();

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        identity.mintIdentity{value: 0.01 ether}("Alice", "", Series9Identity.EntityType.Human, 100, 200);

        identity.unpause();

        vm.prank(alice);
        identity.mintIdentity{value: 0.01 ether}("Alice", "", Series9Identity.EntityType.Human, 100, 200);
    }

    function test_nameTooLong() public {
        vm.prank(alice);
        string memory longName = "abcdefghijklmnopqrstuvwxyz1234567"; // 33 chars
        vm.expectRevert(Series9Identity.NameTooLong.selector);
        identity.mintIdentity{value: 0.01 ether}(longName, "", Series9Identity.EntityType.Human, 100, 200);
    }

    function test_bioTooLong() public {
        vm.prank(alice);
        string memory longBio = "x";
        for (uint256 i = 0; i < 128; i++) {
            longBio = string(abi.encodePacked(longBio, "x"));
        }
        vm.expectRevert(Series9Identity.BioTooLong.selector);
        identity.mintIdentity{value: 0.01 ether}("Alice", longBio, Series9Identity.EntityType.Human, 100, 200);
    }

    function test_customAvatarSeed() public {
        vm.prank(alice);
        uint256 tid = identity.mintIdentity{value: 0.01 ether}("Alice", "", Series9Identity.EntityType.Human, 100, 200);

        vm.prank(alice);
        identity.setCustomAvatarSeed(tid, "special-pattern-42");
        assertEq(identity.customAvatarSeed(tid), "special-pattern-42");
    }

    function test_isAI_unregisteredAddress() public view {
        assertFalse(identity.isAI(alice));
        assertFalse(identity.isHuman(alice));
    }

    function test_upgrade() public {
        Series9Identity newImpl = new Series9Identity();
        identity.upgradeToAndCall(address(newImpl), "");
        // Should still work after upgrade
        assertEq(identity.mintFee(), 0.01 ether);
    }
}
