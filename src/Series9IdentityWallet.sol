// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Initializable} from "openzeppelin-contracts/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "openzeppelin-contracts/contracts/proxy/utils/UUPSUpgradeable.sol";
import {ERC1967Utils} from "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";

/// @notice The subset of Series9Identity the wallet relies on for authorization.
/// @dev All wallet authority is vested in the identity NFT — never in an EOA. Both hooks
///      resolve permission against the *current* `ownerOf(tokenId)` so control follows the NFT.
interface ISeries9IdentityForWallet {
    /// @dev Reverts unless `operator` currently owns `tokenId` and the wallet is not frozen by a pending transfer.
    function authorizeWalletCall(uint256 tokenId, address operator) external view;
    /// @dev Reverts unless `operator` owns `tokenId`, `newImpl` is allowlisted with a strictly
    ///      higher version than `currentImpl`, and the wallet is not frozen by a pending transfer.
    function authorizeWalletUpgrade(uint256 tokenId, address operator, address currentImpl, address newImpl)
        external
        view;
}

/// @title Series9IdentityWallet
/// @notice A per-identity smart-account wallet. Each Series9Identity NFT owns exactly one of these
///         (a UUPS proxy at a `tokenId`-derived address). It behaves like a real EVM account: it holds
///         native MON and any ERC20/NFT, can send arbitrary calls (`execute`), and can deploy contracts
///         (CREATE / CREATE2).
/// @dev Authority is delegated entirely to the Series9Identity contract, which gates every operation on
///      the live `ownerOf(tokenId)`. The wallet stores no owner address, so on NFT transfer the new holder
///      inherits all authority and the old holder is de-authorized atomically. Logic is upgradeable only by
///      the current NFT holder and only to an identity-allowlisted, strictly-newer implementation.
contract Series9IdentityWallet is Initializable, UUPSUpgradeable, ReentrancyGuard {
    /// @notice Series9Identity proxy this wallet is bound to.
    address public identity;
    /// @notice The identity NFT id that controls this wallet.
    uint256 public tokenId;

    error CallFailed(bytes returnData);
    error DeployFailed();
    error LengthMismatch();

    event Executed(address indexed to, uint256 value, bytes data, bytes result);
    event ContractDeployed(address indexed deployed, uint256 value);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize a freshly-cloned wallet proxy. Called once by the factory in the same tx as deploy.
    function initialize(address identity_, uint256 tokenId_) external initializer {
        identity = identity_;
        tokenId = tokenId_;
    }

    // Accept native MON. Kept free of any LOG/SSTORE so a plain `.transfer()`/`.send()` (2300-gas stipend)
    // into the wallet never reverts — the wallet must fund as cheaply as a regular account.
    receive() external payable {}

    /// @dev Gate every outbound operation on the identity contract (owner + freeze check).
    modifier onlyOperator() {
        ISeries9IdentityForWallet(identity).authorizeWalletCall(tokenId, msg.sender);
        _;
    }

    /// @notice Send an arbitrary call (optionally with native value) from this wallet.
    function execute(address to, uint256 value, bytes calldata data)
        external
        onlyOperator
        nonReentrant
        returns (bytes memory result)
    {
        bool ok;
        (ok, result) = to.call{value: value}(data);
        if (!ok) revert CallFailed(result);
        emit Executed(to, value, data, result);
    }

    /// @notice Send a batch of arbitrary calls atomically.
    function executeBatch(address[] calldata tos, uint256[] calldata values, bytes[] calldata datas)
        external
        onlyOperator
        nonReentrant
        returns (bytes[] memory results)
    {
        uint256 n = tos.length;
        if (n != values.length || n != datas.length) revert LengthMismatch();
        results = new bytes[](n);
        for (uint256 i; i < n; ++i) {
            (bool ok, bytes memory res) = tos[i].call{value: values[i]}(datas[i]);
            if (!ok) revert CallFailed(res);
            results[i] = res;
            emit Executed(tos[i], values[i], datas[i], res);
        }
    }

    /// @notice Deploy a contract from this wallet via CREATE.
    function deployContract(uint256 value, bytes calldata bytecode)
        external
        onlyOperator
        nonReentrant
        returns (address deployed)
    {
        bytes memory code = bytecode;
        assembly ("memory-safe") {
            deployed := create(value, add(code, 0x20), mload(code))
        }
        if (deployed == address(0)) revert DeployFailed();
        emit ContractDeployed(deployed, value);
    }

    /// @notice Deploy a contract from this wallet via CREATE2 (deterministic address).
    function deployContract2(bytes32 salt, uint256 value, bytes calldata bytecode)
        external
        onlyOperator
        nonReentrant
        returns (address deployed)
    {
        bytes memory code = bytecode;
        assembly ("memory-safe") {
            deployed := create2(value, add(code, 0x20), mload(code), salt)
        }
        if (deployed == address(0)) revert DeployFailed();
        emit ContractDeployed(deployed, value);
    }

    // ─────────────────── Token receiver hooks (so the wallet can hold NFTs) ───────────────────

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(address, address, uint256[] calldata, uint256[] calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return this.onERC1155BatchReceived.selector;
    }

    /// @dev Upgrade authority lives with the NFT. The identity contract enforces: caller owns the NFT,
    ///      `newImpl` is allowlisted with a strictly higher version, and no transfer is freezing the wallet.
    function _authorizeUpgrade(address newImplementation) internal view override {
        ISeries9IdentityForWallet(identity).authorizeWalletUpgrade(
            tokenId, msg.sender, ERC1967Utils.getImplementation(), newImplementation
        );
    }

    /// @dev Reserved storage so future wallet versions can append state without colliding with the proxy's
    ///      existing linear layout (slot 0 `identity`, slot 1 `tokenId`; the inherited bases use ERC-7201
    ///      namespaced storage and occupy no linear slot here).
    uint256[50] private __gap;
}
