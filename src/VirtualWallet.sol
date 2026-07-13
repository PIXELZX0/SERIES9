// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Initializable} from "openzeppelin-contracts/contracts/proxy/utils/Initializable.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";

interface IVirtualWalletManager {
    function isOperator(address account) external view returns (bool);
}

/// @notice Custodial smart-account for Discord users/guilds without an EOA.
/// Deployed behind a BeaconProxy by UserVirtualWalletManager (CREATE2,
/// salt = virtualId), so every wallet upgrades at once when the beacon
/// implementation changes. Authorization is delegated to the manager on every
/// call (mirrors Series9IdentityWallet's re-check-per-call pattern, with the
/// manager's operator role in place of an NFT owner).
contract VirtualWallet is Initializable, ReentrancyGuard {
    bytes32 public virtualId;
    address public manager;

    error Unauthorized();
    error CallFailed(bytes returnData);
    error LengthMismatch();
    error ZeroAddress();

    event Executed(address indexed to, uint256 value, bytes data, bytes result);
    event Received(address indexed from, uint256 amount);

    modifier onlyOperator() {
        if (!IVirtualWalletManager(manager).isOperator(msg.sender)) {
            revert Unauthorized();
        }
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(bytes32 virtualId_, address manager_) external initializer {
        if (manager_ == address(0)) {
            revert ZeroAddress();
        }
        virtualId = virtualId_;
        manager = manager_;
    }

    receive() external payable {
        emit Received(msg.sender, msg.value);
    }

    function execute(address to, uint256 value, bytes calldata data)
        external
        onlyOperator
        nonReentrant
        returns (bytes memory result)
    {
        result = _call(to, value, data);
        emit Executed(to, value, data, result);
    }

    function executeBatch(address[] calldata tos, uint256[] calldata values, bytes[] calldata datas)
        external
        onlyOperator
        nonReentrant
        returns (bytes[] memory results)
    {
        if (tos.length != values.length || tos.length != datas.length) {
            revert LengthMismatch();
        }
        results = new bytes[](tos.length);
        for (uint256 i = 0; i < tos.length; i++) {
            results[i] = _call(tos[i], values[i], datas[i]);
            emit Executed(tos[i], values[i], datas[i], results[i]);
        }
    }

    function _call(address to, uint256 value, bytes calldata data) internal returns (bytes memory) {
        (bool success, bytes memory returnData) = to.call{value: value}(data);
        if (!success) {
            revert CallFailed(returnData);
        }
        return returnData;
    }

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

    uint256[48] private _gap;
}
