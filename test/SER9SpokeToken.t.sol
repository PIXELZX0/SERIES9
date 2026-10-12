// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {SER9SpokeToken} from "../src/SER9SpokeToken.sol";
import {INttToken} from "../src/interfaces/INttToken.sol";

contract SER9SpokeTokenTest is Test {
    SER9SpokeToken internal token;
    address internal owner = makeAddr("owner");
    address internal nttManager = makeAddr("nttManager");
    address internal alice = makeAddr("alice");

    function setUp() public {
        SER9SpokeToken implementation = new SER9SpokeToken();
        ERC1967Proxy proxy =
            new ERC1967Proxy(address(implementation), abi.encodeCall(SER9SpokeToken.initialize, (owner)));
        token = SER9SpokeToken(address(proxy));

        vm.prank(owner);
        token.setMinter(nttManager);
    }

    function test_initialState() public view {
        assertEq(token.name(), "SERIES9");
        assertEq(token.symbol(), "SER9");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), 0);
        assertEq(token.owner(), owner);
        assertEq(token.minter(), nttManager);
    }

    function test_initialize_revertsTwice() public {
        vm.expectRevert();
        token.initialize(alice);
    }

    function test_setMinter_revertsForNonOwner() public {
        vm.expectRevert();
        vm.prank(alice);
        token.setMinter(alice);
    }

    function test_setMinter_revertsForZero() public {
        vm.expectRevert(INttToken.InvalidMinterZeroAddress.selector);
        vm.prank(owner);
        token.setMinter(address(0));
    }

    function test_setMinter_emitsAndReplaces() public {
        address next = makeAddr("next");
        vm.expectEmit(address(token));
        emit INttToken.NewMinter(nttManager, next);
        vm.prank(owner);
        token.setMinter(next);

        vm.expectRevert(abi.encodeWithSelector(INttToken.CallerNotMinter.selector, nttManager));
        vm.prank(nttManager);
        token.mint(alice, 1);
    }

    function test_mint_onlyMinter() public {
        vm.prank(nttManager);
        token.mint(alice, 100 ether);
        assertEq(token.balanceOf(alice), 100 ether);

        vm.expectRevert(abi.encodeWithSelector(INttToken.CallerNotMinter.selector, owner));
        vm.prank(owner);
        token.mint(owner, 1);
    }

    /// NttManager burning-mode outbound path: transferFrom(user -> manager), then burn(amount).
    function test_outboundBurnFlow() public {
        vm.prank(nttManager);
        token.mint(alice, 100 ether);

        vm.prank(alice);
        token.approve(nttManager, 40 ether);
        vm.startPrank(nttManager);
        token.transferFrom(alice, nttManager, 40 ether);
        token.burn(40 ether);
        vm.stopPrank();

        assertEq(token.balanceOf(alice), 60 ether);
        assertEq(token.balanceOf(nttManager), 0);
        assertEq(token.totalSupply(), 60 ether);
    }

    function test_upgrade_onlyOwner() public {
        SER9SpokeToken next = new SER9SpokeToken();

        vm.expectRevert();
        vm.prank(alice);
        token.upgradeToAndCall(address(next), "");

        vm.prank(owner);
        token.upgradeToAndCall(address(next), "");
        assertEq(token.minter(), nttManager);
    }
}
