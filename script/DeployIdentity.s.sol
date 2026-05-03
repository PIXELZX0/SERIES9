// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Script, console} from "forge-std/Script.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {Series9Identity} from "../src/Series9Identity.sol";

interface ISeries9StakingSer9 {
    function ser9() external view returns (address);
}

/// @notice Deploys only the Series9Identity implementation + proxy.
///
/// Required env:
///   PRIVATE_KEY=0x...
///   SAFE_ADDRESS=0x...
///   STAKING_PROXY=0x...
///
/// Optional env:
///   IDENTITY_AI_FEE=10000000000000000000
///   IDENTITY_HUMAN_FEE=50000000000000000000
///   SKIP_VERIFY=true
contract DeployIdentity is Script {
    string constant VERIFIER_URL = "https://sourcify-api-monad.blockvision.org/api";
    string constant CHAIN_ID = "143";

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address safeAddress = vm.envAddress("SAFE_ADDRESS");
        address stakingProxy = vm.envAddress("STAKING_PROXY");
        uint256 aiFee = vm.envOr("IDENTITY_AI_FEE", uint256(10 ether));
        uint256 humanFee = vm.envOr("IDENTITY_HUMAN_FEE", uint256(50 ether));
        bool skipVerify = vm.envOr("SKIP_VERIFY", false);

        require(safeAddress != address(0), "SAFE_ADDRESS required");
        require(stakingProxy.code.length > 0, "STAKING_PROXY must be a contract");

        address ser9Token = ISeries9StakingSer9(stakingProxy).ser9();
        require(ser9Token.code.length > 0, "staking ser9 must be a contract");

        address deployer = vm.addr(deployerPrivateKey);

        console.log("Deployer:", deployer);
        console.log("Identity owner:", safeAddress);
        console.log("SER9 token:", ser9Token);
        console.log("Staking proxy:", stakingProxy);
        console.log("AI mint fee:", aiFee);
        console.log("Human mint fee:", humanFee);

        vm.startBroadcast(deployerPrivateKey);

        Series9Identity identityImplementation = new Series9Identity();
        Series9Identity identity = Series9Identity(
            address(
                new ERC1967Proxy(
                    address(identityImplementation),
                    abi.encodeCall(
                        Series9Identity.initialize,
                        (safeAddress, ser9Token, stakingProxy, aiFee, humanFee)
                    )
                )
            )
        );

        vm.stopBroadcast();

        console.log("\n=== Identity Deployed ===");
        console.log("Identity Implementation:", address(identityImplementation));
        console.log("Identity Proxy:", address(identity));
        console.log("Identity owner:", identity.owner());
        console.log("SER9 token:", address(identity.ser9()));
        console.log("Staking contract:", identity.stakingContract());
        console.log("AI mint fee:", identity.aiMintFee());
        console.log("Human mint fee:", identity.humanMintFee());

        if (skipVerify) {
            console.log("\n=== Skipping Verification (SKIP_VERIFY=true) ===");
            return;
        }

        console.log("\n=== Verifying Identity Contracts ===");
        _verify(address(identityImplementation), "src/Series9Identity.sol:Series9Identity", "");
        _verify(
            address(identity),
            "lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol:ERC1967Proxy",
            vm.toString(
                abi.encode(
                    address(identityImplementation),
                    abi.encodeCall(
                        Series9Identity.initialize,
                        (safeAddress, ser9Token, stakingProxy, aiFee, humanFee)
                    )
                )
            )
        );
    }

    function _verify(address contractAddr, string memory contractName, string memory constructorArgs) internal {
        string[] memory cmd;

        if (bytes(constructorArgs).length == 0) {
            cmd = new string[](12);
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
        } else {
            cmd = new string[](14);
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
            cmd[12] = "--constructor-args";
            cmd[13] = constructorArgs;
        }

        console.log("Verifying:", contractName, "at", contractAddr);
        // forge-lint: disable-next-line(unsafe-cheatcode)
        try vm.ffi(cmd) returns (bytes memory result) {
            console.log(string(result));
        } catch {
            console.log("  [WARN] MonadVision verification failed, verify manually");
        }
    }
}
