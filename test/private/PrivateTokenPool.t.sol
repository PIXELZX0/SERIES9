// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {SER9Token} from "../../src/SER9Token.sol";
import {PrivateToken} from "../../src/PrivateToken.sol";
import {PrivateTokenPool} from "../../src/PrivateTokenPool.sol";

contract Groth16VerifierMock {
    bool internal shouldVerify = true;

    function setShouldVerify(bool value) external {
        shouldVerify = value;
    }

    function verifyProof(uint256[2] calldata, uint256[2][2] calldata, uint256[2] calldata, uint256[] calldata)
        external
        view
        returns (bool)
    {
        return shouldVerify;
    }
}

contract PrivateTokenPoolTest is Test {
    SER9Token internal ser9;
    PrivateToken internal privateToken;
    PrivateTokenPool internal privatePool;
    Groth16VerifierMock internal depositVerifier;
    Groth16VerifierMock internal withdrawVerifier;

    address internal alice = makeAddr("alice");
    address internal recipient = makeAddr("recipient");

    function setUp() public {
        SER9Token ser9Implementation = new SER9Token();
        PrivateToken privateTokenImplementation = new PrivateToken();
        PrivateTokenPool privatePoolImplementation = new PrivateTokenPool();

        depositVerifier = new Groth16VerifierMock();
        withdrawVerifier = new Groth16VerifierMock();

        ser9 = SER9Token(
            address(new ERC1967Proxy(address(ser9Implementation), abi.encodeCall(SER9Token.initialize, (address(this)))))
        );
        privateToken = PrivateToken(
            address(
                new ERC1967Proxy(
                    address(privateTokenImplementation),
                    abi.encodeCall(PrivateToken.initialize, (address(this), address(depositVerifier), address(withdrawVerifier)))
                )
            )
        );
        privatePool = PrivateTokenPool(
            address(
                new ERC1967Proxy(
                    address(privatePoolImplementation),
                    abi.encodeCall(PrivateTokenPool.initialize, (address(this), address(ser9), address(privateToken)))
                )
            )
        );

        assertTrue(ser9.transfer(alice, 1_000 ether));
    }

    function testShieldMovesSer9IntoPoolAndAddsAnnouncement() public {
        PrivateToken.Proof memory proof;
        bytes32 commitmentHash = keccak256("commitment-1");

        vm.startPrank(alice);
        ser9.approve(address(privatePool), type(uint256).max);
        uint256 leafIndex = privatePool.shield(bytes32(uint256(1)), hex"1234", bytes1(0xaa), commitmentHash, 25 ether, proof);
        vm.stopPrank();

        assertEq(leafIndex, 0);
        assertEq(ser9.balanceOf(address(privatePool)), 25 ether);
        assertEq(privateToken.announcementsLength(), 1);
    }

    function testUnshieldMarksNullifierAndTransfersSer9() public {
        PrivateToken.Proof memory proof;
        bytes32 commitmentHash = keccak256("commitment-2");
        bytes32 nullifierHash = keccak256("nullifier-1");

        vm.startPrank(alice);
        ser9.approve(address(privatePool), type(uint256).max);
        privatePool.shield(bytes32(uint256(2)), hex"5678", bytes1(0xbb), commitmentHash, 40 ether, proof);
        vm.stopPrank();

        bytes32 root = privateToken.currentRoot();
        uint256 recipientBalanceBefore = ser9.balanceOf(recipient);

        privatePool.unshield(nullifierHash, root, recipient, 15 ether, proof);

        assertTrue(privateToken.nullifierSpent(nullifierHash));
        assertEq(ser9.balanceOf(recipient) - recipientBalanceBefore, 15 ether);
        assertEq(ser9.balanceOf(address(privatePool)), 25 ether);
    }

    function testUnshieldRevertsForUnknownRoot() public {
        PrivateToken.Proof memory proof;

        vm.expectRevert(PrivateToken.UnknownRoot.selector);
        privatePool.unshield(keccak256("nullifier-2"), keccak256("root"), recipient, 1 ether, proof);
    }
}
