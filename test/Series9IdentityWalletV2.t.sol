// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "forge-std/Test.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IERC1271} from "openzeppelin-contracts/contracts/interfaces/IERC1271.sol";
import {ECDSA} from "openzeppelin-contracts/contracts/utils/cryptography/ECDSA.sol";
import {Series9Identity} from "../src/Series9Identity.sol";
import {Series9IdentityWallet} from "../src/Series9IdentityWallet.sol";
import {Series9IdentityWalletV2} from "../src/Series9IdentityWalletV2.sol";
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

/// @dev A smart-contract identity holder that authorizes via ERC-1271 itself, used to prove the wallet's
///      ERC-1271 nests correctly when the NFT is held by another smart account.
contract ContractHolder {
    address public immutable signerOwner;

    constructor(address signerOwner_) {
        signerOwner = signerOwner_;
    }

    function approveAndMint(SER9Token ser9, Series9Identity id) external returns (uint256) {
        ser9.approve(address(id), type(uint256).max);
        return id.mintIdentity("CW", "", Series9Identity.EntityType.Human, 10, 10);
    }

    /// @dev Lets the test drive owner-only wallet calls (e.g. `upgradeToAndCall`) from this contract.
    function call(address to, bytes calldata data) external returns (bytes memory) {
        (bool ok, bytes memory res) = to.call(data);
        require(ok, "call failed");
        return res;
    }

    function isValidSignature(bytes32 hash, bytes calldata signature) external view returns (bytes4) {
        (address recovered, ECDSA.RecoverError err,) = ECDSA.tryRecover(hash, signature);
        if (err == ECDSA.RecoverError.NoError && recovered == signerOwner) {
            return IERC1271.isValidSignature.selector;
        }
        return 0xffffffff;
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }
}

contract Series9IdentityWalletV2Test is Test {
    Series9Identity public identity;
    SER9Token public ser9;
    MockStaking public staking;
    Series9IdentityWallet public bootstrap;
    Series9IdentityWalletV2 public v2Impl;

    address public owner;
    address public alice;
    uint256 public alicePk;
    address public carol;
    uint256 public carolPk;
    address public mallory;
    uint256 public malloryPk;

    uint256 constant AI_FEE = 10 ether;
    uint256 constant HUMAN_FEE = 50 ether;

    bytes4 constant MAGIC = IERC1271.isValidSignature.selector; // 0x1626ba7e
    bytes4 constant INVALID = 0xffffffff;

    function setUp() public {
        owner = address(this);
        (alice, alicePk) = makeAddrAndKey("alice");
        (carol, carolPk) = makeAddrAndKey("carol");
        (mallory, malloryPk) = makeAddrAndKey("mallory");

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

        // Configure the wallet factory (reinitializer(3)) and allowlist the v2 logic as version 2.
        bootstrap = new Series9IdentityWallet();
        identity.initializeWalletFactory(address(bootstrap));
        v2Impl = new Series9IdentityWalletV2();
        identity.setWalletImplApproved(address(v2Impl), 2);

        // Fund users.
        ser9.transfer(alice, 1000 ether);
        ser9.transfer(carol, 1000 ether);
        vm.prank(alice);
        ser9.approve(address(identity), type(uint256).max);
        vm.prank(carol);
        ser9.approve(address(identity), type(uint256).max);
    }

    // ─────────────────── Helpers ───────────────────

    /// @dev Mint an identity for `who` and upgrade its wallet to the ERC-1271 logic.
    function _mintV2(address who) internal returns (uint256 tid, Series9IdentityWalletV2 wallet) {
        vm.prank(who);
        tid = identity.mintIdentity("Name", "bio", Series9Identity.EntityType.Human, 100, 100);
        wallet = Series9IdentityWalletV2(payable(identity.walletOf(tid)));
        vm.prank(who);
        wallet.upgradeToAndCall(address(v2Impl), "");
    }

    function _sign(uint256 pk, bytes32 hash) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, hash);
        return abi.encodePacked(r, s, v);
    }

    /// @dev Run the full escrow transfer of `tid` to `to`.
    function _transferIdentity(uint256 tid, address from, address to) internal {
        vm.prank(from);
        identity.initiateIdentityTransfer(to);
        vm.prank(to);
        identity.acceptIdentityTransfer(tid);
        vm.warp(block.timestamp + identity.IDENTITY_TRANSFER_DELAY());
        identity.finalizeIdentityTransfer(tid);
    }

    // ─────────────────── Upgrade + layout ───────────────────

    function test_upgradeToV2PreservesStorage() public {
        vm.prank(alice);
        uint256 tid = identity.mintIdentity("Name", "bio", Series9Identity.EntityType.Human, 100, 100);
        Series9IdentityWalletV2 wallet = Series9IdentityWalletV2(payable(identity.walletOf(tid)));

        // v1 has no isValidSignature yet.
        (bool ok,) = address(wallet).staticcall(abi.encodeCall(IERC1271.isValidSignature, (bytes32(0), "")));
        assertFalse(ok);

        vm.prank(alice);
        wallet.upgradeToAndCall(address(v2Impl), "");

        assertEq(wallet.identity(), address(identity));
        assertEq(wallet.tokenId(), tid);
        // Slot 0 / slot 1 still hold identity + tokenId after the upgrade.
        assertEq(address(uint160(uint256(vm.load(address(wallet), bytes32(uint256(0)))))), address(identity));
        assertEq(uint256(vm.load(address(wallet), bytes32(uint256(1)))), tid);
    }

    function test_v2WalletStillExecutes() public {
        (, Series9IdentityWalletV2 wallet) = _mintV2(alice);
        address dest = makeAddr("dest");
        vm.deal(address(wallet), 1 ether);

        vm.prank(alice);
        wallet.execute(dest, 1 ether, "");
        assertEq(dest.balance, 1 ether);
    }

    // ─────────────────── ERC-1271 ───────────────────

    function test_isValidSignatureFromHolder() public {
        (, Series9IdentityWalletV2 wallet) = _mintV2(alice);
        bytes32 hash = keccak256("hello series9");

        assertEq(wallet.isValidSignature(hash, _sign(alicePk, hash)), MAGIC);
    }

    function test_isValidSignatureFromNonHolder() public {
        (, Series9IdentityWalletV2 wallet) = _mintV2(alice);
        bytes32 hash = keccak256("hello series9");

        assertEq(wallet.isValidSignature(hash, _sign(malloryPk, hash)), INVALID);
    }

    function test_isValidSignatureWrongHash() public {
        (, Series9IdentityWalletV2 wallet) = _mintV2(alice);
        bytes32 hash = keccak256("hello series9");
        bytes memory sig = _sign(alicePk, hash);

        assertEq(wallet.isValidSignature(keccak256("other message"), sig), INVALID);
    }

    function test_isValidSignatureMalformedReturnsInvalid() public {
        (, Series9IdentityWalletV2 wallet) = _mintV2(alice);
        bytes32 hash = keccak256("hello series9");

        assertEq(wallet.isValidSignature(hash, ""), INVALID);
        assertEq(wallet.isValidSignature(hash, hex"deadbeef"), INVALID);
        // 65 bytes of garbage: recovers to some address, but never the holder.
        assertEq(wallet.isValidSignature(hash, new bytes(65)), INVALID);
    }

    function test_isValidSignatureBlockedDuringTransferFreeze() public {
        (uint256 tid, Series9IdentityWalletV2 wallet) = _mintV2(alice);
        bytes32 hash = keccak256("hello series9");
        bytes memory sig = _sign(alicePk, hash);

        assertEq(wallet.isValidSignature(hash, sig), MAGIC);

        vm.prank(alice);
        identity.initiateIdentityTransfer(carol); // Pending → wallet frozen
        assertEq(wallet.isValidSignature(hash, sig), INVALID);

        vm.prank(carol);
        identity.acceptIdentityTransfer(tid); // Accepted → still frozen
        assertEq(wallet.isValidSignature(hash, sig), INVALID);
    }

    function test_signingAuthorityFollowsIdentity() public {
        (uint256 tid, Series9IdentityWalletV2 wallet) = _mintV2(alice);
        bytes32 hash = keccak256("hello series9");

        _transferIdentity(tid, alice, carol);

        // New holder signs; old holder cannot.
        assertEq(wallet.isValidSignature(hash, _sign(carolPk, hash)), MAGIC);
        assertEq(wallet.isValidSignature(hash, _sign(alicePk, hash)), INVALID);
    }

    function test_isValidSignatureCancelledTransferUnfreezes() public {
        (uint256 tid, Series9IdentityWalletV2 wallet) = _mintV2(alice);
        bytes32 hash = keccak256("hello series9");
        bytes memory sig = _sign(alicePk, hash);

        vm.prank(alice);
        identity.initiateIdentityTransfer(carol);
        assertEq(wallet.isValidSignature(hash, sig), INVALID);

        vm.prank(alice);
        identity.cancelIdentityTransfer(tid);
        assertEq(wallet.isValidSignature(hash, sig), MAGIC);
    }

    function test_isValidSignatureContractHolderNested() public {
        (address inner, uint256 innerPk) = makeAddrAndKey("innerSigner");
        ContractHolder holder = new ContractHolder(inner);
        ser9.transfer(address(holder), 1000 ether);

        uint256 tid = holder.approveAndMint(ser9, identity);
        Series9IdentityWalletV2 wallet = Series9IdentityWalletV2(payable(identity.walletOf(tid)));
        holder.call(address(wallet), abi.encodeCall(wallet.upgradeToAndCall, (address(v2Impl), "")));

        bytes32 hash = keccak256("nested 1271");
        // The holder contract validates the inner key's signature; the wallet must defer to it.
        assertEq(wallet.isValidSignature(hash, _sign(innerPk, hash)), MAGIC);
        assertEq(wallet.isValidSignature(hash, _sign(malloryPk, hash)), INVALID);
    }
}
