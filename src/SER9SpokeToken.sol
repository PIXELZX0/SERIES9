// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Initializable} from "openzeppelin-contracts/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "openzeppelin-contracts/contracts/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "openzeppelin-contracts-upgradeable/contracts/access/OwnableUpgradeable.sol";
import {ERC20Upgradeable} from "openzeppelin-contracts-upgradeable/contracts/token/ERC20/ERC20Upgradeable.sol";
import {ERC20BurnableUpgradeable} from
    "openzeppelin-contracts-upgradeable/contracts/token/ERC20/extensions/ERC20BurnableUpgradeable.sol";
import {INttToken} from "./interfaces/INttToken.sol";

/// @notice SER9 on EVM spoke chains (Base first). Supply exists only via Wormhole NTT:
/// the spoke NttManager (burning mode) is the sole minter; Monad SER9 is locked on the hub.
/// Invariant: hub locked SER9 >= sum of spoke totalSupply.
contract SER9SpokeToken is
    Initializable,
    ERC20Upgradeable,
    ERC20BurnableUpgradeable,
    OwnableUpgradeable,
    UUPSUpgradeable,
    INttToken
{
    address public minter;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @dev No initial supply. Minter is unset until the NttManager is deployed and `setMinter` is called.
    function initialize(address initialOwner) external initializer {
        __ERC20_init("SERIES9", "SER9");
        __ERC20Burnable_init();
        __Ownable_init(initialOwner);
    }

    function setMinter(address newMinter) external onlyOwner {
        if (newMinter == address(0)) {
            revert InvalidMinterZeroAddress();
        }

        emit NewMinter(minter, newMinter);
        minter = newMinter;
    }

    function mint(address account, uint256 amount) external {
        if (msg.sender != minter) {
            revert CallerNotMinter(msg.sender);
        }

        _mint(account, amount);
    }

    function burn(uint256 amount) public override(ERC20BurnableUpgradeable, INttToken) {
        super.burn(amount);
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    uint256[49] private _gap;
}
