// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Script, console} from "forge-std/Script.sol";
import {Series9Identity} from "../src/Series9Identity.sol";
import {Series9IdentityWalletV2} from "../src/Series9IdentityWalletV2.sol";

/// @notice Allowlists Series9IdentityWalletV2 (adds ERC-1271 `isValidSignature`) as wallet logic version 2.
///
/// The identity proxy is owned by a Safe multisig, so this script does NOT broadcast the allowlisting itself.
/// It deploys the v2 implementation (any EOA may do this), then emits a Safe Transaction Builder JSON for the
/// single owner-only call:
///
///   setWalletImplApproved(walletV2, 2)
///
/// The Safe that owns the proxy imports the JSON, signs, and executes it.
///
/// After that, each identity holder upgrades their own wallet at will:
///
///   wallet.upgradeToAndCall(walletV2, "")     // v2 adds no storage, so no init data
///
/// Note: `walletImplementation` (the birth logic baked into every wallet's CREATE2 init code) has no setter,
/// so newly minted identities still deploy a v1 proxy — that is deliberate, it keeps the wallet address
/// deterministic per tokenId. Their holders upgrade the same way.
///
/// Note: a version number is immutable once set — re-running this against an already-approved impl reverts
/// with `WalletImplAlreadyApproved`.
///
/// Required env:
///   PRIVATE_KEY=0x...      deployer key (only deploys the v2 implementation)
///   IDENTITY_PROXY=0x...   the deployed ERC1967 proxy address
///
/// Usage:
///   PRIVATE_KEY=0x... IDENTITY_PROXY=0x... forge script script/UpgradeIdentityWalletV2.s.sol \
///     --rpc-url $MONAD_RPC_URL --broadcast --profile deploy
contract UpgradeIdentityWalletV2 is Script {
    string constant CHAIN_ID = "143";
    uint256 constant WALLET_VERSION = 2;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address proxy = vm.envAddress("IDENTITY_PROXY");
        require(proxy.code.length > 0, "IDENTITY_PROXY must be a deployed contract");

        // --- Phase 1: Deploy the v2 wallet implementation (no owner privileges required) ---
        vm.startBroadcast(deployerPrivateKey);
        Series9IdentityWalletV2 walletV2 = new Series9IdentityWalletV2();
        vm.stopBroadcast();

        // --- Phase 2: Emit Safe TX Builder JSON for the owner-only allowlisting ---
        bytes memory approveCalldata =
            abi.encodeCall(Series9Identity.setWalletImplApproved, (address(walletV2), WALLET_VERSION));

        string memory json = string.concat(
            '{"version":"1.0","chainId":"',
            CHAIN_ID,
            '","meta":{"name":"Series9 Identity Wallet v2 (ERC-1271)","description":"Allowlist the wallet implementation that adds ERC-1271 isValidSignature as logic version 2; identity holders then upgrade their own wallets"},"transactions":[{"to":"',
            vm.toString(proxy),
            '","value":"0","data":"',
            vm.toString(approveCalldata),
            '"}]}'
        );

        string memory outputPath = "safe-tx-wallet-v2.json";
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.writeFile(outputPath, json);

        console.log("=== Series9IdentityWallet v2 (ERC-1271) prepared ===");
        console.log("Identity proxy:  ", proxy);
        console.log("Wallet v2 impl:  ", address(walletV2));
        console.log("Version:         ", WALLET_VERSION);
        console.log("\n=== Safe Transaction Builder ===");
        console.log("Written:", outputPath);
        console.log("Import into: https://app.safe.global/transactions/tx-builder");
        console.log("\nThe Safe multisig that owns the proxy must sign and execute this transaction.");
        console.log("Ship it on its own - do NOT bundle it into an unrelated pending batch.");
        console.log("\nHolders then upgrade with: wallet.upgradeToAndCall(walletV2, \"\")");
    }
}
