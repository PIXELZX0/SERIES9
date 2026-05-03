// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Initializable} from "openzeppelin-contracts/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "openzeppelin-contracts/contracts/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "openzeppelin-contracts-upgradeable/contracts/access/OwnableUpgradeable.sol";
import {ERC20Upgradeable} from "openzeppelin-contracts-upgradeable/contracts/token/ERC20/ERC20Upgradeable.sol";

contract SER9Token is Initializable, ERC20Upgradeable, OwnableUpgradeable, UUPSUpgradeable {
    uint256 public constant INITIAL_SUPPLY = 1_000_000_000_000 ether;

    address public stakingContract;

    error InvalidStakingAddress();
    error UnauthorizedMinter();

    event StakingContractSet(address indexed previousStakingContract, address indexed stakingContractAddress);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address initialOwner) external initializer {
        __ERC20_init("SERIES9", "SER9");
        __Ownable_init(initialOwner);
        _mint(initialOwner, INITIAL_SUPPLY);
    }

    function setStakingContract(address stakingContractAddress) external onlyOwner {
        if (stakingContractAddress == address(0) || stakingContractAddress.code.length == 0) {
            revert InvalidStakingAddress();
        }

        address previousStaking = stakingContract;
        stakingContract = stakingContractAddress;
        emit StakingContractSet(previousStaking, stakingContractAddress);
    }

    function mint(address to, uint256 amount) external {
        if (msg.sender != stakingContract) {
            revert UnauthorizedMinter();
        }

        _mint(to, amount);
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    uint256[49] private _gap;
}
