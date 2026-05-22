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
    string constant VERIFIER_URL = "https://sourcify-api-monad.blockvision.org/api";
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
        string[] memory cmd = new string[](12);
        cmd[0] = "forge";
        cmd[1] = "verify-contract";
        cmd[2] = vm.toString(contractAddr);
        cmd[3] = contractName;
        cmd[4] = "--chain";
        cmd[5] = CHAIN_ID;
        cmd[6] = "--rpc-url";
        cmd[7] = vm.envString("MONAD_RPC_URL");
        cmd[8] = "--verifier";
        cmd[9] = "sourcify";
        cmd[10] = "--verifier-url";
        cmd[11] = VERIFIER_URL;

        console.log("Verifying:", contractName, "at", contractAddr);
        // forge-lint: disable-next-line(unsafe-cheatcode)
        try vm.ffi(cmd) returns (bytes memory result) {
            console.log(string(result));
        } catch {
            console.log("  [WARN] Sourcify verification failed, verify manually");
        }
    }
}
