// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Initializable} from "openzeppelin-contracts/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "openzeppelin-contracts/contracts/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "openzeppelin-contracts-upgradeable/contracts/access/OwnableUpgradeable.sol";

import {IncrementalMerkleTree} from "./private/IncrementalMerkleTree.sol";
import {ISeries9Groth16Verifier} from "./private/ISeries9Groth16Verifier.sol";

contract PrivateToken is Initializable, OwnableUpgradeable, UUPSUpgradeable {
    using IncrementalMerkleTree for IncrementalMerkleTree.Tree;

    uint32 public constant TREE_DEPTH = 20;

    struct Proof {
        uint256[2] a;
        uint256[2][2] b;
        uint256[2] c;
        uint256[] publicInputs;
    }

    struct Announcement {
        bytes32 stealthAddress;
        bytes ephemeralPubKey;
        bytes1 viewTag;
        uint64 blockNumber;
        uint32 leafIndex;
        bytes32 commitmentHash;
    }

    IncrementalMerkleTree.Tree private _tree;
    address public depositVerifier;
    address public withdrawVerifier;

    Announcement[] private _announcements;
    mapping(uint8 => uint256[]) private _announcementIndexesByViewTag;
    mapping(bytes32 => bool) public nullifierSpent;

    error DepositProofInvalid();
    error WithdrawProofInvalid();
    error NullifierAlreadySpent();
    error UnknownRoot();

    event DepositVerifierUpdated(address indexed previousVerifier, address indexed newVerifier);
    event WithdrawVerifierUpdated(address indexed previousVerifier, address indexed newVerifier);
    event PrivateDeposit(
        uint256 indexed leafIndex,
        bytes32 indexed commitmentHash,
        bytes32 indexed stealthAddress,
        bytes1 viewTag,
        bytes ephemeralPubKey,
        bytes32 merkleRoot
    );
    event PrivateWithdrawal(bytes32 indexed nullifierHash, bytes32 indexed merkleRoot, address indexed recipient, uint256 amount);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address initialOwner, address depositVerifier_, address withdrawVerifier_) external initializer {
        __Ownable_init(initialOwner);
        _tree.initialize(TREE_DEPTH);
        depositVerifier = depositVerifier_;
        withdrawVerifier = withdrawVerifier_;
    }

    function setDepositVerifier(address newVerifier) external onlyOwner {
        address previousVerifier = depositVerifier;
        depositVerifier = newVerifier;
        emit DepositVerifierUpdated(previousVerifier, newVerifier);
    }

    function setWithdrawVerifier(address newVerifier) external onlyOwner {
        address previousVerifier = withdrawVerifier;
        withdrawVerifier = newVerifier;
        emit WithdrawVerifierUpdated(previousVerifier, newVerifier);
    }

    function currentRoot() external view returns (bytes32) {
        return _tree.root;
    }

    function nextLeafIndex() external view returns (uint256) {
        return _tree.nextLeafIndex;
    }

    function announcementsLength() external view returns (uint256) {
        return _announcements.length;
    }

    function isKnownRoot(bytes32 root) external view returns (bool) {
        return _tree.isKnownRoot(root);
    }

    function deposit(
        bytes32 stealthAddress,
        bytes calldata ephemeralPubKey,
        bytes1 viewTag,
        bytes32 commitmentHash,
        Proof calldata proof
    ) external returns (uint256 leafIndex) {
        if (depositVerifier != address(0)) {
            bool verified = ISeries9Groth16Verifier(depositVerifier).verifyProof(proof.a, proof.b, proof.c, proof.publicInputs);
            if (!verified) revert DepositProofInvalid();
        }

        (leafIndex,) = _tree.insert(commitmentHash);

        Announcement memory announcement = Announcement({
            stealthAddress: stealthAddress,
            ephemeralPubKey: ephemeralPubKey,
            viewTag: viewTag,
            blockNumber: uint64(block.number),
            // forge-lint: disable-next-line(unsafe-typecast)
            leafIndex: uint32(leafIndex),
            commitmentHash: commitmentHash
        });
        _announcements.push(announcement);
        _announcementIndexesByViewTag[uint8(viewTag)].push(_announcements.length - 1);

        emit PrivateDeposit(leafIndex, commitmentHash, stealthAddress, viewTag, ephemeralPubKey, _tree.root);
    }

    function withdraw(bytes32 nullifierHash, bytes32 merkleRoot, address recipient, uint256 amount, Proof calldata proof)
        external
    {
        if (nullifierSpent[nullifierHash]) revert NullifierAlreadySpent();
        if (!_tree.isKnownRoot(merkleRoot)) revert UnknownRoot();

        if (withdrawVerifier != address(0)) {
            bool verified = ISeries9Groth16Verifier(withdrawVerifier).verifyProof(proof.a, proof.b, proof.c, proof.publicInputs);
            if (!verified) revert WithdrawProofInvalid();
        }

        nullifierSpent[nullifierHash] = true;
        emit PrivateWithdrawal(nullifierHash, merkleRoot, recipient, amount);
    }

    function getAnnouncementsByViewTag(bytes1 viewTag, uint256 fromBlock, uint256 limit)
        external
        view
        returns (Announcement[] memory items)
    {
        uint256[] storage indexes = _announcementIndexesByViewTag[uint8(viewTag)];
        uint256 count;

        for (uint256 i = 0; i < indexes.length; ++i) {
            if (_announcements[indexes[i]].blockNumber >= fromBlock) {
                ++count;
                if (limit != 0 && count == limit) {
                    break;
                }
            }
        }

        items = new Announcement[](count);
        uint256 cursor;
        for (uint256 i = 0; i < indexes.length && cursor < count; ++i) {
            Announcement storage announcement = _announcements[indexes[i]];
            if (announcement.blockNumber >= fromBlock) {
                items[cursor] = announcement;
                ++cursor;
            }
        }
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    uint256[45] private _gap;
}
