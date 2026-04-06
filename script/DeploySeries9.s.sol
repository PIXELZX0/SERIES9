// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Script, console} from "forge-std/Script.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {SER9Token} from "../src/SER9Token.sol";
import {Series9ManagedToken} from "../src/Series9ManagedToken.sol";
import {Series9Staking} from "../src/Series9Staking.sol";

contract DeploySeries9 is Script {
    string constant VERIFIER_URL = "https://api.socialscan.io/monad/v1/explorer/command_api/contract";

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        uint256 rewardPerBlock = vm.envOr("REWARD_PER_BLOCK", uint256(1 ether));
        address deployer = vm.addr(deployerPrivateKey);

        vm.startBroadcast(deployerPrivateKey);

        SER9Token ser9Implementation = new SER9Token();
        Series9ManagedToken managedTokenImplementation = new Series9ManagedToken();
        Series9Staking stakingImplementation = new Series9Staking();

        SER9Token ser9 = SER9Token(
            address(
                new ERC1967Proxy(
                    address(ser9Implementation), abi.encodeCall(SER9Token.initialize, (deployer))
                )
            )
        );

        Series9Staking staking = Series9Staking(
            address(
                new ERC1967Proxy(
                    address(stakingImplementation),
                    abi.encodeCall(
                        Series9Staking.initialize,
                        (address(ser9), rewardPerBlock, deployer, address(managedTokenImplementation), 1 ether)
                    )
                )
            )
        );

        ser9.setStakingContract(address(staking));
        ser9.transferOwnership(address(staking));

        vm.stopBroadcast();

        console.log("=== Deployed Addresses ===");
        console.log("SER9 Implementation:", address(ser9Implementation));
        console.log("SER9 Proxy:", address(ser9));
        console.log("ManagedToken Implementation:", address(managedTokenImplementation));
        console.log("Staking Implementation:", address(stakingImplementation));
        console.log("Staking Proxy:", address(staking));

        console.log("\n=== Verifying Contracts ===");
        _verify(address(ser9Implementation), "src/SER9Token.sol:SER9Token", "");
        _verify(address(managedTokenImplementation), "src/Series9ManagedToken.sol:Series9ManagedToken", "");
        _verify(address(stakingImplementation), "src/Series9Staking.sol:Series9Staking", "");
        _verify(
            address(ser9),
            "lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol:ERC1967Proxy",
            vm.toString(
                abi.encode(address(ser9Implementation), abi.encodeCall(SER9Token.initialize, (deployer)))
            )
        );
        _verify(
            address(staking),
            "lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol:ERC1967Proxy",
            vm.toString(
                abi.encode(
                    address(stakingImplementation),
                    abi.encodeCall(
                        Series9Staking.initialize,
                        (address(ser9), rewardPerBlock, deployer, address(managedTokenImplementation), 1 ether)
                    )
                )
            )
        );
    }

    function _verify(address contractAddr, string memory contractName, string memory constructorArgs) internal {
        string[] memory cmd;

        if (bytes(constructorArgs).length == 0) {
            cmd = new string[](10);
            cmd[0] = "forge";
            cmd[1] = "verify-contract";
            cmd[2] = vm.toString(contractAddr);
            cmd[3] = contractName;
            cmd[4] = "--chain";
            cmd[5] = "10143";
            cmd[6] = "--verifier";
            cmd[7] = "blockscout";
            cmd[8] = "--verifier-url";
            cmd[9] = VERIFIER_URL;
        } else {
            cmd = new string[](12);
            cmd[0] = "forge";
            cmd[1] = "verify-contract";
            cmd[2] = vm.toString(contractAddr);
            cmd[3] = contractName;
            cmd[4] = "--chain";
            cmd[5] = "10143";
            cmd[6] = "--verifier";
            cmd[7] = "blockscout";
            cmd[8] = "--verifier-url";
            cmd[9] = VERIFIER_URL;
            cmd[10] = "--constructor-args";
            cmd[11] = constructorArgs;
        }

        console.log("Verifying:", contractName, "at", contractAddr);
        try vm.ffi(cmd) returns (bytes memory result) {
            console.log(string(result));
        } catch {
            console.log("  [WARN] Verification failed, verify manually");
        }
    }
}
