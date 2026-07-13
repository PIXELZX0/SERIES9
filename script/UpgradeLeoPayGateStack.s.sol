// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Script, console} from "forge-std/Script.sol";

import {LeoPayGate} from "../src/LeoPayGate.sol";
import {VirtualWallet} from "../src/VirtualWallet.sol";
import {UserVirtualWalletManager} from "../src/UserVirtualWalletManager.sol";

interface IUUPS {
    function upgradeToAndCall(address newImplementation, bytes calldata data) external payable;
}

interface IBeacon {
    function implementation() external view returns (address);
}

/// @notice Idempotent CD upgrade for the PIXELZX payment stack. Compares each
/// contract's freshly-compiled runtime bytecode hash against the live
/// implementation's codehash and deploys + upgrades only what changed.
/// Requires foundry.toml `bytecode_hash = "none"` (set) so hashes are
/// deterministic across machines.
///
/// Env:
///   CHECK_ONLY=true          report pending upgrades, no key / no broadcast
///   PRIVATE_KEY=0x...        proxy owner key (required unless CHECK_ONLY)
///   GATE_PROXY / MANAGER_PROXY   default to the mainnet deployment
///
/// Exit log line `UPGRADES_PENDING=<n>` is parsed by the Jenkins pipeline.
contract UpgradeLeoPayGateStack is Script {
    bytes32 constant IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    address constant DEFAULT_GATE = 0x6F37bFdBB747e20901d9d5b845A869332C703b22;
    address constant DEFAULT_MANAGER = 0x819765A18867075f4701fE302f97e9eF4312229E;

    function run() external {
        bool checkOnly = vm.envOr("CHECK_ONLY", false);
        address gateProxy = vm.envOr("GATE_PROXY", DEFAULT_GATE);
        address managerProxy = vm.envOr("MANAGER_PROXY", DEFAULT_MANAGER);

        address gateImpl = address(uint160(uint256(vm.load(gateProxy, IMPL_SLOT))));
        address managerImpl = address(uint160(uint256(vm.load(managerProxy, IMPL_SLOT))));
        address beacon = UserVirtualWalletManager(managerProxy).beacon();
        address walletImpl = IBeacon(beacon).implementation();

        // Candidates deployed in simulation only (outside broadcast) — used
        // purely to obtain runtime bytecode with real immutables filled in.
        bool upGate = _differs(address(new LeoPayGate()), gateImpl);
        bool upManager = _differs(address(new UserVirtualWalletManager()), managerImpl);
        bool upWallet = _differs(address(new VirtualWallet()), walletImpl);

        console.log("LeoPayGate upgrade needed:", upGate);
        console.log("UserVirtualWalletManager upgrade needed:", upManager);
        console.log("VirtualWallet upgrade needed:", upWallet);

        uint256 pending = (upGate ? 1 : 0) + (upManager ? 1 : 0) + (upWallet ? 1 : 0);
        console.log("UPGRADES_PENDING=", pending);

        if (checkOnly || pending == 0) {
            return;
        }

        uint256 ownerKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(ownerKey);

        if (upGate) {
            address newImpl = address(new LeoPayGate());
            IUUPS(gateProxy).upgradeToAndCall(newImpl, "");
            console.log("LeoPayGate upgraded to:", newImpl);
        }
        if (upManager) {
            address newImpl = address(new UserVirtualWalletManager());
            IUUPS(managerProxy).upgradeToAndCall(newImpl, "");
            console.log("UserVirtualWalletManager upgraded to:", newImpl);
        }
        if (upWallet) {
            address newImpl = address(new VirtualWallet());
            UserVirtualWalletManager(managerProxy).upgradeWalletImplementation(newImpl);
            console.log("VirtualWallet (beacon) upgraded to:", newImpl);
        }

        vm.stopBroadcast();
    }

    function _differs(address candidate, address liveImpl) internal view returns (bool) {
        // UUPSUpgradeable embeds an immutable __self = address(this) in the
        // runtime code, so identical source still hashes differently per
        // deployment address. Mask each contract's own address out of its
        // code before comparing.
        return keccak256(_maskSelf(candidate.code, candidate)) != keccak256(_maskSelf(liveImpl.code, liveImpl));
    }

    function _maskSelf(bytes memory code, address self) internal pure returns (bytes memory) {
        bytes20 target = bytes20(self);
        for (uint256 i = 0; i + 20 <= code.length; i++) {
            bool matched = true;
            for (uint256 j = 0; j < 20; j++) {
                if (code[i + j] != target[j]) {
                    matched = false;
                    break;
                }
            }
            if (matched) {
                for (uint256 j = 0; j < 20; j++) {
                    code[i + j] = 0;
                }
                i += 19;
            }
        }
        return code;
    }
}
