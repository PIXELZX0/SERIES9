// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "forge-std/Test.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {UpgradeableBeacon} from "openzeppelin-contracts/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {SER9Token} from "../src/SER9Token.sol";
import {LeoPayGate} from "../src/LeoPayGate.sol";
import {VirtualWallet} from "../src/VirtualWallet.sol";
import {UserVirtualWalletManager} from "../src/UserVirtualWalletManager.sol";

/// @dev v2 impl for the beacon-upgrade test: one new function, storage untouched.
contract VirtualWalletV2 is VirtualWallet {
    function version() external pure returns (uint256) {
        return 2;
    }
}

contract UserVirtualWalletManagerTest is Test {
    SER9Token internal ser9;
    LeoPayGate internal gate;
    UserVirtualWalletManager internal manager;
    UpgradeableBeacon internal beacon;

    address internal owner = makeAddr("owner");
    address internal operator = makeAddr("operator");
    address internal master = makeAddr("master");
    address internal rando = makeAddr("rando");

    bytes32 internal constant USER_ID = keccak256("discord:user:12345");
    bytes32 internal constant GUILD_ID = keccak256("discord:guild:67890");

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

        VirtualWallet walletImpl = new VirtualWallet();
        beacon = new UpgradeableBeacon(address(walletImpl), owner);

        UserVirtualWalletManager managerImpl = new UserVirtualWalletManager();
        manager = UserVirtualWalletManager(
            address(
                new ERC1967Proxy(
                    address(managerImpl),
                    abi.encodeCall(UserVirtualWalletManager.initialize, (owner, address(beacon)))
                )
            )
        );
        vm.prank(owner);
        beacon.transferOwnership(address(manager));

        vm.prank(owner);
        manager.setOperator(operator, true);
        vm.prank(owner);
        gate.setOperator(operator, true);
    }

    function test_predictMatchesCreate() public {
        address predicted = manager.predictVirtualWalletAddress(USER_ID);
        vm.prank(operator);
        address created = manager.createVirtualWallet(USER_ID);
        assertEq(created, predicted);
        assertEq(manager.walletOf(USER_ID), created);
        assertEq(VirtualWallet(payable(created)).virtualId(), USER_ID);
        assertEq(VirtualWallet(payable(created)).manager(), address(manager));
    }

    function test_createRevertsForUnauthorized() public {
        vm.prank(rando);
        vm.expectRevert(UserVirtualWalletManager.Unauthorized.selector);
        manager.createVirtualWallet(USER_ID);
    }

    function test_createRevertsOnDuplicate() public {
        vm.prank(operator);
        manager.createVirtualWallet(USER_ID);
        vm.prank(operator);
        vm.expectRevert(UserVirtualWalletManager.AlreadyExists.selector);
        manager.createVirtualWallet(USER_ID);
    }

    function test_executeApproveThenGatePull() public {
        vm.prank(operator);
        address wallet = manager.createVirtualWallet(USER_ID);

        // operator drives the wallet's one-time infinite approve
        bytes memory approveCall =
            abi.encodeCall(ser9.approve, (address(gate), type(uint256).max));
        vm.prank(operator);
        VirtualWallet(payable(wallet)).execute(address(ser9), 0, approveCall);

        vm.prank(owner);
        ser9.transfer(wallet, 100 ether);

        vm.prank(operator);
        gate.pay(wallet, 40 ether, bytes32("ref"));

        assertEq(ser9.balanceOf(master), 40 ether);
        assertEq(ser9.balanceOf(wallet), 60 ether);
    }

    function test_executeRevertsForUnauthorized() public {
        vm.prank(operator);
        address wallet = manager.createVirtualWallet(USER_ID);

        vm.prank(rando);
        vm.expectRevert(VirtualWallet.Unauthorized.selector);
        VirtualWallet(payable(wallet)).execute(address(ser9), 0, "");
    }

    function test_beaconUpgradeAllWalletsAtOnce() public {
        vm.prank(operator);
        address walletA = manager.createVirtualWallet(USER_ID);
        vm.prank(operator);
        address walletB = manager.createVirtualWallet(GUILD_ID);

        vm.prank(owner);
        ser9.transfer(walletA, 7 ether);

        address predictedBefore = manager.predictVirtualWalletAddress(keccak256("future"));

        VirtualWalletV2 v2 = new VirtualWalletV2();
        vm.prank(owner);
        manager.upgradeWalletImplementation(address(v2));

        // both proxies serve the new impl
        assertEq(VirtualWalletV2(payable(walletA)).version(), 2);
        assertEq(VirtualWalletV2(payable(walletB)).version(), 2);
        // storage preserved
        assertEq(VirtualWallet(payable(walletA)).virtualId(), USER_ID);
        assertEq(VirtualWallet(payable(walletB)).virtualId(), GUILD_ID);
        assertEq(ser9.balanceOf(walletA), 7 ether);
        // deterministic address unchanged by impl upgrade
        assertEq(manager.predictVirtualWalletAddress(keccak256("future")), predictedBefore);
    }

    function test_upgradeOnlyOwner() public {
        VirtualWalletV2 v2 = new VirtualWalletV2();
        vm.prank(rando);
        vm.expectRevert();
        manager.upgradeWalletImplementation(address(v2));
    }

    function test_walletReceivesNative() public {
        vm.prank(operator);
        address wallet = manager.createVirtualWallet(USER_ID);
        vm.deal(rando, 1 ether);
        vm.prank(rando);
        (bool ok,) = wallet.call{value: 0.5 ether}("");
        assertTrue(ok);
        assertEq(wallet.balance, 0.5 ether);
    }
}
