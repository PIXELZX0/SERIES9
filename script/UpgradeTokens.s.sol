// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Script, console} from "forge-std/Script.sol";

import {SER9Token} from "../src/SER9Token.sol";
import {Series9ManagedToken} from "../src/Series9ManagedToken.sol";
import {Series9Staking} from "../src/Series9Staking.sol";

/// @notice Deploys new implementation contracts and outputs the Safe TX Builder JSON
///         for upgrading via the Safe multisig.
///
/// Flow:
///   1. Deployer EOA deploys new implementation contracts (just code, no privileges)
///   2. Script outputs a Safe TX Builder JSON for the upgradeTokens() call
///   3. Import JSON into Safe{Wallet} → multisig signs → executes upgrade
///
/// Usage:
///   PRIVATE_KEY=0x... STAKING_PROXY=0x... forge script script/UpgradeTokens.s.sol \
///     --rpc-url $MONAD_RPC_URL --broadcast --ffi --profile deploy
contract UpgradeTokens is Script {
    string constant VERIFIER_URL = "https://api.socialscan.io/monad/v1/explorer/command_api/contract";
    string constant CHAIN_ID = "143";

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address stakingProxy = vm.envAddress("STAKING_PROXY");
        bool skipVerify = vm.envOr("SKIP_VERIFY", false);

        string memory ser9DataHex = vm.envOr("SER9_UPGRADE_DATA", string(""));
        string memory managedDataHex = vm.envOr("MANAGED_UPGRADE_DATA", string(""));
        bytes memory ser9Data = bytes(ser9DataHex).length == 0 ? bytes("") : vm.parseBytes(ser9DataHex);
        bytes memory managedData = bytes(managedDataHex).length == 0 ? bytes("") : vm.parseBytes(managedDataHex);

        // --- Phase 1: Deploy new implementations (deployer EOA, no privileges) ---
        vm.startBroadcast(deployerPrivateKey);

        address newSer9Implementation = address(new SER9Token());
        address newManagedImplementation = address(new Series9ManagedToken());

        vm.stopBroadcast();

        console.log("=== New Implementations Deployed ===");
        console.log("New SER9 Implementation:", newSer9Implementation);
        console.log("New Managed Implementation:", newManagedImplementation);
        console.log("Staking Proxy:", stakingProxy);

        // --- Phase 2: Verify new implementations (optional) ---
        if (skipVerify) {
            console.log("\n=== Skipping Verification (SKIP_VERIFY=true) ===");
        } else {
            console.log("\n=== Verifying New Implementations ===");
            _verify(newSer9Implementation, "src/SER9Token.sol:SER9Token");
            _verify(newManagedImplementation, "src/Series9ManagedToken.sol:Series9ManagedToken");
        }

        // --- Phase 3: Generate Safe TX Builder JSON ---
        bytes memory upgradeCalldata = abi.encodeCall(
            Series9Staking.upgradeTokens,
            (newSer9Implementation, newManagedImplementation, ser9Data, managedData)
        );

        string memory json = string.concat(
            '{"version":"1.0","chainId":"',
            CHAIN_ID,
            '","meta":{"name":"Series9 Upgrade","description":"Upgrade SER9 and managed token implementations"},"transactions":[{"to":"',
            vm.toString(stakingProxy),
            '","value":"0","data":"',
            vm.toString(upgradeCalldata),
            '"}]}'
        );

        string memory outputPath = "safe-tx-upgrade-tokens.json";
        vm.writeFile(outputPath, json);

        console.log("\n=== Safe Transaction Builder ===");
        console.log("Written:", outputPath);
        console.log("Import into: https://app.safe.global/transactions/tx-builder");
        console.log("\nThe Safe multisig must sign and execute this transaction to complete the upgrade.");
    }

    function _verify(address contractAddr, string memory contractName) internal {
        string[] memory cmd = new string[](10);
        cmd[0] = "forge";
        cmd[1] = "verify-contract";
        cmd[2] = vm.toString(contractAddr);
        cmd[3] = contractName;
        cmd[4] = "--chain";
        cmd[5] = CHAIN_ID;
        cmd[6] = "--verifier";
        cmd[7] = "blockscout";
        cmd[8] = "--verifier-url";
        cmd[9] = VERIFIER_URL;

        console.log("Verifying:", contractName, "at", contractAddr);
        try vm.ffi(cmd) returns (bytes memory result) {
            console.log(string(result));
        } catch {
            console.log("  [WARN] Verification failed, verify manually");
        }
    }
}
