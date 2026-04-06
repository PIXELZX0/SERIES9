// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Script} from "forge-std/Script.sol";

import {SER9Token} from "../src/SER9Token.sol";
import {Series9ManagedToken} from "../src/Series9ManagedToken.sol";
import {Series9Staking} from "../src/Series9Staking.sol";

contract UpgradeTokens is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address stakingProxy = vm.envAddress("STAKING_PROXY");

        address newSer9Implementation = vm.envOr("NEW_SER9_IMPLEMENTATION", address(0));
        address newManagedImplementation = vm.envOr("NEW_MANAGED_IMPLEMENTATION", address(0));

        string memory ser9DataHex = vm.envOr("SER9_UPGRADE_DATA", string(""));
        string memory managedDataHex = vm.envOr("MANAGED_UPGRADE_DATA", string(""));
        bytes memory ser9Data = bytes(ser9DataHex).length == 0 ? bytes("") : vm.parseBytes(ser9DataHex);
        bytes memory managedData = bytes(managedDataHex).length == 0 ? bytes("") : vm.parseBytes(managedDataHex);

        vm.startBroadcast(deployerPrivateKey);

        if (newSer9Implementation == address(0)) {
            newSer9Implementation = address(new SER9Token());
        }
        if (newManagedImplementation == address(0)) {
            newManagedImplementation = address(new Series9ManagedToken());
        }

        Series9Staking(stakingProxy).upgradeTokens(
            newSer9Implementation, newManagedImplementation, ser9Data, managedData
        );

        vm.stopBroadcast();
    }
}
