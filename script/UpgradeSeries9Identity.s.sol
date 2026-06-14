// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Script, console} from "forge-std/Script.sol";
import {Series9Identity} from "../src/Series9Identity.sol";
import {Series9IdentityWallet} from "../src/Series9IdentityWallet.sol";

/// @notice Upgrades the Series9Identity proxy to add the per-identity smart-account wallet and the
///         escrowed identity-transfer features, and configures the wallet factory in one transaction.
///
/// The production proxy is owned by a Safe multisig, so this script does NOT broadcast the upgrade itself.
/// It deploys the two new implementations (any EOA may do this), then emits a Safe Transaction Builder JSON
/// for the single owner-only call:
///
///   upgradeToAndCall(newIdentityImpl, initializeWalletFactory(bootstrapWallet))   // reinitializer(3)
///
/// The Safe that owns the proxy imports the JSON, signs, and executes it.
///
/// Post-upgrade: new mints auto-create their wallet; identities minted earlier call `createWallet(tokenId)`.
/// Future wallet versions are added with `setWalletImplApproved(impl, version)` (holders upgrade at will) and
/// retired with `revokeWalletImpl(impl)`.
///
/// Required env:
///   PRIVATE_KEY=0x...      deployer key (only deploys the two implementations)
///   IDENTITY_PROXY=0x...   the deployed ERC1967 proxy address
///
/// Usage:
///   PRIVATE_KEY=0x... IDENTITY_PROXY=0x... forge script script/UpgradeSeries9Identity.s.sol \
///     --rpc-url $MONAD_RPC_URL --broadcast --profile deploy
contract UpgradeSeries9Identity is Script {
    string constant CHAIN_ID = "143";

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address proxy = vm.envAddress("IDENTITY_PROXY");
        require(proxy.code.length > 0, "IDENTITY_PROXY must be a deployed contract");

        // --- Phase 1: Deploy the new implementations (no owner privileges required) ---
        vm.startBroadcast(deployerPrivateKey);

        // Bootstrap wallet implementation (frozen as every wallet proxy's birth logic).
        Series9IdentityWallet bootstrapWallet = new Series9IdentityWallet();

        // New identity implementation.
        Series9Identity newImpl = new Series9Identity();

        vm.stopBroadcast();

        // --- Phase 2: Emit Safe TX Builder JSON for the owner-only upgrade + factory configuration ---
        bytes memory initData = abi.encodeCall(Series9Identity.initializeWalletFactory, (address(bootstrapWallet)));
        bytes memory upgradeCalldata =
            abi.encodeWithSignature("upgradeToAndCall(address,bytes)", address(newImpl), initData);

        string memory json = string.concat(
            '{"version":"1.0","chainId":"',
            CHAIN_ID,
            '","meta":{"name":"Series9 Identity Wallet + Escrow Upgrade","description":"Upgrade Series9Identity proxy to the implementation that ships per-identity smart-account wallets and escrowed identity transfers, and configure the wallet factory"},"transactions":[{"to":"',
            vm.toString(proxy),
            '","value":"0","data":"',
            vm.toString(upgradeCalldata),
            '"}]}'
        );

        string memory outputPath = "safe-tx-upgrade-identity-wallet.json";
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.writeFile(outputPath, json);

        console.log("=== Series9Identity wallet upgrade prepared ===");
        console.log("Identity proxy:        ", proxy);
        console.log("New identity impl:     ", address(newImpl));
        console.log("Bootstrap wallet impl: ", address(bootstrapWallet));
        console.log("\n=== Safe Transaction Builder ===");
        console.log("Written:", outputPath);
        console.log("Import into: https://app.safe.global/transactions/tx-builder");
        console.log("\nThe Safe multisig that owns the proxy must sign and execute this transaction.");
    }
}
