// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Initializable} from "openzeppelin-contracts/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "openzeppelin-contracts/contracts/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "openzeppelin-contracts-upgradeable/contracts/access/OwnableUpgradeable.sol";
import {BeaconProxy} from "openzeppelin-contracts/contracts/proxy/beacon/BeaconProxy.sol";
import {UpgradeableBeacon} from "openzeppelin-contracts/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {VirtualWallet} from "./VirtualWallet.sol";

/// @notice Factory/registry for custodial VirtualWallets, keyed by an opaque
/// virtualId (e.g. keccak256("discord:user:<id>") / keccak256("discord:guild:<id>")).
/// Wallets are BeaconProxies deployed via CREATE2 (salt = virtualId) — addresses
/// are predictable before deployment and survive implementation upgrades, since
/// the proxy init-code only embeds the (fixed) beacon address.
///
/// This contract must own the UpgradeableBeacon so upgradeWalletImplementation
/// can rotate every wallet's implementation in a single transaction.
contract UserVirtualWalletManager is Initializable, OwnableUpgradeable, UUPSUpgradeable {
    address public beacon;
    mapping(bytes32 => address) public walletOf;
    mapping(address => bool) public operators;

    error ZeroAddress();
    error InvalidBeacon();
    error Unauthorized();
    error AlreadyExists();

    event WalletCreated(bytes32 indexed virtualId, address indexed wallet);
    event OperatorUpdated(address indexed operator, bool allowed);
    event WalletImplementationUpgraded(address indexed previousImplementation, address indexed newImplementation);

    modifier onlyOperator() {
        if (!operators[msg.sender] && msg.sender != owner()) {
            revert Unauthorized();
        }
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address initialOwner, address beacon_) external initializer {
        if (beacon_ == address(0) || beacon_.code.length == 0) {
            revert InvalidBeacon();
        }
        __Ownable_init(initialOwner);
        beacon = beacon_;
    }

    function createVirtualWallet(bytes32 virtualId) external onlyOperator returns (address wallet) {
        if (walletOf[virtualId] != address(0)) {
            revert AlreadyExists();
        }
        wallet = address(new BeaconProxy{salt: virtualId}(beacon, _initCalldata(virtualId)));
        walletOf[virtualId] = wallet;
        emit WalletCreated(virtualId, wallet);
    }

    /// @notice CREATE2 address for a virtualId's wallet, valid before deployment
    /// and stable across implementation upgrades (init-code embeds only the beacon).
    function predictVirtualWalletAddress(bytes32 virtualId) external view returns (address) {
        bytes32 initCodeHash =
            keccak256(abi.encodePacked(type(BeaconProxy).creationCode, abi.encode(beacon, _initCalldata(virtualId))));
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), virtualId, initCodeHash)))));
    }

    /// @notice Upgrade every VirtualWallet at once via the shared beacon.
    /// Requires this contract to be the beacon's owner.
    function upgradeWalletImplementation(address newImplementation) external onlyOwner {
        if (newImplementation == address(0) || newImplementation.code.length == 0) {
            revert ZeroAddress();
        }
        UpgradeableBeacon upgradeableBeacon = UpgradeableBeacon(beacon);
        address previous = upgradeableBeacon.implementation();
        upgradeableBeacon.upgradeTo(newImplementation);
        emit WalletImplementationUpgraded(previous, newImplementation);
    }

    /// @notice Authorization callback used by VirtualWallet.execute/executeBatch.
    function isOperator(address account) external view returns (bool) {
        return operators[account] || account == owner();
    }

    function setOperator(address operator, bool allowed) external onlyOwner {
        if (operator == address(0)) {
            revert ZeroAddress();
        }
        operators[operator] = allowed;
        emit OperatorUpdated(operator, allowed);
    }

    function _initCalldata(bytes32 virtualId) internal view returns (bytes memory) {
        return abi.encodeCall(VirtualWallet.initialize, (virtualId, address(this)));
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    uint256[47] private _gap;
}
