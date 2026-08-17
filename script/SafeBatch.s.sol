// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Script, console} from "forge-std/Script.sol";

import {Base64} from "openzeppelin-contracts/contracts/utils/Base64.sol";

import {SER9Token} from "../src/SER9Token.sol";
import {Series9Staking} from "../src/Series9Staking.sol";

/// @notice Generates Safe Transaction Builder JSON for admin operations.
///
/// All Staking admin functions require the Safe multisig to execute.
/// This script generates a JSON file that can be imported directly
/// into the Safe{Wallet} Transaction Builder app.
///
/// Usage:
///   STAKING_PROXY=0x... forge script script/SafeBatch.s.sol:SafeSetRewardRate \
///     --sig "run(uint256)" 0.5ether -vvv
///
///   Then import the generated JSON at:
///   https://app.safe.global/transactions/tx-builder
contract SafeBatchBase is Script {
    string constant CHAIN_ID = "143";

    function _header() internal pure returns (string memory) {
        return string.concat(
            '{"version":"1.0","chainId":"',
            CHAIN_ID,
            '","meta":{"name":"Series9 Admin","description":"Series9 Staking admin batch"},"transactions":['
        );
    }

    function _tx(address to, bytes memory data) internal pure returns (string memory) {
        return string.concat(
            '{"to":"',
            vm.toString(to),
            '","value":"0","data":"',
            vm.toString(data),
            '"}'
        );
    }

    function _writeBatch(string memory name, string memory txs) internal {
        string memory json = string.concat(_header(), txs, "]}");
        string memory path = string.concat("safe-tx-", name, ".json");
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.writeFile(path, json);
        console.log("Written:", path);
        console.log("Import into Safe Transaction Builder: https://app.safe.global/transactions/tx-builder");
    }

    function _staking() internal view returns (address) {
        return vm.envAddress("STAKING_PROXY");
    }
}

/// @notice Set reward rate per block
/// Usage: STAKING_PROXY=0x... forge script script/SafeBatch.s.sol:SafeSetRewardRate --sig "run(uint256)" <newRate>
contract SafeSetRewardRate is SafeBatchBase {
    function run(uint256 newRate) external {
        address staking = _staking();
        console.log("Staking:", staking);
        console.log("New reward rate:", newRate);

        _writeBatch(
            "set-reward-rate",
            _tx(staking, abi.encodeCall(Series9Staking.setRewardRatePerBlock, (newRate)))
        );
    }
}

/// @notice Set token creation fee
/// Usage: STAKING_PROXY=0x... forge script script/SafeBatch.s.sol:SafeSetCreationFee --sig "run(uint256)" <newFee>
contract SafeSetCreationFee is SafeBatchBase {
    function run(uint256 newFee) external {
        address staking = _staking();
        console.log("Staking:", staking);
        console.log("New creation fee:", newFee);

        _writeBatch(
            "set-creation-fee",
            _tx(staking, abi.encodeCall(Series9Staking.setTokenCreationFee, (newFee)))
        );
    }
}

/// @notice Pause all user operations
/// Usage: STAKING_PROXY=0x... forge script script/SafeBatch.s.sol:SafePause
contract SafePause is SafeBatchBase {
    function run() external {
        address staking = _staking();
        _writeBatch("pause", _tx(staking, abi.encodeCall(Series9Staking.pause, ())));
    }
}

/// @notice Unpause all user operations
/// Usage: STAKING_PROXY=0x... forge script script/SafeBatch.s.sol:SafeUnpause
contract SafeUnpause is SafeBatchBase {
    function run() external {
        address staking = _staking();
        _writeBatch("unpause", _tx(staking, abi.encodeCall(Series9Staking.unpause, ())));
    }
}

/// @notice Upgrade SER9 implementation via Safe batch
/// Usage:
///   STAKING_PROXY=0x... forge script script/SafeBatch.s.sol:SafeUpgradeTokens \
///     --sig "run(address)" <newSer9Impl>
contract SafeUpgradeTokens is SafeBatchBase {
    function run(address newSer9Impl) external {
        address staking = _staking();
        console.log("Staking:", staking);
        console.log("New SER9 impl:", newSer9Impl);

        _writeBatch(
            "upgrade-tokens",
            _tx(staking, abi.encodeCall(Series9Staking.upgradeSer9, (newSer9Impl, bytes(""))))
        );
    }
}

/// @notice Batch multiple admin operations into one Safe transaction
/// Usage:
///   STAKING_PROXY=0x... forge script script/SafeBatch.s.sol:SafeCustomBatch \
///     --sig "run(uint256,uint256)" <newRewardRate> <newCreationFee>
contract SafeCustomBatch is SafeBatchBase {
    function run(uint256 newRewardRate, uint256 newCreationFee) external {
        address staking = _staking();
        console.log("Staking:", staking);

        string memory txs = string.concat(
            _tx(staking, abi.encodeCall(Series9Staking.setRewardRatePerBlock, (newRewardRate))),
            ",",
            _tx(staking, abi.encodeCall(Series9Staking.setTokenCreationFee, (newCreationFee)))
        );

        _writeBatch("custom-batch", txs);
    }
}

/// @notice Set ERC-20M token metadata (image + description) on the SER9 proxy.
///
/// The image is inlined as a base64 data: URI built from assets/series9-logo.svg,
/// so the logo has no host dependency. The SVG is ~2.6KB, so the encoded string is
/// ~3.5KB of onchain storage — budget for it.
///
/// Usage:
///   SER9_PROXY=0x... forge script script/SafeBatch.s.sol:SafeSetTokenMetadata \
///     --sig "run(string)" "SERIES9 staking token"
contract SafeSetTokenMetadata is SafeBatchBase {
    function run(string calldata description_) external {
        address ser9 = vm.envAddress("SER9_PROXY");
        // forge-lint: disable-next-line(unsafe-cheatcode)
        string memory svg = vm.readFile("assets/series9-logo.svg");
        string memory image = string.concat("data:image/svg+xml;base64,", Base64.encode(bytes(svg)));

        console.log("SER9:", ser9);
        console.log("Image URI bytes:", bytes(image).length);
        console.log("Description:", description_);

        _writeBatch(
            "set-token-metadata",
            _tx(ser9, abi.encodeCall(SER9Token.setTokenMetadata, (image, description_)))
        );
    }
}
