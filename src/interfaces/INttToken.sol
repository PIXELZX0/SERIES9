// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

/// @notice Wormhole NTT token interface (mirrors wormhole-foundation/native-token-transfers evm/src/interfaces/INttToken.sol).
/// NttManager in burning mode calls `burn` on tokens it holds and `mint` on inbound transfers.
interface INttToken {
    error CallerNotMinter(address caller);
    error InvalidMinterZeroAddress();

    event NewMinter(address previousMinter, address newMinter);

    function mint(address account, uint256 amount) external;

    function setMinter(address newMinter) external;

    function burn(uint256 amount) external;
}
