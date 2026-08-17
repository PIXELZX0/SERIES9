// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";

import {SER9Token} from "../src/SER9Token.sol";
import {Series9Staking} from "../src/Series9Staking.sol";

/// @notice SER9 is owned by the Staking proxy, not the Safe, so the Safe cannot call
/// setTokenMetadata directly. It reaches it through upgradeSer9(currentImpl, data),
/// whose delegatecall runs with msg.sender == Staking. Fork test pins that route.
contract Ser9MetadataForkTest is Test {
    address constant SAFE = 0x96628f6F2353169dad8c9FeE65F190716705715e;
    address constant STAKING = 0xFa76a92716D9fE7DF902266651Ca64014c4dC35A;
    address constant SER9 = 0x461b9beFb3c81c988501C89F5caaBa03b02565d0;
    bytes32 constant IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    function setUp() public {
        string memory rpc = vm.envOr("MONAD_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
        }
        vm.createSelectFork(rpc);
    }

    function test_SafeCannotCallSetTokenMetadataDirectly() public {
        vm.prank(SAFE);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", SAFE));
        SER9Token(SER9).setTokenMetadata("img", "desc");
    }

    function test_SafeSetsMetadataViaUpgradeSer9Passthrough() public {
        address currentImpl = address(uint160(uint256(vm.load(SER9, IMPL_SLOT))));
        string memory image = string.concat("data:image/svg+xml;base64,", vm.toString(bytes("stub")));

        vm.prank(SAFE);
        Series9Staking(payable(STAKING)).upgradeSer9(
            currentImpl, abi.encodeCall(SER9Token.setTokenMetadata, (image, "SERIES9 staking token"))
        );

        assertEq(SER9Token(SER9).image(), image);
        assertEq(SER9Token(SER9).description(), "SERIES9 staking token");
        // implementation must be untouched: this is a metadata call, not an upgrade
        assertEq(address(uint160(uint256(vm.load(SER9, IMPL_SLOT)))), currentImpl);
    }
}
