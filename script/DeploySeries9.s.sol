// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Script, console} from "forge-std/Script.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {SER9Token} from "../src/SER9Token.sol";
import {Series9ManagedToken} from "../src/Series9ManagedToken.sol";
import {Series9Staking} from "../src/Series9Staking.sol";

/// @notice Deploys Series9 contracts with a Safe multisig as the final owner.
///
/// Flow:
///   1. Deployer EOA deploys all implementations + proxies
///   2. SER9 is temporarily owned by deployer for setup
///   3. Staking is initialized with Safe as owner
///   4. Deployer sets staking contract on SER9 and transfers SER9 ownership to staking
///   5. After deployment: Staking.owner() == Safe, SER9.owner() == Staking
///
/// Usage:
///   PRIVATE_KEY=0x... SAFE_ADDRESS=0x... PERMIT2_ADDRESS=0x... forge script script/DeploySeries9.s.sol \
///     --rpc-url $MONAD_RPC_URL --broadcast --ffi --profile deploy
contract DeploySeries9 is Script {
    string constant VERIFIER_URL = "https://sourcify-api-monad.blockvision.org/api";

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address safeAddress = vm.envAddress("SAFE_ADDRESS");
        address permit2Address = vm.envOr("PERMIT2_ADDRESS", address(0));
        uint256 rewardPerBlock = vm.envOr("REWARD_PER_BLOCK", uint256(1 ether));
        address deployer = vm.addr(deployerPrivateKey);

        require(safeAddress != address(0), "SAFE_ADDRESS required");
        require(safeAddress != deployer, "SAFE_ADDRESS must differ from deployer");

        console.log("Deployer (temporary):", deployer);
        console.log("Safe Owner (permanent):", safeAddress);

        vm.startBroadcast(deployerPrivateKey);

        // --- Deploy implementations ---
        SER9Token ser9Implementation = new SER9Token();
        Series9ManagedToken managedTokenImplementation = new Series9ManagedToken();
        Series9Staking stakingImplementation = new Series9Staking();

        // --- Deploy SER9 proxy (deployer as temporary owner for setup) ---
        SER9Token ser9 = SER9Token(
            address(
                new ERC1967Proxy(
                    address(ser9Implementation), abi.encodeCall(SER9Token.initialize, (deployer))
                )
            )
        );

        // --- Deploy Staking proxy (Safe as owner) ---
        Series9Staking staking = Series9Staking(
            payable(
                new ERC1967Proxy(
                    address(stakingImplementation),
                    abi.encodeCall(
                        Series9Staking.initialize,
                        (address(ser9), rewardPerBlock, safeAddress, address(managedTokenImplementation), 1 ether)
                    )
                )
            )
        );

        // --- Setup: deployer configures SER9 then relinquishes control ---
        ser9.setStakingContract(address(staking));
        ser9.transferOwnership(address(staking));

        if (permit2Address != address(0)) {
            staking.setPermit2(permit2Address);
        }

        vm.stopBroadcast();

        // --- Post-deploy logs ---
        console.log("\n=== Deployed Addresses ===");
        console.log("SER9 Implementation:", address(ser9Implementation));
        console.log("SER9 Proxy:", address(ser9));
        console.log("ManagedToken Implementation:", address(managedTokenImplementation));
        console.log("Staking Implementation:", address(stakingImplementation));
        console.log("Staking Proxy:", address(staking));
        console.log("Permit2:", permit2Address == address(0) ? "not-set" : vm.toString(permit2Address));

        console.log("\n=== Ownership ===");
        console.log("Staking.owner():", safeAddress, "(Safe multisig)");
        console.log("SER9.owner():", address(staking), "(Staking contract)");
        console.log("Deployer privileges: NONE");

        // --- Auto-verify ---
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
                        (address(ser9), rewardPerBlock, safeAddress, address(managedTokenImplementation), 1 ether)
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
            cmd[5] = "143";
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
            cmd[5] = "143";
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
        try vm.ffi(cmd) returns (bytes memory result) {
            console.log(string(result));
        } catch {
            console.log("  [WARN] MonadVision verification failed, verify manually");
        }
    }
}
