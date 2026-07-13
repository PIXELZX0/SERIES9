// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "forge-std/Test.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20Errors} from "openzeppelin-contracts/contracts/interfaces/draft-IERC6093.sol";
import {SER9Token} from "../src/SER9Token.sol";
import {LeoPayGate} from "../src/LeoPayGate.sol";

contract LeoPayGateTest is Test {
    SER9Token internal ser9;
    LeoPayGate internal gate;

    address internal owner = makeAddr("owner");
    address internal operator = makeAddr("operator");
    address internal master = makeAddr("master");
    address internal payer = makeAddr("payer");
    address internal rando = makeAddr("rando");

    function setUp() public {
        SER9Token ser9Impl = new SER9Token();
        ser9 = SER9Token(
            address(new ERC1967Proxy(address(ser9Impl), abi.encodeCall(SER9Token.initialize, (owner))))
        );

        LeoPayGate gateImpl = new LeoPayGate();
        gate = LeoPayGate(
            address(
                new ERC1967Proxy(
                    address(gateImpl), abi.encodeCall(LeoPayGate.initialize, (owner, address(ser9), master))
                )
            )
        );

        vm.prank(owner);
        gate.setOperator(operator, true);
        vm.prank(owner);
        ser9.transfer(payer, 1_000 ether);
    }

    function test_payPullsToMaster() public {
        vm.prank(payer);
        ser9.approve(address(gate), type(uint256).max);

        vm.prank(operator);
        gate.pay(payer, 100 ether, bytes32("ref-1"));

        assertEq(ser9.balanceOf(master), 100 ether);
        assertEq(ser9.balanceOf(payer), 900 ether);
        assertEq(ser9.balanceOf(address(gate)), 0);
    }

    function test_payRevertsWithoutAllowance() public {
        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(gate), 0, 100 ether)
        );
        gate.pay(payer, 100 ether, bytes32("ref-2"));
    }

    function test_payRevertsForUnauthorizedCaller() public {
        vm.prank(payer);
        ser9.approve(address(gate), type(uint256).max);

        vm.prank(rando);
        vm.expectRevert(LeoPayGate.Unauthorized.selector);
        gate.pay(payer, 1 ether, bytes32("ref-3"));
    }

    function test_payRevertsOnZeroAmount() public {
        vm.prank(operator);
        vm.expectRevert(LeoPayGate.ZeroAmount.selector);
        gate.pay(payer, 0, bytes32("ref-4"));
    }

    function test_ownerCanPayWithoutOperatorFlag() public {
        vm.prank(payer);
        ser9.approve(address(gate), type(uint256).max);

        vm.prank(owner);
        gate.pay(payer, 5 ether, bytes32("ref-5"));
        assertEq(ser9.balanceOf(master), 5 ether);
    }

    function test_setMasterWalletOnlyOwner() public {
        vm.prank(rando);
        vm.expectRevert();
        gate.setMasterWallet(rando);

        vm.prank(owner);
        gate.setMasterWallet(rando);
        assertEq(gate.masterWallet(), rando);
    }
}
