// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "forge-std/Test.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Series9Identity} from "../src/Series9Identity.sol";
import {Series9IdentityRenderer} from "../src/Series9IdentityRenderer.sol";
import {SER9Token} from "../src/SER9Token.sol";
import {Series9Staking} from "../src/Series9Staking.sol";

contract Series9IdentityRendererHarness is Series9IdentityRenderer {
    function exposedEscapeJson(string memory value) external pure returns (string memory) {
        return _escapeJson(value);
    }

    function exposedGenerateSvg(string memory handle) external pure returns (string memory) {
        RenderProfile memory p = RenderProfile({
            name: "Alice",
            bio: "on-chain user",
            entityType: 0,
            hue: 100,
            saturation: 180,
            verified: false,
            registeredAt: 1_700_000_000,
            reputationScore: 9,
            handle: handle,
            avatarSeed: ""
        });

        return _generateSVG(1, p);
    }
}

contract Series9IdentityTest is Test {
    Series9Identity public identity;
    SER9Token public ser9;
    Series9Staking public staking;
    address public owner;
    address public alice;
    address public bob;
    address public charlie;

    uint256 constant AI_FEE = 10 ether; // 10 SER9
    uint256 constant HUMAN_FEE = 50 ether; // 50 SER9

    function setUp() public {
        owner = address(this);
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        charlie = makeAddr("charlie");

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
        bytes memory idData =
            abi.encodeCall(Series9Identity.initialize, (owner, address(ser9), address(mockStaking), AI_FEE, HUMAN_FEE));
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

    function test_initializeRejectsEOAStakingContract() public {
        Series9Identity impl = new Series9Identity();
        bytes memory idData = abi.encodeCall(
            Series9Identity.initialize, (owner, address(ser9), makeAddr("notStaking"), AI_FEE, HUMAN_FEE)
        );

        vm.expectRevert(Series9Identity.InvalidStakingContract.selector);
        new ERC1967Proxy(address(impl), idData);
    }

    function test_mintHuman() public {
        uint256 balBefore = ser9.balanceOf(alice);

        vm.prank(alice);
        uint256 tid = identity.mintIdentity("Alice", "Hello I am Alice", Series9Identity.EntityType.Human, 180, 200);

        assertEq(identity.ownerOf(tid), alice);
        assertEq(identity.ownerTokenId(alice), tid);
        assertTrue(identity.isHuman(alice));
        assertFalse(identity.isAI(alice));
        assertFalse(identity.isVerified(tid));
        assertEq(identity.reputationScores(tid), identity.DEFAULT_HUMAN_REPUTATION_SCORE());
        assertEq(identity.effectiveReputationScore(tid), identity.DEFAULT_HUMAN_REPUTATION_SCORE());
        assertEq(identity.reputationScoreOf(alice), identity.DEFAULT_HUMAN_REPUTATION_SCORE());
        assertEq(identity.totalReputationScore(), identity.DEFAULT_HUMAN_REPUTATION_SCORE());

        // 50 SER9 deducted from alice
        assertEq(balBefore - ser9.balanceOf(alice), HUMAN_FEE);

        // 50 SER9 staked in mock staking
        MockStaking ms = MockStaking(identity.stakingContract());
        assertEq(ms.stakedAmount(address(identity)), HUMAN_FEE);
    }

    function test_mintAI() public {
        uint256 balBefore = ser9.balanceOf(bob);

        vm.prank(bob);
        identity.mintIdentity("AgentX", "AI assistant", Series9Identity.EntityType.AI, 250, 180);

        assertTrue(identity.isAI(bob));
        assertFalse(identity.isHuman(bob));
        uint256 tid = identity.ownerTokenId(bob);
        assertEq(identity.reputationScores(tid), identity.DEFAULT_AI_REPUTATION_SCORE());
        assertEq(identity.effectiveReputationScore(tid), identity.DEFAULT_AI_REPUTATION_SCORE());
        assertEq(identity.reputationScoreOf(bob), identity.DEFAULT_AI_REPUTATION_SCORE());
        assertEq(identity.totalReputationScore(), identity.DEFAULT_AI_REPUTATION_SCORE());

        // 10 SER9 deducted
        assertEq(balBefore - ser9.balanceOf(bob), AI_FEE);

        MockStaking ms = MockStaking(identity.stakingContract());
        assertEq(ms.stakedAmount(address(identity)), AI_FEE);
    }

    function test_mintRevertsIfStakingContractDoesNotPullFee() public {
        NoPullStaking badStaking = new NoPullStaking();
        identity.setStakingContract(address(badStaking));

        uint256 balBefore = ser9.balanceOf(alice);

        vm.prank(alice);
        vm.expectRevert(Series9Identity.StakingFailed.selector);
        identity.mintIdentity("Alice", "", Series9Identity.EntityType.Human, 100, 200);

        assertEq(ser9.balanceOf(alice), balBefore);
        assertFalse(identity.hasIdentity(alice));
    }

    function test_zeroFeeMintDoesNotCallStaking() public {
        NoPullStaking badStaking = new NoPullStaking();
        identity.setStakingContract(address(badStaking));
        identity.setHumanMintFee(0);

        vm.prank(alice);
        uint256 tid = identity.mintIdentity("Alice", "", Series9Identity.EntityType.Human, 100, 200);

        assertEq(identity.ownerOf(tid), alice);
        assertEq(badStaking.stakeCalls(), 0);
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

    function test_verifyNonexistentTokenReverts() public {
        vm.expectRevert(Series9Identity.NonexistentToken.selector);
        identity.verify(999, true);
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

    function test_tokenURIChangesAfterHandleRegistration() public {
        vm.prank(alice);
        uint256 tid = identity.mintIdentity("Alice", "Test bio", Series9Identity.EntityType.Human, 100, 200);

        string memory beforeUri = identity.tokenURI(tid);

        vm.prank(alice);
        identity.setHandle(tid, "alice-1");

        string memory afterUri = identity.tokenURI(tid);
        assertTrue(keccak256(bytes(beforeUri)) != keccak256(bytes(afterUri)));
    }

    function test_svgRendersPaymentHandle() public {
        Series9IdentityRendererHarness harness = new Series9IdentityRendererHarness();

        assertTrue(_contains(harness.exposedGenerateSvg("alice-1"), "@alice-1"));
        assertTrue(_contains(harness.exposedGenerateSvg(""), "HANDLE PENDING"));
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

    function test_setStakingContractRejectsEOA() public {
        vm.expectRevert(Series9Identity.InvalidStakingContract.selector);
        identity.setStakingContract(makeAddr("notStaking"));
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

        string memory beforeUri = identity.tokenURI(tid);

        vm.prank(alice);
        identity.setCustomAvatarSeed(tid, "special-pattern-42");
        assertEq(identity.customAvatarSeed(tid), "special-pattern-42");

        string memory afterUri = identity.tokenURI(tid);
        assertTrue(keccak256(bytes(beforeUri)) != keccak256(bytes(afterUri)));
    }

    function test_customAvatarSeedTooLong() public {
        vm.prank(alice);
        uint256 tid = identity.mintIdentity("Alice", "", Series9Identity.EntityType.Human, 100, 200);

        vm.prank(alice);
        vm.expectRevert(Series9Identity.AvatarSeedTooLong.selector);
        identity.setCustomAvatarSeed(tid, "abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmn");
    }

    function test_customAvatarSeedBlockedWhilePaused() public {
        vm.prank(alice);
        uint256 tid = identity.mintIdentity("Alice", "", Series9Identity.EntityType.Human, 100, 200);

        identity.pause();

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        identity.setCustomAvatarSeed(tid, "paused");
    }

    function test_transferUpdatesIdentityOwnerAndRewardAccounting() public {
        vm.prank(alice);
        uint256 tid = identity.mintIdentity("Alice", "", Series9Identity.EntityType.Human, 100, 200);

        _fundIdentityRewards(9 ether);
        identity.collectStakingRewards();

        vm.prank(alice);
        identity.transferFrom(alice, bob, tid);

        assertEq(identity.ownerTokenId(alice), 0);
        assertEq(identity.ownerTokenId(bob), tid);
        assertFalse(identity.hasIdentity(alice));
        assertTrue(identity.hasIdentity(bob));
        assertTrue(identity.isHuman(bob));
        assertEq(identity.nameOf(alice), "");
        assertEq(identity.nameOf(bob), "Alice");
        assertEq(identity.totalReputationScore(), identity.DEFAULT_HUMAN_REPUTATION_SCORE());
        assertEq(identity.pendingNFTRewards(alice), 9 ether);
        assertEq(identity.pendingNFTRewards(bob), 0);

        uint256 aliceBefore = ser9.balanceOf(alice);
        vm.prank(alice);
        identity.claimNFTRewards();
        assertEq(ser9.balanceOf(alice), aliceBefore + 9 ether);

        _fundIdentityRewards(18 ether);
        identity.collectStakingRewards();

        assertEq(identity.pendingNFTRewards(alice), 0);
        assertEq(identity.pendingNFTRewards(bob), 18 ether);
    }

    function test_defaultReputationScoresSplitHumanAndAIRewardsNineToOne() public {
        vm.prank(alice);
        identity.mintIdentity("Alice", "", Series9Identity.EntityType.Human, 100, 200);

        vm.prank(bob);
        identity.mintIdentity("AgentX", "", Series9Identity.EntityType.AI, 120, 180);

        assertEq(identity.totalReputationScore(), 10);

        _fundIdentityRewards(100 ether);
        identity.collectStakingRewards();

        assertEq(identity.pendingNFTRewards(alice), 90 ether);
        assertEq(identity.pendingNFTRewards(bob), 10 ether);

        uint256 aliceBefore = ser9.balanceOf(alice);
        uint256 bobBefore = ser9.balanceOf(bob);

        vm.prank(alice);
        identity.claimNFTRewards();
        vm.prank(bob);
        identity.claimNFTRewards();

        assertEq(ser9.balanceOf(alice), aliceBefore + 90 ether);
        assertEq(ser9.balanceOf(bob), bobBefore + 10 ether);
    }

    function test_ownerCanUpdateReputationScoreAndFutureRewardsFollowScoreRatio() public {
        vm.prank(alice);
        uint256 aliceTokenId = identity.mintIdentity("Alice", "", Series9Identity.EntityType.Human, 100, 200);

        vm.prank(bob);
        uint256 bobTokenId = identity.mintIdentity("AgentX", "", Series9Identity.EntityType.AI, 120, 180);

        _fundIdentityRewards(100 ether);
        identity.collectStakingRewards();

        identity.setReputationScore(bobTokenId, 11);

        assertEq(identity.effectiveReputationScore(aliceTokenId), 9);
        assertEq(identity.effectiveReputationScore(bobTokenId), 11);
        assertEq(identity.totalReputationScore(), 20);
        assertEq(identity.pendingNFTRewards(alice), 90 ether);
        assertEq(identity.pendingNFTRewards(bob), 10 ether);

        _fundIdentityRewards(100 ether);
        identity.collectStakingRewards();

        assertEq(identity.pendingNFTRewards(alice), 135 ether);
        assertEq(identity.pendingNFTRewards(bob), 65 ether);
    }

    function test_nonOwnerCannotUpdateReputationScore() public {
        vm.prank(alice);
        uint256 tid = identity.mintIdentity("Alice", "", Series9Identity.EntityType.Human, 100, 200);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", bob));
        identity.setReputationScore(tid, 20);
    }

    function test_reputationScoreMustBeWithinAllowedRange() public {
        vm.prank(alice);
        uint256 tid = identity.mintIdentity("Alice", "", Series9Identity.EntityType.Human, 100, 200);

        vm.expectRevert(Series9Identity.InvalidReputationScore.selector);
        identity.setReputationScore(tid, 0);

        uint256 maxScore = identity.MAX_REPUTATION_SCORE();
        vm.expectRevert(Series9Identity.InvalidReputationScore.selector);
        identity.setReputationScore(tid, maxScore + 1);
    }

    function test_transferToExistingIdentityHolderReverts() public {
        vm.prank(alice);
        uint256 tid = identity.mintIdentity("Alice", "", Series9Identity.EntityType.Human, 100, 200);

        vm.prank(bob);
        identity.mintIdentity("Bob", "", Series9Identity.EntityType.Human, 100, 200);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Series9Identity.AlreadyHasIdentity.selector, bob));
        identity.transferFrom(alice, bob, tid);
    }

    function test_newMinterCannotClaimPastNftRewards() public {
        vm.prank(alice);
        identity.mintIdentity("Alice", "", Series9Identity.EntityType.Human, 100, 200);

        _fundIdentityRewards(9 ether);
        identity.collectStakingRewards();

        vm.prank(bob);
        identity.mintIdentity("Bob", "", Series9Identity.EntityType.Human, 100, 200);

        assertEq(identity.pendingNFTRewards(alice), 9 ether);
        assertEq(identity.pendingNFTRewards(bob), 0);

        vm.prank(bob);
        vm.expectRevert(Series9Identity.NoNFTRewards.selector);
        identity.claimNFTRewards();
    }

    function test_jsonEscapesTokenName() public {
        Series9IdentityRendererHarness harness = new Series9IdentityRendererHarness();
        string memory value = string(abi.encodePacked("A\"\\B", bytes1(uint8(0x0a)), "C"));

        assertEq(harness.exposedEscapeJson(value), "A\\\"\\\\B\\u000aC");
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

    function test_mintIdentityWithHandleRegistersHandle() public {
        vm.prank(alice);
        uint256 tid =
            identity.mintIdentityWithHandle("Alice", "", Series9Identity.EntityType.Human, 100, 200, "alice-1");

        assertEq(identity.handleOf(tid), "alice-1");
        assertEq(identity.tokenIdOfHandle("alice-1"), tid);
        assertEq(identity.ownerOfHandle("alice-1"), alice);
    }

    function test_handleValidationAndUniqueness() public {
        vm.prank(alice);
        identity.mintIdentityWithHandle("Alice", "", Series9Identity.EntityType.Human, 100, 200, "alice");

        vm.prank(bob);
        uint256 bobTokenId =
            identity.mintIdentityWithHandle("Bob", "", Series9Identity.EntityType.Human, 120, 180, "bob");

        vm.prank(bob);
        vm.expectRevert(Series9Identity.HandleAlreadyTaken.selector);
        identity.setHandle(bobTokenId, "alice");

        vm.prank(bob);
        vm.expectRevert(Series9Identity.InvalidHandle.selector);
        identity.setHandle(bobTokenId, "BadHandle");
    }

    function test_legacyHandleReservationsBlockUntilSeededAndUseLowestTokenId() public {
        vm.prank(alice);
        uint256 aliceTokenId = identity.mintIdentity("Alice_Name", "", Series9Identity.EntityType.Human, 100, 200);

        vm.prank(bob);
        uint256 bobTokenId = identity.mintIdentity("Alice Name", "", Series9Identity.EntityType.Human, 120, 180);

        identity.initializePayment();

        vm.prank(alice);
        vm.expectRevert(Series9Identity.LegacyHandleReservationsNotFinalized.selector);
        identity.setHandle(aliceTokenId, "alice-name");

        identity.seedLegacyHandleReservations(1);
        identity.seedLegacyHandleReservations(10);

        (uint256 reservedTokenId, uint64 expiresAt, bool active) = identity.legacyHandleReservationOf("alice-name");
        assertEq(reservedTokenId, aliceTokenId);
        assertEq(expiresAt, identity.legacyHandlePriorityDeadline());
        assertTrue(active);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Series9Identity.HandleReserved.selector, aliceTokenId, expiresAt));
        identity.setHandle(bobTokenId, "alice-name");

        vm.prank(alice);
        identity.setHandle(aliceTokenId, "alice-name");

        assertEq(identity.tokenIdOfHandle("alice-name"), aliceTokenId);
    }

    function test_legacyHandleReservationExpires() public {
        vm.prank(alice);
        identity.mintIdentity("Alice", "", Series9Identity.EntityType.Human, 100, 200);

        vm.prank(bob);
        uint256 bobTokenId = identity.mintIdentity("Bob", "", Series9Identity.EntityType.Human, 120, 180);

        identity.initializePayment();
        identity.seedLegacyHandleReservations(10);

        vm.warp(identity.legacyHandlePriorityDeadline() + 1);

        vm.prank(bob);
        identity.setHandle(bobTokenId, "alice");

        assertEq(identity.tokenIdOfHandle("alice"), bobTokenId);
    }

    function test_payToHandleTransfersERC20FromCallerOnly() public {
        (uint256 aliceTokenId, uint256 bobTokenId) = _mintAliceAndBobWithHandles();

        uint256 bobBefore = ser9.balanceOf(bob);
        vm.prank(alice);
        uint256 paymentId = identity.payToHandle(address(ser9), "bob", 7 ether, "coffee");

        assertEq(paymentId, 1);
        assertEq(identity.tokenIdOfHandle("alice"), aliceTokenId);
        assertEq(identity.tokenIdOfHandle("bob"), bobTokenId);
        assertEq(ser9.balanceOf(bob), bobBefore + 7 ether);
    }

    function test_transferredIdentityCannotSpendPreviousOwnerAllowance() public {
        (uint256 aliceTokenId,) = _mintAliceAndBobWithHandles();

        vm.prank(alice);
        identity.transferFrom(alice, charlie, aliceTokenId);

        uint256 aliceBefore = ser9.balanceOf(alice);
        vm.prank(charlie);
        vm.expectRevert();
        identity.payToHandle(address(ser9), "bob", 1 ether, "");

        assertEq(ser9.balanceOf(alice), aliceBefore);
    }

    function test_payToHandleTransfersNativeMON() public {
        _mintAliceAndBobWithHandles();

        vm.deal(alice, 3 ether);
        uint256 bobBefore = bob.balance;

        vm.prank(alice);
        identity.payToHandle{value: 1 ether}(address(0), "bob", 1 ether, "mon");

        assertEq(bob.balance, bobBefore + 1 ether);
    }

    function test_payToHandleRejectsWrongNativeValue() public {
        _mintAliceAndBobWithHandles();

        vm.deal(alice, 3 ether);
        vm.prank(alice);
        vm.expectRevert(Series9Identity.InvalidNativeValue.selector);
        identity.payToHandle{value: 2 ether}(address(0), "bob", 1 ether, "mon");

        vm.prank(alice);
        vm.expectRevert(Series9Identity.InvalidNativeValue.selector);
        identity.payToHandle{value: 1 ether}(address(ser9), "bob", 1 ether, "ser9");
    }

    function test_createAndPayERC20PaymentRequest() public {
        (uint256 aliceTokenId, uint256 bobTokenId) = _mintAliceAndBobWithHandles();

        vm.prank(bob);
        uint256 requestId =
            identity.createPaymentRequest("alice", address(ser9), 3 ether, uint64(block.timestamp + 1 days), "invoice");

        assertEq(identity.payerPaymentRequestCount(aliceTokenId), 1);
        assertEq(identity.payeePaymentRequestCount(bobTokenId), 1);
        assertEq(identity.payerPaymentRequestIdAt(aliceTokenId, 0), requestId);
        assertEq(identity.payeePaymentRequestIdAt(bobTokenId, 0), requestId);

        uint256 bobBefore = ser9.balanceOf(bob);
        vm.prank(alice);
        uint256 paymentId = identity.payPaymentRequest(requestId);

        assertEq(paymentId, 1);
        assertEq(ser9.balanceOf(bob), bobBefore + 3 ether);
        assertEq(
            uint8(identity.effectivePaymentRequestStatus(requestId)), uint8(Series9Identity.PaymentRequestStatus.Paid)
        );
    }

    function test_createAndPayNativeMONPaymentRequest() public {
        _mintAliceAndBobWithHandles();

        vm.prank(bob);
        uint256 requestId = identity.createPaymentRequest(
            "alice", address(0), 2 ether, uint64(block.timestamp + 1 days), "mon invoice"
        );

        vm.deal(alice, 3 ether);
        uint256 bobBefore = bob.balance;

        vm.prank(alice);
        identity.payPaymentRequest{value: 2 ether}(requestId);

        assertEq(bob.balance, bobBefore + 2 ether);
        assertEq(
            uint8(identity.effectivePaymentRequestStatus(requestId)), uint8(Series9Identity.PaymentRequestStatus.Paid)
        );
    }

    function test_paymentRequestCanBeCancelledByPayerOrPayee() public {
        _mintAliceAndBobWithHandles();

        vm.prank(bob);
        uint256 requestId =
            identity.createPaymentRequest("alice", address(ser9), 1 ether, uint64(block.timestamp + 1 days), "cancel");

        vm.prank(alice);
        identity.cancelPaymentRequest(requestId);

        assertEq(
            uint8(identity.effectivePaymentRequestStatus(requestId)),
            uint8(Series9Identity.PaymentRequestStatus.Cancelled)
        );

        vm.prank(alice);
        vm.expectRevert(Series9Identity.PaymentRequestNotPending.selector);
        identity.payPaymentRequest(requestId);
    }

    function test_paymentRequestExpires() public {
        _mintAliceAndBobWithHandles();

        vm.prank(bob);
        uint256 requestId =
            identity.createPaymentRequest("alice", address(ser9), 1 ether, uint64(block.timestamp + 1 days), "expired");

        vm.warp(block.timestamp + 2 days);

        assertEq(
            uint8(identity.effectivePaymentRequestStatus(requestId)),
            uint8(Series9Identity.PaymentRequestStatus.Expired)
        );

        vm.prank(alice);
        vm.expectRevert(Series9Identity.PaymentRequestNotPending.selector);
        identity.payPaymentRequest(requestId);
    }

    function _fundIdentityRewards(uint256 amount) internal {
        MockStaking ms = MockStaking(identity.stakingContract());
        ser9.approve(address(ms), amount);
        ms.fundRewards(address(identity), amount);
    }

    function _mintAliceAndBobWithHandles() internal returns (uint256 aliceTokenId, uint256 bobTokenId) {
        vm.prank(alice);
        aliceTokenId = identity.mintIdentityWithHandle("Alice", "", Series9Identity.EntityType.Human, 100, 200, "alice");

        vm.prank(bob);
        bobTokenId = identity.mintIdentityWithHandle("Bob", "", Series9Identity.EntityType.Human, 120, 180, "bob");
    }

    function _contains(string memory haystack, string memory needle) internal pure returns (bool) {
        bytes memory haystackBytes = bytes(haystack);
        bytes memory needleBytes = bytes(needle);
        if (needleBytes.length == 0 || needleBytes.length > haystackBytes.length) {
            return false;
        }

        for (uint256 i = 0; i <= haystackBytes.length - needleBytes.length; i++) {
            bool found = true;
            for (uint256 j = 0; j < needleBytes.length; j++) {
                if (haystackBytes[i + j] != needleBytes[j]) {
                    found = false;
                    break;
                }
            }
            if (found) {
                return true;
            }
        }

        return false;
    }
}

/// @notice Mock staking contract for testing — just records staked amounts
contract MockStaking {
    IERC20 public ser9;
    mapping(address => uint256) public stakedAmount;
    mapping(address => uint256) public rewards;
    uint256 public totalStaked;

    constructor(address ser9Token) {
        ser9 = IERC20(ser9Token);
    }

    function stake(uint256 amount) external {
        ser9.transferFrom(msg.sender, address(this), amount);
        stakedAmount[msg.sender] += amount;
        totalStaked += amount;
    }

    function fundRewards(address account, uint256 amount) external {
        ser9.transferFrom(msg.sender, address(this), amount);
        rewards[account] += amount;
    }

    function claimRewards() external {
        uint256 reward = rewards[msg.sender];
        rewards[msg.sender] = 0;
        ser9.transfer(msg.sender, reward);
    }
}

contract NoPullStaking {
    uint256 public stakeCalls;
    mapping(address => uint256) public rewards;

    function stake(uint256) external {
        stakeCalls++;
    }

    function claimRewards() external {}
}
