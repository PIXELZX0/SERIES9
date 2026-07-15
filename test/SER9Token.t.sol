// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {SER9Token} from "../src/SER9Token.sol";

contract SER9TokenTest is Test {
    SER9Token internal token;
    address internal owner = makeAddr("owner");

    function setUp() public {
        SER9Token implementation = new SER9Token();
        ERC1967Proxy proxy =
            new ERC1967Proxy(address(implementation), abi.encodeCall(SER9Token.initialize, (owner)));
        token = SER9Token(address(proxy));
    }

    function test_setTokenMetadata() public {
        vm.prank(owner);
        token.setTokenMetadata("data:image/svg+xml;base64,AAA", "SERIES9 token");

        assertEq(token.image(), "data:image/svg+xml;base64,AAA");
        assertEq(token.description(), "SERIES9 token");
    }

    function test_setTokenMetadata_revertsForNonOwner() public {
        vm.expectRevert();
        vm.prank(makeAddr("stranger"));
        token.setTokenMetadata("x", "y");
    }
}
