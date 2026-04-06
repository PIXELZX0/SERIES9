// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Script, console} from "forge-std/Script.sol";

import {SER9Token} from "../src/SER9Token.sol";

/// @notice Retries the failed setup calls from the initial deployment.
///
///   The original deployment succeeded in deploying all contracts,
///   but `setStakingContract()` and `transferOwnership()` on the SER9 proxy
///   failed. This script retries those two calls.
///
/// Usage:
///   source .env && FOUNDRY_PROFILE=deploy forge script script/FixSetup.s.sol \
///     --rpc-url $MONAD_RPC_URL --broadcast
contract FixSetup is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        // Deployed addresses from initial deployment
        address ser9Proxy = 0x461b9beFb3c81c988501C89F5caaBa03b02565d0;
        address stakingProxy = 0xFa76a92716D9fE7DF902266651Ca64014c4dC35A;

        SER9Token ser9 = SER9Token(ser9Proxy);

        console.log("Deployer:", deployer);
        console.log("SER9 Proxy:", ser9Proxy);
        console.log("Staking Proxy:", stakingProxy);
        console.log("Current SER9 owner:", ser9.owner());
        console.log("Current stakingContract:", ser9.stakingContract());

        require(ser9.owner() == deployer, "Deployer must still own SER9");

        vm.startBroadcast(deployerPrivateKey);

        // Retry the two failed calls
        ser9.setStakingContract(stakingProxy);
        ser9.transferOwnership(stakingProxy);

        vm.stopBroadcast();

        console.log("\n=== Setup Complete ===");
        console.log("SER9 owner:", ser9.owner());
        console.log("SER9 stakingContract:", ser9.stakingContract());
        console.log("Staking Proxy:", stakingProxy);
    }
}
