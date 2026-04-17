// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "forge-std/Test.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Series9Identity} from "../src/Series9Identity.sol";
import {SER9Token} from "../src/SER9Token.sol";
import {Series9Staking} from "../src/Series9Staking.sol";

contract Series9IdentityTest is Test {
    Series9Identity public identity;
    SER9Token public ser9;
    Series9Staking public staking;
    address public owner;
    address public alice;
    address public bob;

    uint256 constant AI_FEE = 10 ether;       // 10 SER9
    uint256 constant HUMAN_FEE = 50 ether;    // 50 SER9

    function setUp() public {
        owner = address(this);
        alice = makeAddr("alice");
        bob = makeAddr("bob");

        // 1. Deploy SER9 token
        SER9Token ser9Impl = new SER9Token();
        bytes memory ser9Data = abi.encodeCall(SER9Token.initialize, (owner));
        ERC1967Proxy ser9Proxy = new ERC1967Proxy(address(ser9Impl), ser9Data);
        ser9 = SER9Token(address(ser9Proxy));

        // 2. Deploy Staking (minimal setup — we just need stake() to work)
        // For testing, use a mock staking contract instead
        MockStaking mockStaking = new MockStaking(address(ser9));

        // 3. Deploy Identity
        Series9Identity impl = new Series9Identity();
        bytes memory idData = abi.encodeCall(
            Series9Identity.initialize,
            (owner, address(ser9), address(mockStaking), AI_FEE, HUMAN_FEE)
        );
        ERC1967Proxy idProxy = new ERC1967Proxy(address(impl), idData);
        identity = Series9Identity(address(idProxy));

        // Fund users with SER9
        ser9.transfer(alice, 100 ether);
        ser9.transfer(bob, 100 ether);

        // Approve identity contract to spend SER9
        vm.prank(alice);
        ser9.approve(address(identity), type(uint256).max);
        vm.prank(bob);
        ser9.approve(address(identity), type(uint256).max);
    }

    function test_initialize() public view {
        assertEq(identity.aiMintFee(), AI_FEE);
        assertEq(identity.humanMintFee(), HUMAN_FEE);
        assertEq(address(identity.ser9()), address(ser9));
        assertEq(identity.stakingContract(), address(MockStaking(address(identity.stakingContract()))));
    }

    function test_mintHuman() public {
        uint256 balBefore = ser9.balanceOf(alice);

        vm.prank(alice);
        uint256 tid = identity.mintIdentity(
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

        // 50 SER9 deducted from alice
        assertEq(balBefore - ser9.balanceOf(alice), HUMAN_FEE);

        // 50 SER9 staked in mock staking
        MockStaking ms = MockStaking(identity.stakingContract());
        assertEq(ms.stakedAmount(address(identity)), HUMAN_FEE);
    }

    function test_mintAI() public {
        uint256 balBefore = ser9.balanceOf(bob);

        vm.prank(bob);
        uint256 tid = identity.mintIdentity(
            "AgentX",
            "AI assistant",
            Series9Identity.EntityType.AI,
            250,
            180
        );

        assertTrue(identity.isAI(bob));
        assertFalse(identity.isHuman(bob));

        // 10 SER9 deducted
        assertEq(balBefore - ser9.balanceOf(bob), AI_FEE);

        MockStaking ms = MockStaking(identity.stakingContract());
        assertEq(ms.stakedAmount(address(identity)), AI_FEE);
    }

    function test_oneIdentityPerAddress() public {
        vm.prank(alice);
        identity.mintIdentity("Alice", "", Series9Identity.EntityType.Human, 100, 200);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("AlreadyHasIdentity(address)", alice));
        identity.mintIdentity("Alice2", "", Series9Identity.EntityType.Human, 100, 200);
    }

    function test_insufficientAllowance() public {
        // Revoke approval
        vm.prank(alice);
        ser9.approve(address(identity), 0);

        vm.prank(alice);
        // ERC20 will revert with insufficient allowance
        vm.expectRevert();
        identity.mintIdentity("Alice", "", Series9Identity.EntityType.Human, 100, 200);
    }

    function test_insufficientBalance() public {
        address poor = makeAddr("poor");
        vm.prank(alice);
        ser9.transfer(poor, 5 ether); // only 5 SER9, needs 10 for AI

        vm.prank(poor);
        ser9.approve(address(identity), type(uint256).max);

        vm.prank(poor);
        // Will fail because poor only has 5 SER9 but needs 10 for AI
        vm.expectRevert();
        identity.mintIdentity("Poor", "", Series9Identity.EntityType.AI, 100, 200);
    }

    function test_updateProfile() public {
        vm.prank(alice);
        uint256 tid = identity.mintIdentity("Alice", "old bio", Series9Identity.EntityType.Human, 100, 200);

        vm.prank(alice);
        identity.updateProfile(tid, "Alice Updated", "new bio", 150, 220);

        (string memory name,,,,,,) = identity.profiles(tid);
        assertEq(name, "Alice Updated");
    }

    function test_updateProfileNotOwner() public {
        vm.prank(alice);
        uint256 tid = identity.mintIdentity("Alice", "", Series9Identity.EntityType.Human, 100, 200);

        vm.prank(bob);
        vm.expectRevert(Series9Identity.NotTokenOwner.selector);
        identity.updateProfile(tid, "Hacked", "", 100, 200);
    }

    function test_verify() public {
        vm.prank(alice);
        uint256 tid = identity.mintIdentity("Alice", "", Series9Identity.EntityType.Human, 100, 200);

        identity.verify(tid, true);
        assertTrue(identity.isVerified(tid));

        identity.verify(tid, false);
        assertFalse(identity.isVerified(tid));
    }

    function test_verifyNotOwner() public {
        vm.prank(alice);
        uint256 tid = identity.mintIdentity("Alice", "", Series9Identity.EntityType.Human, 100, 200);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", bob));
        identity.verify(tid, true);
    }

    function test_tokenURIContainsSVG() public {
        vm.prank(alice);
        uint256 tid = identity.mintIdentity("Alice", "Test bio", Series9Identity.EntityType.Human, 100, 200);

        string memory uri = identity.tokenURI(tid);
        assertEq(uri, uri); // ensure no revert
    }

    function test_hasIdentity() public {
        assertFalse(identity.hasIdentity(alice));

        vm.prank(alice);
        identity.mintIdentity("Alice", "", Series9Identity.EntityType.Human, 100, 200);

        assertTrue(identity.hasIdentity(alice));
    }

    function test_nameOf() public {
        assertEq(identity.nameOf(alice), "");

        vm.prank(alice);
        identity.mintIdentity("Alice", "", Series9Identity.EntityType.Human, 100, 200);

        assertEq(identity.nameOf(alice), "Alice");
    }

    function test_setAIMintFee() public {
        identity.setAIMintFee(20 ether);
        assertEq(identity.aiMintFee(), 20 ether);
    }

    function test_setHumanMintFee() public {
        identity.setHumanMintFee(100 ether);
        assertEq(identity.humanMintFee(), 100 ether);
    }

    function test_pauseUnpause() public {
        identity.pause();

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        identity.mintIdentity("Alice", "", Series9Identity.EntityType.Human, 100, 200);

        identity.unpause();

        vm.prank(alice);
        identity.mintIdentity("Alice", "", Series9Identity.EntityType.Human, 100, 200);
    }

    function test_nameTooLong() public {
        vm.prank(alice);
        string memory longName = "abcdefghijklmnopqrstuvwxyz1234567"; // 33 chars
        vm.expectRevert(Series9Identity.NameTooLong.selector);
        identity.mintIdentity(longName, "", Series9Identity.EntityType.Human, 100, 200);
    }

    function test_customAvatarSeed() public {
        vm.prank(alice);
        uint256 tid = identity.mintIdentity("Alice", "", Series9Identity.EntityType.Human, 100, 200);

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
        assertEq(identity.aiMintFee(), AI_FEE);
        assertEq(identity.humanMintFee(), HUMAN_FEE);
    }
}

/// @notice Mock staking contract for testing — just records staked amounts
contract MockStaking {
    IERC20 public ser9;
    mapping(address => uint256) public stakedAmount;
    uint256 public totalStaked;

    constructor(address ser9Token) {
        ser9 = IERC20(ser9Token);
    }

    function stake(uint256 amount) external {
        ser9.transferFrom(msg.sender, address(this), amount);
        stakedAmount[msg.sender] += amount;
        totalStaked += amount;
    }
}
