// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Script, console} from "forge-std/Script.sol";
import {Series9Identity} from "../src/Series9Identity.sol";
import {Series9IdentityWallet} from "../src/Series9IdentityWallet.sol";

/// @notice Upgrades the Series9Identity proxy to add the per-identity smart-account wallet and the
///         escrowed identity-transfer features, and configures the wallet factory in one transaction.
///
/// Flow:
///   1. Deploy the bootstrap Series9IdentityWallet implementation (every wallet proxy's birth logic).
///   2. Deploy the new Series9Identity implementation.
///   3. upgradeToAndCall(newImpl, initializeWalletFactory(bootstrapWallet)) on the proxy.
///
/// The proxy owner is the Safe multisig. In production, propose the `upgradeToAndCall` call below through
/// the Safe (the two `new` deployments can be done by any EOA first; only step 3 must come from the owner).
/// For a directly EOA-owned proxy, set PRIVATE_KEY to the owner key and broadcast the whole script.
///
/// Post-upgrade: new mints auto-create their wallet; identities minted earlier call `createWallet(tokenId)`.
/// Future wallet versions are added with `setWalletImplApproved(impl, version)` (holders upgrade at will).
///
/// Usage:
///   PRIVATE_KEY=0x... IDENTITY_PROXY=0x... forge script script/UpgradeSeries9Identity.s.sol \
///     --rpc-url $MONAD_RPC_URL --broadcast --profile deploy
contract UpgradeSeries9Identity is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address proxy = vm.envAddress("IDENTITY_PROXY");
        require(proxy != address(0), "IDENTITY_PROXY required");

        vm.startBroadcast(deployerPrivateKey);

        // 1. Bootstrap wallet implementation (frozen as every wallet proxy's birth logic).
        Series9IdentityWallet bootstrapWallet = new Series9IdentityWallet();

        // 2. New identity implementation.
        Series9Identity newImpl = new Series9Identity();

        // 3. Upgrade + configure the wallet factory (reinitializer(3)).
        Series9Identity(proxy).upgradeToAndCall(
            address(newImpl), abi.encodeCall(Series9Identity.initializeWalletFactory, (address(bootstrapWallet)))
        );

        vm.stopBroadcast();

        console.log("=== Series9Identity upgraded ===");
        console.log("Identity proxy:", proxy);
        console.log("New identity impl:", address(newImpl));
        console.log("Bootstrap wallet impl:", address(bootstrapWallet));
    }
}
