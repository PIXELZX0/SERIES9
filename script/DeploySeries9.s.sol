// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Script} from "forge-std/Script.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {SER9Token} from "../src/SER9Token.sol";
import {Series9ManagedToken} from "../src/Series9ManagedToken.sol";
import {Series9Staking} from "../src/Series9Staking.sol";

contract DeploySeries9 is Script {
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
                        (address(ser9), rewardPerBlock, deployer, address(managedTokenImplementation))
                    )
                )
            )
        );

        ser9.setStakingContract(address(staking));
        ser9.transferOwnership(address(staking));

        vm.stopBroadcast();
    }
}
