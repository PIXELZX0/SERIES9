// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "forge-std/Test.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Series9Identity} from "../src/Series9Identity.sol";
import {Series9IdentityWallet} from "../src/Series9IdentityWallet.sol";
import {SER9Token} from "../src/SER9Token.sol";

/// @dev Minimal staking mock that pulls SER9 on stake (mirrors the harness used in Series9Identity.t.sol).
contract MockStaking {
    IERC20 public ser9;
    mapping(address => uint256) public stakedAmount;

    constructor(address ser9Token) {
        ser9 = IERC20(ser9Token);
    }

    function stake(uint256 amount) external {
        ser9.transferFrom(msg.sender, address(this), amount);
        stakedAmount[msg.sender] += amount;
    }

    function claimRewards() external {}
}

/// @dev A throwaway contract used to exercise wallet CREATE / CREATE2 deployment.
contract Dummy {
    uint256 public magic = 42;
}

/// @dev A valid forward wallet implementation (same storage layout, extra function).
contract WalletUpgradeTarget is Series9IdentityWallet {
    function walletVersion() external pure returns (uint256) {
        return 2;
    }
}

/// @dev Malicious escrow recipient: if its ERC721 receiver hook were ever invoked during finalize it would
///      try to forward the just-received identity with a raw transfer, bypassing the escrow restriction.
///      Since finalize uses the callback-free _transfer, this hook must never run.
contract ReentrantRecipient {
    Series9Identity public immutable id;
    bool public hookRan;

    constructor(Series9Identity _id) {
        id = _id;
    }

    function onERC721Received(address, address, uint256 tokenId, bytes calldata) external returns (bytes4) {
        hookRan = true;
        // Attempt the bypass; swallow the revert so we can detect whether the hook ran at all.
        try id.transferFrom(address(this), address(0xdead), tokenId) {} catch {}
        return this.onERC721Received.selector;
    }
}

contract Series9IdentityWalletTest is Test {
    Series9Identity public identity;
    SER9Token public ser9;
    MockStaking public staking;
    Series9IdentityWallet public bootstrap;

    address public owner;
    address public alice;
    address public bob;
    address public carol;
    address public dest;

    uint256 constant AI_FEE = 10 ether;
    uint256 constant HUMAN_FEE = 50 ether;

    // Storage slots (from `forge inspect Series9Identity storage-layout`).
    uint256 constant _NEXT_PAYMENT_ID_SLOT = 19;
    uint256 constant _NEXT_PAYMENT_REQUEST_ID_SLOT = 20;

    function setUp() public {
        owner = address(this);
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        carol = makeAddr("carol");
        dest = makeAddr("dest");

        // SER9
        SER9Token ser9Impl = new SER9Token();
        ser9 = SER9Token(address(new ERC1967Proxy(address(ser9Impl), abi.encodeCall(SER9Token.initialize, (owner)))));

        // Staking mock
        staking = new MockStaking(address(ser9));

        // Identity
        Series9Identity idImpl = new Series9Identity();
        identity = Series9Identity(
            address(
                new ERC1967Proxy(
                    address(idImpl),
                    abi.encodeCall(Series9Identity.initialize, (owner, address(ser9), address(staking), AI_FEE, HUMAN_FEE))
                )
            )
        );

        // Initialize payment storage (reinitializer(2)) before configuring the wallet factory (reinitializer(3)).
        identity.initializePayment();

        // Configure the wallet factory (reinitializer(3)).
        bootstrap = new Series9IdentityWallet();
        identity.initializeWalletFactory(address(bootstrap));

        // Fund + approve users.
        ser9.transfer(alice, 1000 ether);
        ser9.transfer(bob, 1000 ether);
        vm.prank(alice);
        ser9.approve(address(identity), type(uint256).max);
        vm.prank(bob);
        ser9.approve(address(identity), type(uint256).max);
    }

    // ─────────────────── Helpers ───────────────────

    function _mint(address who) internal returns (uint256 tid, Series9IdentityWallet wallet) {
        vm.prank(who);
        tid = identity.mintIdentity("Name", "bio", Series9Identity.EntityType.Human, 100, 100);
        wallet = Series9IdentityWallet(payable(identity.walletOf(tid)));
    }

    // ─────────────────── Factory ───────────────────

    function test_walletAutoCreatedOnMint() public {
        (uint256 tid, Series9IdentityWallet wallet) = _mint(alice);
        assertTrue(address(wallet) != address(0));
        assertEq(address(wallet), identity.predictWalletAddress(tid));
        assertEq(wallet.identity(), address(identity));
        assertEq(wallet.tokenId(), tid);
    }

    function test_createWalletRevertsWhenAlreadyCreated() public {
        (uint256 tid,) = _mint(alice);
        vm.expectRevert(Series9Identity.WalletAlreadyCreated.selector);
        identity.createWallet(tid);
    }

    function test_createWalletRevertsForNonexistentToken() public {
        vm.expectRevert(Series9Identity.NonexistentToken.selector);
        identity.createWallet(12_345);
    }

    function test_lazyCreateForLegacyIdentity() public {
        // Fresh identity proxy whose wallet factory is NOT configured → mint produces no wallet.
        Series9Identity legacyImpl = new Series9Identity();
        Series9Identity legacy = Series9Identity(
            address(
                new ERC1967Proxy(
                    address(legacyImpl),
                    abi.encodeCall(Series9Identity.initialize, (owner, address(ser9), address(staking), AI_FEE, HUMAN_FEE))
                )
            )
        );
        vm.prank(alice);
        ser9.approve(address(legacy), type(uint256).max);
        vm.prank(alice);
        uint256 tid = legacy.mintIdentity("L", "legacy", Series9Identity.EntityType.Human, 1, 1);
        assertEq(legacy.walletOf(tid), address(0));

        // Configure factory after the fact, then lazily create the wallet.
        legacy.initializePayment();
        Series9IdentityWallet boot2 = new Series9IdentityWallet();
        legacy.initializeWalletFactory(address(boot2));
        address predicted = legacy.predictWalletAddress(tid);
        address wallet = legacy.createWallet(tid);
        assertEq(wallet, predicted);
        assertEq(legacy.walletOf(tid), wallet);
    }

    // ─────────────────── Wallet operations ───────────────────

    function test_receiveAndExecuteNative() public {
        (, Series9IdentityWallet wallet) = _mint(alice);
        vm.deal(address(wallet), 5 ether);

        vm.prank(alice);
        wallet.execute(dest, 1 ether, "");

        assertEq(dest.balance, 1 ether);
        assertEq(address(wallet).balance, 4 ether);
    }

    function test_executeERC20Transfer() public {
        (, Series9IdentityWallet wallet) = _mint(alice);
        ser9.transfer(address(wallet), 10 ether);

        vm.prank(alice);
        wallet.execute(address(ser9), 0, abi.encodeCall(IERC20.transfer, (carol, 4 ether)));

        assertEq(ser9.balanceOf(carol), 4 ether);
        assertEq(ser9.balanceOf(address(wallet)), 6 ether);
    }

    function test_executeRevertsForNonOwner() public {
        (, Series9IdentityWallet wallet) = _mint(alice);
        vm.deal(address(wallet), 1 ether);

        vm.prank(bob);
        vm.expectRevert(Series9Identity.NotTokenOwner.selector);
        wallet.execute(dest, 1 ether, "");
    }

    function test_deployContractViaCreate() public {
        (, Series9IdentityWallet wallet) = _mint(alice);

        vm.prank(alice);
        address deployed = wallet.deployContract(0, type(Dummy).creationCode);

        assertGt(deployed.code.length, 0);
        assertEq(Dummy(deployed).magic(), 42);
    }

    function test_deployContract2Deterministic() public {
        (, Series9IdentityWallet wallet) = _mint(alice);
        bytes32 salt = keccak256("salt-1");

        vm.prank(alice);
        address deployed = wallet.deployContract2(salt, 0, type(Dummy).creationCode);
        assertGt(deployed.code.length, 0);

        // Re-deploying to the same CREATE2 address fails (slot occupied → create2 returns 0).
        vm.prank(alice);
        vm.expectRevert(Series9IdentityWallet.DeployFailed.selector);
        wallet.deployContract2(salt, 0, type(Dummy).creationCode);
    }

    function test_executeBatch() public {
        (, Series9IdentityWallet wallet) = _mint(alice);
        vm.deal(address(wallet), 5 ether);

        address[] memory tos = new address[](2);
        uint256[] memory values = new uint256[](2);
        bytes[] memory datas = new bytes[](2);
        tos[0] = dest;
        values[0] = 1 ether;
        datas[0] = "";
        tos[1] = bob;
        values[1] = 2 ether;
        datas[1] = "";

        vm.prank(alice);
        wallet.executeBatch(tos, values, datas);

        assertEq(dest.balance, 1 ether);
        assertEq(bob.balance, 2 ether);
    }

    function test_executeBatchLengthMismatch() public {
        (, Series9IdentityWallet wallet) = _mint(alice);
        address[] memory tos = new address[](2);
        uint256[] memory values = new uint256[](1);
        bytes[] memory datas = new bytes[](2);

        vm.prank(alice);
        vm.expectRevert(Series9IdentityWallet.LengthMismatch.selector);
        wallet.executeBatch(tos, values, datas);
    }

    // ─────────────────── Upgrade (allowlist + no-downgrade) ───────────────────

    function test_upgradeToApprovedImpl() public {
        (, Series9IdentityWallet wallet) = _mint(alice);
        WalletUpgradeTarget v2 = new WalletUpgradeTarget();
        identity.setWalletImplApproved(address(v2), 2);

        vm.prank(alice);
        wallet.upgradeToAndCall(address(v2), "");

        // State preserved; new behavior available.
        assertEq(wallet.identity(), address(identity));
        assertEq(WalletUpgradeTarget(payable(address(wallet))).walletVersion(), 2);
    }

    function test_upgradeToUnapprovedImplReverts() public {
        (, Series9IdentityWallet wallet) = _mint(alice);
        WalletUpgradeTarget v2 = new WalletUpgradeTarget(); // not approved

        vm.prank(alice);
        vm.expectRevert(Series9Identity.WalletImplNotApproved.selector);
        wallet.upgradeToAndCall(address(v2), "");
    }

    function test_upgradeByNonOwnerReverts() public {
        (, Series9IdentityWallet wallet) = _mint(alice);
        WalletUpgradeTarget v2 = new WalletUpgradeTarget();
        identity.setWalletImplApproved(address(v2), 2);

        vm.prank(bob);
        vm.expectRevert(Series9Identity.NotTokenOwner.selector);
        wallet.upgradeToAndCall(address(v2), "");
    }

    function test_downgradeReverts() public {
        (, Series9IdentityWallet wallet) = _mint(alice);
        WalletUpgradeTarget v2 = new WalletUpgradeTarget();
        identity.setWalletImplApproved(address(v2), 2);

        vm.prank(alice);
        wallet.upgradeToAndCall(address(v2), ""); // now on v2 (version 2)

        // Roll back to the bootstrap impl (version 1) → blocked.
        vm.prank(alice);
        vm.expectRevert(Series9Identity.WalletDowngradeNotAllowed.selector);
        wallet.upgradeToAndCall(address(bootstrap), "");
    }

    function test_equalVersionUpgradeReverts() public {
        (, Series9IdentityWallet wallet) = _mint(alice);
        WalletUpgradeTarget v2a = new WalletUpgradeTarget();
        WalletUpgradeTarget v2b = new WalletUpgradeTarget();
        identity.setWalletImplApproved(address(v2a), 2);
        identity.setWalletImplApproved(address(v2b), 2);

        vm.prank(alice);
        wallet.upgradeToAndCall(address(v2a), "");

        vm.prank(alice);
        vm.expectRevert(Series9Identity.WalletDowngradeNotAllowed.selector);
        wallet.upgradeToAndCall(address(v2b), "");
    }

    function test_upgradeBlockedDuringTransferFreeze() public {
        (, Series9IdentityWallet wallet) = _mint(alice);
        WalletUpgradeTarget v2 = new WalletUpgradeTarget();
        identity.setWalletImplApproved(address(v2), 2);

        vm.prank(alice);
        identity.initiateIdentityTransfer(carol); // wallet freezes (Pending)

        vm.prank(alice);
        vm.expectRevert(Series9Identity.WalletFrozenDuringTransfer.selector);
        wallet.upgradeToAndCall(address(v2), "");
    }

    // ─────────────────── Escrowed transfer ───────────────────

    function test_transferHappyPath() public {
        (uint256 tid,) = _mint(alice);

        vm.prank(alice);
        identity.initiateIdentityTransfer(carol);

        vm.prank(carol);
        identity.acceptIdentityTransfer(tid);

        // Cannot finalize before the delay elapses.
        (,, uint64 acceptedAt,) = identity.identityTransferOf(tid);
        uint64 readyAt = acceptedAt + identity.IDENTITY_TRANSFER_DELAY();
        vm.expectRevert(abi.encodeWithSelector(Series9Identity.TransferDelayNotElapsed.selector, readyAt));
        identity.finalizeIdentityTransfer(tid);

        vm.warp(block.timestamp + identity.IDENTITY_TRANSFER_DELAY());
        identity.finalizeIdentityTransfer(tid); // permissionless

        assertEq(identity.ownerOf(tid), carol);
        assertEq(identity.ownerTokenId(carol), tid);
        assertEq(identity.ownerTokenId(alice), 0);
    }

    function test_walletControlAndBalanceFollowIdentity() public {
        (uint256 tid, Series9IdentityWallet wallet) = _mint(alice);
        vm.deal(address(wallet), 3 ether);

        vm.prank(alice);
        identity.initiateIdentityTransfer(carol);
        vm.prank(carol);
        identity.acceptIdentityTransfer(tid);
        vm.warp(block.timestamp + identity.IDENTITY_TRANSFER_DELAY());
        identity.finalizeIdentityTransfer(tid);

        // Wallet address unchanged; balance rode along; carol now controls it.
        assertEq(address(wallet).balance, 3 ether);
        vm.prank(carol);
        wallet.execute(dest, 3 ether, "");
        assertEq(dest.balance, 3 ether);

        // Old owner is de-authorized.
        vm.prank(alice);
        vm.expectRevert(Series9Identity.NotTokenOwner.selector);
        wallet.execute(dest, 0, "");
    }

    function test_freezeBlocksWalletWhilePending() public {
        (, Series9IdentityWallet wallet) = _mint(alice);
        vm.deal(address(wallet), 1 ether);

        vm.prank(alice);
        identity.initiateIdentityTransfer(carol);

        vm.prank(alice);
        vm.expectRevert(Series9Identity.WalletFrozenDuringTransfer.selector);
        wallet.execute(dest, 1 ether, "");
    }

    function test_freezeBlocksWalletWhileAccepted() public {
        (uint256 tid, Series9IdentityWallet wallet) = _mint(alice);
        vm.deal(address(wallet), 1 ether);

        vm.prank(alice);
        identity.initiateIdentityTransfer(carol);
        vm.prank(carol);
        identity.acceptIdentityTransfer(tid);

        vm.prank(alice);
        vm.expectRevert(Series9Identity.WalletFrozenDuringTransfer.selector);
        wallet.execute(dest, 1 ether, "");
    }

    function test_cancelBySenderInPending() public {
        (uint256 tid,) = _mint(alice);
        vm.prank(alice);
        identity.initiateIdentityTransfer(carol);

        vm.prank(alice);
        identity.cancelIdentityTransfer(tid);

        vm.prank(carol);
        vm.expectRevert(Series9Identity.TransferNotPending.selector);
        identity.acceptIdentityTransfer(tid);
    }

    function test_cancelByRecipientInPending() public {
        (uint256 tid,) = _mint(alice);
        vm.prank(alice);
        identity.initiateIdentityTransfer(carol);

        vm.prank(carol);
        identity.cancelIdentityTransfer(tid);

        (,,, Series9Identity.TransferStatus status) = identity.identityTransferOf(tid);
        assertEq(uint256(status), uint256(Series9Identity.TransferStatus.Cancelled));
    }

    function test_cancelInAcceptedBlocksFinalize() public {
        (uint256 tid,) = _mint(alice);
        vm.prank(alice);
        identity.initiateIdentityTransfer(carol);
        vm.prank(carol);
        identity.acceptIdentityTransfer(tid);

        vm.prank(carol);
        identity.cancelIdentityTransfer(tid);

        vm.warp(block.timestamp + identity.IDENTITY_TRANSFER_DELAY());
        vm.expectRevert(Series9Identity.TransferNotAccepted.selector);
        identity.finalizeIdentityTransfer(tid);
    }

    function test_cancelUnfreezesWallet() public {
        (uint256 tid, Series9IdentityWallet wallet) = _mint(alice);
        vm.deal(address(wallet), 1 ether);

        vm.prank(alice);
        identity.initiateIdentityTransfer(carol);
        vm.prank(alice);
        identity.cancelIdentityTransfer(tid);

        // Wallet operable again by the original owner.
        vm.prank(alice);
        wallet.execute(dest, 1 ether, "");
        assertEq(dest.balance, 1 ether);
    }

    function test_acceptByNonRecipientReverts() public {
        (uint256 tid,) = _mint(alice);
        vm.prank(alice);
        identity.initiateIdentityTransfer(carol);

        vm.prank(bob);
        vm.expectRevert(Series9Identity.UnauthorizedTransferActor.selector);
        identity.acceptIdentityTransfer(tid);
    }

    function test_directTransferBlocked() public {
        (uint256 tid,) = _mint(alice);

        vm.prank(alice);
        vm.expectRevert(Series9Identity.TransferRestricted.selector);
        identity.transferFrom(alice, carol, tid);

        vm.prank(alice);
        vm.expectRevert(Series9Identity.TransferRestricted.selector);
        identity.safeTransferFrom(alice, carol, tid);
    }

    function test_initiateToExistingIdentityReverts() public {
        _mint(alice);
        _mint(bob);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Series9Identity.AlreadyHasIdentity.selector, bob));
        identity.initiateIdentityTransfer(bob);
    }

    function test_initiateWithoutIdentityReverts() public {
        vm.prank(carol);
        vm.expectRevert(Series9Identity.NoIdentity.selector);
        identity.initiateIdentityTransfer(alice);
    }

    function test_initiateTwiceReverts() public {
        _mint(alice);
        vm.prank(alice);
        identity.initiateIdentityTransfer(carol);

        vm.prank(alice);
        vm.expectRevert(Series9Identity.TransferAlreadyActive.selector);
        identity.initiateIdentityTransfer(bob);
    }

    // ─────────────────── Regression: hardening fixes ───────────────────

    /// @dev finalize must use the callback-free _transfer: a contract recipient's ERC721 hook is never invoked,
    ///      so it cannot re-enter and forward the identity to bypass the escrow restriction.
    function test_finalizeDoesNotInvokeRecipientHookNorAllowReentrantBypass() public {
        (uint256 tid,) = _mint(alice);
        ReentrantRecipient recipient = new ReentrantRecipient(identity);

        vm.prank(alice);
        identity.initiateIdentityTransfer(address(recipient));
        vm.prank(address(recipient));
        identity.acceptIdentityTransfer(tid);
        vm.warp(block.timestamp + identity.IDENTITY_TRANSFER_DELAY());
        identity.finalizeIdentityTransfer(tid);

        // Hook never ran → no reentrancy surface; identity stayed with the legitimate recipient.
        assertFalse(recipient.hookRan());
        assertEq(identity.ownerOf(tid), address(recipient));
        assertEq(identity.ownerTokenId(address(recipient)), tid);
    }

    /// @dev Approvals are disabled outright (escrow-only / soulbound) so no misleading allowance can exist.
    function test_approvalsDisabled() public {
        (uint256 tid,) = _mint(alice);

        vm.prank(alice);
        vm.expectRevert(Series9Identity.ApprovalsDisabled.selector);
        identity.approve(bob, tid);

        vm.prank(alice);
        vm.expectRevert(Series9Identity.ApprovalsDisabled.selector);
        identity.setApprovalForAll(bob, true);
    }

    /// @dev predictWalletAddress reverts before the factory is configured (would otherwise return a
    ///      zero-impl-derived address that never matches the deployed wallet).
    function test_predictWalletAddressRevertsBeforeFactoryConfigured() public {
        Series9Identity legacyImpl = new Series9Identity();
        Series9Identity legacy = Series9Identity(
            address(
                new ERC1967Proxy(
                    address(legacyImpl),
                    abi.encodeCall(Series9Identity.initialize, (owner, address(ser9), address(staking), AI_FEE, HUMAN_FEE))
                )
            )
        );
        vm.expectRevert(Series9Identity.WalletNotConfigured.selector);
        legacy.predictWalletAddress(1);
    }

    /// @dev A revoked implementation can no longer be an upgrade target, even though its baseline version stays.
    function test_revokedImplCannotBeUpgradeTarget() public {
        (, Series9IdentityWallet wallet) = _mint(alice);
        WalletUpgradeTarget v2 = new WalletUpgradeTarget();
        identity.setWalletImplApproved(address(v2), 2);
        identity.revokeWalletImpl(address(v2));

        vm.prank(alice);
        vm.expectRevert(Series9Identity.WalletImplNotApproved.selector);
        wallet.upgradeToAndCall(address(v2), "");
    }

    /// @dev Versions are immutable once set, so re-numbering an approved impl (which could lower the
    ///      no-downgrade baseline) is rejected.
    function test_setWalletImplApprovedIsImmutable() public {
        WalletUpgradeTarget v2 = new WalletUpgradeTarget();
        identity.setWalletImplApproved(address(v2), 2);
        vm.expectRevert(Series9Identity.WalletImplAlreadyApproved.selector);
        identity.setWalletImplApproved(address(v2), 3);
    }

    function test_setWalletImplApprovedRejectsZeroVersionAndCodeless() public {
        WalletUpgradeTarget v2 = new WalletUpgradeTarget();
        vm.expectRevert(Series9Identity.WalletImplNotApproved.selector);
        identity.setWalletImplApproved(address(v2), 0);

        vm.expectRevert(Series9Identity.WalletNotConfigured.selector);
        identity.setWalletImplApproved(makeAddr("noCode"), 2);
    }

    /// @dev initializeWalletFactory (reinitializer 3) fails loud if payment storage was never initialized
    ///      (an ancient proxy at _initialized=1 whose initialize predates payment), rather than silently
    ///      bricking payments by advancing _initialized to 3. Simulated by zeroing the payment cursors.
    function test_initializeWalletFactoryRequiresPaymentInitialized() public {
        Series9Identity freshImpl = new Series9Identity();
        Series9Identity fresh = Series9Identity(
            address(
                new ERC1967Proxy(
                    address(freshImpl),
                    abi.encodeCall(Series9Identity.initialize, (owner, address(ser9), address(staking), AI_FEE, HUMAN_FEE))
                )
            )
        );
        // Force the pre-payment storage state (initialize() sets these; an old impl would not have).
        vm.store(address(fresh), bytes32(_NEXT_PAYMENT_ID_SLOT), bytes32(0));
        vm.store(address(fresh), bytes32(_NEXT_PAYMENT_REQUEST_ID_SLOT), bytes32(0));

        Series9IdentityWallet boot = new Series9IdentityWallet();
        vm.expectRevert(Series9Identity.PaymentNotInitialized.selector);
        fresh.initializeWalletFactory(address(boot));
    }
}
