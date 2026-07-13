// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Initializable} from "openzeppelin-contracts/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "openzeppelin-contracts/contracts/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "openzeppelin-contracts-upgradeable/contracts/access/OwnableUpgradeable.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Pull-based SER9 payment relay. Payers grant a one-time infinite
/// SER9 allowance to this contract; authorized operators then move funds from
/// payer wallets to the configured master wallet. Holds no funds itself.
contract LeoPayGate is Initializable, OwnableUpgradeable, UUPSUpgradeable {
    using SafeERC20 for IERC20;

    IERC20 public ser9;
    address public masterWallet;
    mapping(address => bool) public operators;

    error ZeroAddress();
    error ZeroAmount();
    error Unauthorized();

    event MasterWalletUpdated(address indexed previousMasterWallet, address indexed masterWallet);
    event OperatorUpdated(address indexed operator, bool allowed);
    event Paid(address indexed payer, address indexed masterWallet, uint256 amount, bytes32 indexed paymentRef);

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

    function initialize(address initialOwner, address ser9Token, address masterWallet_) external initializer {
        if (ser9Token == address(0) || masterWallet_ == address(0)) {
            revert ZeroAddress();
        }
        __Ownable_init(initialOwner);
        ser9 = IERC20(ser9Token);
        masterWallet = masterWallet_;
    }

    function setMasterWallet(address masterWallet_) external onlyOwner {
        if (masterWallet_ == address(0)) {
            revert ZeroAddress();
        }
        address previous = masterWallet;
        masterWallet = masterWallet_;
        emit MasterWalletUpdated(previous, masterWallet_);
    }

    function setOperator(address operator, bool allowed) external onlyOwner {
        if (operator == address(0)) {
            revert ZeroAddress();
        }
        operators[operator] = allowed;
        emit OperatorUpdated(operator, allowed);
    }

    /// @notice Pull `amount` SER9 from `payer` into the master wallet.
    /// @param paymentRef Off-chain reconciliation id (e.g. payment row id).
    /// ERC20 allowance/balance failures bubble up as OZ ERC20 custom errors.
    function pay(address payer, uint256 amount, bytes32 paymentRef) external onlyOperator {
        if (payer == address(0)) {
            revert ZeroAddress();
        }
        if (amount == 0) {
            revert ZeroAmount();
        }
        ser9.safeTransferFrom(payer, masterWallet, amount);
        emit Paid(payer, masterWallet, amount, paymentRef);
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    uint256[47] private _gap;
}
