// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Script, console} from "forge-std/Script.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {UpgradeableBeacon} from "openzeppelin-contracts/contracts/proxy/beacon/UpgradeableBeacon.sol";

import {LeoPayGate} from "../src/LeoPayGate.sol";
import {VirtualWallet} from "../src/VirtualWallet.sol";
import {UserVirtualWalletManager} from "../src/UserVirtualWalletManager.sol";

/// @notice Deploys the PIXELZX payment stack: LeoPayGate + VirtualWallet beacon
/// + UserVirtualWalletManager, wires the operator, then hands ownership to the Safe.
///
/// Required env:
///   PRIVATE_KEY=0x...        deployer (needs MON for gas)
///   SAFE_ADDRESS=0x...       final owner of both proxies
///   MASTER_WALLET=0x...      SER9 payment sink / weekly distributor
///   OPERATOR_ADDRESS=0x...   bot backend hot key (pay pulls + wallet creation)
///
/// Optional env:
///   SER9_TOKEN=0x...         defaults to the mainnet SER9 proxy
contract DeployLeoPayGate is Script {
    address constant DEFAULT_SER9 = 0x461b9beFb3c81c988501C89F5caaBa03b02565d0;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address safeAddress = vm.envAddress("SAFE_ADDRESS");
        address masterWallet = vm.envAddress("MASTER_WALLET");
        address operator = vm.envAddress("OPERATOR_ADDRESS");
        address ser9 = vm.envOr("SER9_TOKEN", DEFAULT_SER9);

        require(safeAddress != address(0), "SAFE_ADDRESS required");
        require(masterWallet != address(0), "MASTER_WALLET required");
        require(operator != address(0), "OPERATOR_ADDRESS required");
        require(ser9.code.length > 0, "SER9_TOKEN must be a contract");

        address deployer = vm.addr(deployerPrivateKey);
        console.log("Deployer:", deployer);
        console.log("Final owner (Safe):", safeAddress);
        console.log("Master wallet:", masterWallet);
        console.log("Operator:", operator);
        console.log("SER9:", ser9);

        vm.startBroadcast(deployerPrivateKey);

        // 1. LeoPayGate — owner starts as deployer so we can wire the operator,
        //    then ownership moves to the Safe.
        LeoPayGate gateImpl = new LeoPayGate();
        LeoPayGate gate = LeoPayGate(
            address(new ERC1967Proxy(address(gateImpl), abi.encodeCall(LeoPayGate.initialize, (deployer, ser9, masterWallet))))
        );
        gate.setOperator(operator, true);
        gate.transferOwnership(safeAddress);

        // 2. VirtualWallet impl + beacon (beacon owner = manager proxy, below).
        VirtualWallet walletImpl = new VirtualWallet();
        UpgradeableBeacon beacon = new UpgradeableBeacon(address(walletImpl), deployer);

        // 3. Manager proxy, wire operator, hand beacon + manager to their owners.
        UserVirtualWalletManager managerImpl = new UserVirtualWalletManager();
        UserVirtualWalletManager manager = UserVirtualWalletManager(
            address(
                new ERC1967Proxy(
                    address(managerImpl), abi.encodeCall(UserVirtualWalletManager.initialize, (deployer, address(beacon)))
                )
            )
        );
        beacon.transferOwnership(address(manager));
        manager.setOperator(operator, true);
        manager.transferOwnership(safeAddress);

        vm.stopBroadcast();

        console.log("");
        console.log("== PIXELZX .env values ==");
        console.log("LEO_PAY_GATE_ADDRESS=", address(gate));
        console.log("USER_VIRTUAL_WALLET_MANAGER_ADDRESS=", address(manager));
        console.log("");
        console.log("LeoPayGate impl:", address(gateImpl));
        console.log("VirtualWallet impl:", address(walletImpl));
        console.log("Beacon:", address(beacon));
        console.log("Manager impl:", address(managerImpl));
    }
}
