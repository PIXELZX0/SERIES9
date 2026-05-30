// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Script, console} from "forge-std/Script.sol";

import {Series9Identity} from "../src/Series9Identity.sol";

/// @notice Deploys a new Series9Identity implementation that ships the 8-slot character avatar feature,
///         and emits a Safe TX Builder JSON that upgrades the existing proxy via UUPS upgradeToAndCall.
///
/// Required env:
///   PRIVATE_KEY=0x...
///   IDENTITY_PROXY=0x...   the deployed ERC1967 proxy address
///
/// Optional env:
///   SKIP_VERIFY=true       skip on-chain source verification
///
/// Usage:
///   PRIVATE_KEY=0x... IDENTITY_PROXY=0x... forge script script/UpgradeIdentityAvatar.s.sol \
///     --rpc-url $MONAD_RPC_URL --broadcast --ffi --profile deploy
contract UpgradeIdentityAvatar is Script {
    string constant SOURCIFY_VERIFIER_URL = "https://sourcify-api-monad.blockvision.org";
    string constant SOCIALSCAN_VERIFIER_URL = "https://api.socialscan.io/monad/v1/explorer/command_api/contract";
    string constant CHAIN_ID = "143";

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address identityProxy = vm.envAddress("IDENTITY_PROXY");
        bool skipVerify = vm.envOr("SKIP_VERIFY", false);

        require(identityProxy.code.length > 0, "IDENTITY_PROXY must be a deployed contract");

        // --- Phase 1: Deploy new implementation ---
        vm.startBroadcast(deployerPrivateKey);
        Series9Identity newImpl = new Series9Identity();
        vm.stopBroadcast();

        address newImplAddr = address(newImpl);

        console.log("=== New Series9Identity Implementation Deployed ===");
        console.log("Identity Proxy:        ", identityProxy);
        console.log("New Implementation:    ", newImplAddr);

        // --- Phase 2: Optional verification ---
        if (skipVerify) {
            console.log("\n=== Skipping Verification (SKIP_VERIFY=true) ===");
        } else {
            console.log("\n=== Verifying New Implementation ===");
            _verify(newImplAddr, "src/Series9Identity.sol:Series9Identity");
        }

        // --- Phase 3: Emit Safe TX Builder JSON for UUPS upgradeToAndCall ---
        // No reinitializer needed: new avatarConfig mapping defaults to zero (baseline character).
        bytes memory upgradeCalldata = abi.encodeWithSignature("upgradeToAndCall(address,bytes)", newImplAddr, bytes(""));

        string memory json = string.concat(
            '{"version":"1.0","chainId":"',
            CHAIN_ID,
            '","meta":{"name":"Series9 Identity Avatar Upgrade","description":"Upgrade Series9Identity proxy to the implementation that ships the 8-slot character avatar feature"},"transactions":[{"to":"',
            vm.toString(identityProxy),
            '","value":"0","data":"',
            vm.toString(upgradeCalldata),
            '"}]}'
        );

        string memory outputPath = "safe-tx-upgrade-identity-avatar.json";
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.writeFile(outputPath, json);

        console.log("\n=== Safe Transaction Builder ===");
        console.log("Written:", outputPath);
        console.log("Import into: https://app.safe.global/transactions/tx-builder");
        console.log("\nThe Safe multisig that owns the proxy must sign and execute this transaction.");
    }

    function _verify(address contractAddr, string memory contractName) internal {
        // 1. Sourcify (Blockvision)
        string[] memory sourcifyCmd = new string[](12);
        sourcifyCmd[0] = "forge";
        sourcifyCmd[1] = "verify-contract";
        sourcifyCmd[2] = vm.toString(contractAddr);
        sourcifyCmd[3] = contractName;
        sourcifyCmd[4] = "--chain";
        sourcifyCmd[5] = CHAIN_ID;
        sourcifyCmd[6] = "--rpc-url";
        sourcifyCmd[7] = vm.envString("MONAD_RPC_URL");
        sourcifyCmd[8] = "--verifier";
        sourcifyCmd[9] = "sourcify";
        sourcifyCmd[10] = "--verifier-url";
        sourcifyCmd[11] = SOURCIFY_VERIFIER_URL;

        console.log("Verifying:", contractName, "at", contractAddr);
        // forge-lint: disable-next-line(unsafe-cheatcode)
        try vm.ffi(sourcifyCmd) returns (bytes memory result) {
            console.log("  [Sourcify] ", string(result));
        } catch {
            console.log("  [WARN] Sourcify verification failed");
        }

        // 2. SocialScan (Blockscout)
        string[] memory socialscanCmd = new string[](12);
        socialscanCmd[0] = "forge";
        socialscanCmd[1] = "verify-contract";
        socialscanCmd[2] = vm.toString(contractAddr);
        socialscanCmd[3] = contractName;
        socialscanCmd[4] = "--chain";
        socialscanCmd[5] = CHAIN_ID;
        socialscanCmd[6] = "--rpc-url";
        socialscanCmd[7] = vm.envString("MONAD_RPC_URL");
        socialscanCmd[8] = "--verifier";
        socialscanCmd[9] = "blockscout";
        socialscanCmd[10] = "--verifier-url";
        socialscanCmd[11] = SOCIALSCAN_VERIFIER_URL;

        // forge-lint: disable-next-line(unsafe-cheatcode)
        try vm.ffi(socialscanCmd) returns (bytes memory result2) {
            console.log("  [SocialScan] ", string(result2));
        } catch {
            console.log("  [WARN] SocialScan verification failed");
        }
    }
}
