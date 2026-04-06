// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Initializable} from "openzeppelin-contracts/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "openzeppelin-contracts/contracts/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "openzeppelin-contracts-upgradeable/contracts/access/OwnableUpgradeable.sol";
import {ERC20Upgradeable} from "openzeppelin-contracts-upgradeable/contracts/token/ERC20/ERC20Upgradeable.sol";

contract Series9ManagedToken is Initializable, ERC20Upgradeable, OwnableUpgradeable, UUPSUpgradeable {
    uint16 public constant MAX_FEE_BPS = 1_000;
    uint16 private constant BPS_DENOMINATOR = 10_000;

    bool public feeEnabled;
    uint16 public feeBps;
    address public feeRecipient;

    mapping(address => bool) public isFeeExempt;

    error FeeDisabled();
    error FeeTooHigh();
    error InvalidFeeRecipient();
    error InvalidFeeConfiguration();

    event FeeBpsUpdated(uint16 feeBps);
    event FeeRecipientUpdated(address indexed previousRecipient, address indexed newRecipient);
    event FeeExemptUpdated(address indexed account, bool isExempt);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        string memory name_,
        string memory symbol_,
        address initialOwner,
        bool feeEnabled_,
        uint16 initialFeeBps,
        address feeRecipient_
    ) external initializer {
        __ERC20_init(name_, symbol_);
        __Ownable_init(initialOwner);

        if (feeRecipient_ == address(0)) {
            revert InvalidFeeRecipient();
        }

        feeEnabled = feeEnabled_;
        feeRecipient = feeRecipient_;

        if (!feeEnabled_ && initialFeeBps != 0) {
            revert InvalidFeeConfiguration();
        }

        _setFeeBps(initialFeeBps);

        // staking contract transfers should not be charged a fee
        isFeeExempt[feeRecipient_] = true;
        emit FeeExemptUpdated(feeRecipient_, true);
    }

    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }

    function burnFromAccount(address user, uint256 amount) external onlyOwner {
        _burn(user, amount);
    }

    function setFeeBps(uint16 newFeeBps) external onlyOwner {
        if (!feeEnabled) {
            revert FeeDisabled();
        }

        _setFeeBps(newFeeBps);
    }

    function setFeeRecipient(address newFeeRecipient) external onlyOwner {
        if (newFeeRecipient == address(0)) {
            revert InvalidFeeRecipient();
        }

        address previousRecipient = feeRecipient;
        feeRecipient = newFeeRecipient;
        emit FeeRecipientUpdated(previousRecipient, newFeeRecipient);
    }

    function setFeeExempt(address account, bool exempt) external onlyOwner {
        isFeeExempt[account] = exempt;
        emit FeeExemptUpdated(account, exempt);
    }

    function _setFeeBps(uint16 newFeeBps) internal {
        if (newFeeBps > MAX_FEE_BPS) {
            revert FeeTooHigh();
        }

        feeBps = newFeeBps;
        emit FeeBpsUpdated(newFeeBps);
    }

    function _update(address from, address to, uint256 value) internal virtual override {
        if (
            !feeEnabled || from == address(0) || to == address(0) || feeBps == 0 || isFeeExempt[from] || isFeeExempt[to]
        ) {
            super._update(from, to, value);
            return;
        }

        uint256 feeAmount = (value * feeBps) / BPS_DENOMINATOR;
        if (feeAmount == 0) {
            super._update(from, to, value);
            return;
        }

        uint256 netAmount = value - feeAmount;
        super._update(from, feeRecipient, feeAmount);
        super._update(from, to, netAmount);
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    uint256[48] private __gap;
}
