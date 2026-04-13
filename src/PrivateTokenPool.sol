// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Initializable} from "openzeppelin-contracts/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "openzeppelin-contracts/contracts/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {OwnableUpgradeable} from "openzeppelin-contracts-upgradeable/contracts/access/OwnableUpgradeable.sol";

import {PrivateToken} from "./PrivateToken.sol";

contract PrivateTokenPool is Initializable, OwnableUpgradeable, UUPSUpgradeable {
    using SafeERC20 for IERC20;

    IERC20 public ser9;
    PrivateToken public privateToken;

    error InvalidTokenAddress();
    error InvalidPrivateTokenAddress();

    event Shielded(
        address indexed sender,
        uint256 indexed leafIndex,
        bytes32 indexed commitmentHash,
        bytes32 stealthAddress,
        uint256 amount
    );
    event Unshielded(address indexed recipient, bytes32 indexed nullifierHash, bytes32 indexed merkleRoot, uint256 amount);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address initialOwner, address ser9Token, address privateTokenAddress) external initializer {
        if (ser9Token == address(0) || ser9Token.code.length == 0) revert InvalidTokenAddress();
        if (privateTokenAddress == address(0) || privateTokenAddress.code.length == 0) {
            revert InvalidPrivateTokenAddress();
        }

        __Ownable_init(initialOwner);

        ser9 = IERC20(ser9Token);
        privateToken = PrivateToken(privateTokenAddress);
    }

    function shield(
        bytes32 stealthAddress,
        bytes calldata ephemeralPubKey,
        bytes1 viewTag,
        bytes32 commitmentHash,
        uint256 amount,
        PrivateToken.Proof calldata proof
    ) external returns (uint256 leafIndex) {
        ser9.safeTransferFrom(msg.sender, address(this), amount);
        leafIndex = privateToken.deposit(stealthAddress, ephemeralPubKey, viewTag, commitmentHash, proof);
        emit Shielded(msg.sender, leafIndex, commitmentHash, stealthAddress, amount);
    }

    function unshield(bytes32 nullifierHash, bytes32 merkleRoot, address recipient, uint256 amount, PrivateToken.Proof calldata proof)
        external
    {
        privateToken.withdraw(nullifierHash, merkleRoot, recipient, amount, proof);
        ser9.safeTransfer(recipient, amount);
        emit Unshielded(recipient, nullifierHash, merkleRoot, amount);
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    uint256[48] private _gap;
}
