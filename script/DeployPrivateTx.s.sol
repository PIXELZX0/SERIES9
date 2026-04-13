// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Script, console} from "forge-std/Script.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {PrivateToken} from "../src/PrivateToken.sol";
import {PrivateTokenPool} from "../src/PrivateTokenPool.sol";

contract DeployPrivateTx is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address safeAddress = vm.envAddress("SAFE_ADDRESS");
        address ser9Proxy = vm.envAddress("SER9_PROXY");
        address depositVerifier = vm.envOr("PRIVATE_DEPOSIT_VERIFIER", address(0));
        address withdrawVerifier = vm.envOr("PRIVATE_WITHDRAW_VERIFIER", address(0));

        vm.startBroadcast(deployerPrivateKey);

        PrivateToken privateTokenImplementation = new PrivateToken();
        PrivateTokenPool privatePoolImplementation = new PrivateTokenPool();

        PrivateToken privateToken = PrivateToken(
            address(
                new ERC1967Proxy(
                    address(privateTokenImplementation),
                    abi.encodeCall(PrivateToken.initialize, (safeAddress, depositVerifier, withdrawVerifier))
                )
            )
        );

        PrivateTokenPool privatePool = PrivateTokenPool(
            address(
                new ERC1967Proxy(
                    address(privatePoolImplementation),
                    abi.encodeCall(PrivateTokenPool.initialize, (safeAddress, ser9Proxy, address(privateToken)))
                )
            )
        );

        vm.stopBroadcast();

        console.log("PrivateToken implementation:", address(privateTokenImplementation));
        console.log("PrivateToken proxy:", address(privateToken));
        console.log("PrivateTokenPool implementation:", address(privatePoolImplementation));
        console.log("PrivateTokenPool proxy:", address(privatePool));
        console.log("SER9 proxy:", ser9Proxy);
        console.log("Deposit verifier:", depositVerifier);
        console.log("Withdraw verifier:", withdrawVerifier);
    }
}
