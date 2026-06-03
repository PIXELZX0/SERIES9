// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Script, console} from "forge-std/Script.sol";

import {SER9Token} from "../src/SER9Token.sol";
import {Series9Staking} from "../src/Series9Staking.sol";

contract UpgradeTokens is Script {
    string constant SOURCIFY_VERIFIER_URL = "https://sourcify-api-monad.blockvision.org";
    string constant SOCIALSCAN_VERIFIER_URL = "https://api.socialscan.io/monad/v1/explorer/command_api/contract";
    string constant CHAIN_ID = "143";

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address stakingProxy = vm.envAddress("STAKING_PROXY");
        bool skipVerify = vm.envOr("SKIP_VERIFY", false);

        string memory ser9DataHex = vm.envOr("SER9_UPGRADE_DATA", string(""));
        bytes memory ser9Data = bytes(ser9DataHex).length == 0 ? bytes("") : vm.parseBytes(ser9DataHex);

        vm.startBroadcast(deployerPrivateKey);

        address newSer9Implementation = address(new SER9Token());

        vm.stopBroadcast();

        console.log("=== New Implementations Deployed ===");
        console.log("New SER9 Implementation:", newSer9Implementation);
        console.log("Staking Proxy:", stakingProxy);

        if (skipVerify) {
            console.log("\n=== Skipping Verification (SKIP_VERIFY=true) ===");
        } else {
            console.log("\n=== Verifying New Implementations ===");
            _verify(newSer9Implementation, "src/SER9Token.sol:SER9Token");
        }

        bytes memory upgradeSer9Calldata = abi.encodeCall(Series9Staking.upgradeSer9, (newSer9Implementation, ser9Data));

        string memory json = string.concat(
            '{"version":"1.0","chainId":"',
            CHAIN_ID,
            '","meta":{"name":"Series9 Upgrade","description":"Upgrade SER9 implementation"},"transactions":[{"to":"',
            vm.toString(stakingProxy),
            '","value":"0","data":"',
            vm.toString(upgradeSer9Calldata),
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
        try vm.ffi(sourcifyCmd) returns (bytes memory result) {
            console.log("  [Sourcify] ", string(result));
        } catch {
            console.log("  [WARN] Sourcify verification failed");
        }

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

        try vm.ffi(socialscanCmd) returns (bytes memory result2) {
            console.log("  [SocialScan] ", string(result2));
        } catch {
            console.log("  [WARN] SocialScan verification failed");
        }
    }
}
