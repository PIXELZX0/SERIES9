// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC1822Proxiable} from "openzeppelin-contracts/contracts/interfaces/draft-IERC1822.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

import {SER9Token} from "../src/SER9Token.sol";
import {Series9ManagedToken} from "../src/Series9ManagedToken.sol";
import {Series9Staking} from "../src/Series9Staking.sol";
import {IPermit2} from "../src/interfaces/IPermit2.sol";

contract SER9TokenV2 is SER9Token {
    function version() external pure returns (uint256) {
        return 2;
    }
}

contract Series9ManagedTokenV2 is Series9ManagedToken {
    function version() external pure returns (uint256) {
        return 2;
    }
}

contract NonUUPSImplementation {}

contract WrongUUIDImplementation is IERC1822Proxiable {
    function proxiableUUID() external pure returns (bytes32) {
        return bytes32(uint256(123));
    }
}

contract Permit2Mock is IPermit2 {
    mapping(address owner => mapping(address token => mapping(address spender => uint160 amount))) internal allowanceAmount;

    function permit(address owner, PermitSingle calldata permitSingle, bytes calldata) external {
        allowanceAmount[owner][permitSingle.details.token][permitSingle.spender] = permitSingle.details.amount;
    }

    function transferFrom(address from, address to, uint160 amount, address token) external {
        uint160 allowed = allowanceAmount[from][token][msg.sender];
        require(allowed >= amount, "Permit2: insufficient allowance");

        unchecked {
            allowanceAmount[from][token][msg.sender] = allowed - amount;
        }

        IERC20(token).transferFrom(from, to, amount);
    }
}

contract Series9StakingTest is Test {
    SER9Token internal ser9;
    Series9Staking internal staking;
    Permit2Mock internal permit2;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal charlie = makeAddr("charlie");

    uint256 internal constant INITIAL_SUPPLY = 1_000_000_000_000 ether;
    uint256 internal constant REWARD_PER_BLOCK = 1 ether;
    uint256 internal constant CREATION_FEE = 1 ether;

    function setUp() public {
        SER9Token ser9Implementation = new SER9Token();
        Series9ManagedToken managedTokenImplementation = new Series9ManagedToken();
        Series9Staking stakingImplementation = new Series9Staking();

        ser9 = SER9Token(
            address(new ERC1967Proxy(address(ser9Implementation), abi.encodeCall(SER9Token.initialize, (address(this)))))
        );

        staking = Series9Staking(
            address(
                new ERC1967Proxy(
                    address(stakingImplementation),
                    abi.encodeCall(
                        Series9Staking.initialize,
                        (address(ser9), REWARD_PER_BLOCK, address(this), address(managedTokenImplementation), CREATION_FEE)
                    )
                )
            )
        );

        permit2 = new Permit2Mock();
        staking.setPermit2(address(permit2));

        ser9.setStakingContract(address(staking));
        ser9.transferOwnership(address(staking));

        ser9.transfer(alice, 10_000 ether);
        ser9.transfer(bob, 10_000 ether);
        ser9.transfer(charlie, 10_000 ether);
    }

    function testInitialSupplyIsOneTrillion() public view {
        assertEq(ser9.totalSupply(), INITIAL_SUPPLY);
    }

    function testOwnerCannotMintSER9Directly() public {
        vm.expectRevert(SER9Token.UnauthorizedMinter.selector);
        ser9.mint(alice, 1 ether);
    }

    function testStakingContractAddressCanBeUpdated() public {
        address oldStaking = address(staking);
        address newStaking = makeAddr("newStaking");

        vm.prank(address(staking));
        ser9.setStakingContract(newStaking);

        vm.expectRevert(SER9Token.UnauthorizedMinter.selector);
        vm.prank(oldStaking);
        ser9.mint(alice, 1 ether);

        vm.prank(newStaking);
        ser9.mint(alice, 1 ether);
        assertEq(ser9.balanceOf(alice), 10_001 ether);
    }

    function testStakeAccruesAndClaimsSER9Rewards() public {
        vm.startPrank(alice);
        ser9.approve(address(staking), type(uint256).max);
        staking.stake(100 ether);

        vm.roll(block.number + 10);

        uint256 balanceBefore = ser9.balanceOf(alice);
        staking.claimRewards();
        uint256 claimed = ser9.balanceOf(alice) - balanceBefore;

        vm.stopPrank();

        assertEq(claimed, 10 ether);
    }

    function testStakeWithPermit2() public {
        vm.startPrank(alice);
        ser9.approve(address(permit2), type(uint256).max);

        IPermit2.PermitSingle memory permitSingle = IPermit2.PermitSingle({
            details: IPermit2.PermitDetails({
                token: address(ser9),
                amount: uint160(100 ether),
                expiration: uint48(block.timestamp + 1 days),
                nonce: 0
            }),
            spender: address(staking),
            sigDeadline: block.timestamp + 1 days
        });

        staking.stakeWithPermit2(100 ether, permitSingle, hex"01");
        vm.stopPrank();

        assertEq(staking.stakedBalance(alice), 100 ether);
        assertEq(ser9.balanceOf(alice), 9_900 ether);
    }

    function testCreateManagedTokenWithPermit2() public {
        vm.startPrank(alice);
        ser9.approve(address(permit2), type(uint256).max);

        IPermit2.PermitSingle memory permitSingle = IPermit2.PermitSingle({
            details: IPermit2.PermitDetails({
                token: address(ser9),
                amount: uint160(CREATION_FEE),
                expiration: uint48(block.timestamp + 1 days),
                nonce: 0
            }),
            spender: address(staking),
            sigDeadline: block.timestamp + 1 days
        });

        uint256 aliceBefore = ser9.balanceOf(alice);
        address token =
            staking.createManagedTokenWithPermit2("PERMIT", "PRM", 1 ether, false, 0, permitSingle, hex"01");
        vm.stopPrank();

        (bool exists, address creator,,) = staking.tokenConfigs(token);
        assertTrue(exists);
        assertEq(creator, alice);
        assertEq(ser9.balanceOf(alice), aliceBefore - CREATION_FEE);
    }

    function testCreateManagedTokenWithPermit2WithPolicy() public {
        vm.startPrank(alice);
        ser9.approve(address(permit2), type(uint256).max);

        IPermit2.PermitSingle memory permitSingle = IPermit2.PermitSingle({
            details: IPermit2.PermitDetails({
                token: address(ser9),
                amount: uint160(CREATION_FEE),
                expiration: uint48(block.timestamp + 1 days),
                nonce: 0
            }),
            spender: address(staking),
            sigDeadline: block.timestamp + 1 days
        });

        address token = staking.createManagedTokenWithPermit2WithPolicy(
            "PERMIT-POLICY", "PPL", 1 ether, false, 0, 1_000 ether, 30_000, 7_000, permitSingle, hex"01"
        );
        vm.stopPrank();

        (uint256 maxSupply, uint256 maxMultiplierBps, uint16 rampStartBps) = staking.tokenMintPolicies(token);
        assertEq(maxSupply, 1_000 ether);
        assertEq(maxMultiplierBps, 30_000);
        assertEq(rampStartBps, 7_000);
    }

    function testStakeFeeTokenWithPermit2() public {
        _stake(alice, 500 ether);
        address token = _createToken(alice, "FEEPERMIT", "FPM", 1 ether, true, 200);

        vm.startPrank(alice);
        staking.mintManagedToken(token, 200 ether);
        Series9ManagedToken(token).approve(address(permit2), type(uint256).max);

        IPermit2.PermitSingle memory permitSingle = IPermit2.PermitSingle({
            details: IPermit2.PermitDetails({
                token: token,
                amount: uint160(100 ether),
                expiration: uint48(block.timestamp + 1 days),
                nonce: 0
            }),
            spender: address(staking),
            sigDeadline: block.timestamp + 1 days
        });

        staking.stakeFeeTokenWithPermit2(token, 100 ether, permitSingle, hex"01");
        vm.stopPrank();

        assertEq(staking.feeStakeBalance(token, alice), 100 ether);
    }

    function testPermit2PathRevertsWhenPermit2NotConfigured() public {
        // Re-deploy staking without Permit2 setup to verify guard behavior.
        Series9ManagedToken managedTokenImplementation = new Series9ManagedToken();
        Series9Staking stakingImplementation = new Series9Staking();
        Series9Staking stakingWithoutPermit2 = Series9Staking(
            address(
                new ERC1967Proxy(
                    address(stakingImplementation),
                    abi.encodeCall(
                        Series9Staking.initialize,
                        (address(ser9), REWARD_PER_BLOCK, address(this), address(managedTokenImplementation), CREATION_FEE)
                    )
                )
            )
        );

        vm.startPrank(alice);
        ser9.approve(address(permit2), type(uint256).max);
        IPermit2.PermitSingle memory permitSingle = IPermit2.PermitSingle({
            details: IPermit2.PermitDetails({
                token: address(ser9),
                amount: uint160(1 ether),
                expiration: uint48(block.timestamp + 1 days),
                nonce: 0
            }),
            spender: address(stakingWithoutPermit2),
            sigDeadline: block.timestamp + 1 days
        });

        vm.expectRevert(Series9Staking.Permit2NotConfigured.selector);
        stakingWithoutPermit2.stakeWithPermit2(1 ether, permitSingle, hex"01");
        vm.stopPrank();
    }

    function testOwnerCanUpdateRewardRatePerBlock() public {
        vm.startPrank(alice);
        ser9.approve(address(staking), type(uint256).max);
        staking.stake(100 ether);
        vm.stopPrank();

        vm.roll(6);
        staking.setRewardRatePerBlock(2 ether);
        vm.roll(11);

        vm.startPrank(alice);
        uint256 balanceBefore = ser9.balanceOf(alice);
        staking.claimRewards();
        uint256 claimed = ser9.balanceOf(alice) - balanceBefore;
        vm.stopPrank();

        assertEq(staking.rewardRatePerBlock(), 2 ether);
        assertEq(claimed, 15 ether);
    }

    function testNonOwnerCannotUpdateRewardRatePerBlock() public {
        vm.expectRevert();
        vm.prank(alice);
        staking.setRewardRatePerBlock(2 ether);
    }

    function testAutoLockedStakeGetsHalfRewardVsUnlockedStake() public {
        vm.startPrank(alice);
        ser9.approve(address(staking), type(uint256).max);
        staking.stake(100 ether);
        vm.stopPrank();

        address token = _createToken(alice, "LOCKTEST", "LCK", 1 ether, false, 0);
        vm.prank(alice);
        staking.mintManagedToken(token, 100 ether);

        vm.startPrank(bob);
        ser9.approve(address(staking), type(uint256).max);
        staking.stake(100 ether);
        vm.stopPrank();

        vm.roll(block.number + 3);

        vm.startPrank(alice);
        uint256 aliceBefore = ser9.balanceOf(alice);
        staking.claimRewards();
        uint256 aliceReward = ser9.balanceOf(alice) - aliceBefore;
        vm.stopPrank();

        vm.startPrank(bob);
        uint256 bobBefore = ser9.balanceOf(bob);
        staking.claimRewards();
        uint256 bobReward = ser9.balanceOf(bob) - bobBefore;
        vm.stopPrank();

        assertEq(aliceReward, 1 ether);
        assertEq(bobReward, 2 ether);
    }

    function testManualLockIsDisabled() public {
        _stake(alice, 100 ether);

        vm.startPrank(alice);
        vm.expectRevert(Series9Staking.ManualLockDisabled.selector);
        staking.lock(1 ether);
        vm.stopPrank();
    }

    function testAnyoneCanCreateTokenByPayingFee() public {
        uint256 aliceBefore = ser9.balanceOf(alice);
        address token = _createToken(alice, "INFINITY9", "INF9", 1 ether, false, 0);

        (bool exists, address creator,,) = staking.tokenConfigs(token);
        assertTrue(exists);
        assertEq(creator, alice);
        assertEq(ser9.balanceOf(alice), aliceBefore - CREATION_FEE);
    }

    function testCreateManagedTokenWithPolicyStoresMintPolicy() public {
        address token = _createTokenWithPolicy(alice, "CAPPED", "CAP", 1 ether, false, 0, 1_000 ether, 30_000, 7_000);

        (uint256 maxSupply, uint256 maxMultiplierBps, uint16 rampStartBps) = staking.tokenMintPolicies(token);
        assertEq(maxSupply, 1_000 ether);
        assertEq(maxMultiplierBps, 30_000);
        assertEq(rampStartBps, 7_000);
    }

    function testLegacyCreateManagedTokenUsesUnlimitedPolicyDefaults() public {
        address token = _createToken(alice, "LEGACY", "LEG", 1 ether, false, 0);
        (uint256 maxSupply, uint256 maxMultiplierBps, uint16 rampStartBps) = staking.tokenMintPolicies(token);

        assertEq(maxSupply, 0);
        assertEq(maxMultiplierBps, 10_000);
        assertEq(rampStartBps, 0);
    }

    function testCreateManagedTokenWithPolicyRejectsInvalidMultiplier() public {
        vm.startPrank(alice);
        ser9.approve(address(staking), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(Series9Staking.InvalidMaxMultiplierBps.selector, 9_999));
        staking.createManagedTokenWithPolicy("BADMULT", "BM", 1 ether, false, 0, 1_000 ether, 9_999, 0);
        vm.stopPrank();
    }

    function testCreateManagedTokenWithPolicyRejectsInvalidRampStart() public {
        vm.startPrank(alice);
        ser9.approve(address(staking), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(Series9Staking.InvalidRampStartBps.selector, 10_000));
        staking.createManagedTokenWithPolicy("BADRAMP", "BR", 1 ether, false, 0, 1_000 ether, 20_000, 10_000);
        vm.stopPrank();
    }

    function testCannotCreateTokenWithoutSufficientBalance() public {
        address poor = makeAddr("poor");

        vm.startPrank(poor);
        ser9.approve(address(staking), type(uint256).max);
        vm.expectRevert();
        staking.createManagedToken("FAIL", "FAIL", 1 ether, false, 0);
        vm.stopPrank();
    }

    function testOwnerCanUpdateCreationFee() public {
        staking.setTokenCreationFee(5 ether);
        assertEq(staking.tokenCreationFee(), 5 ether);

        uint256 aliceBefore = ser9.balanceOf(alice);
        _createToken(alice, "EXPENSIVE", "EXP", 1 ether, false, 0);
        assertEq(ser9.balanceOf(alice), aliceBefore - 5 ether);
    }

    function testZeroCreationFeeAllowsFreeCreation() public {
        staking.setTokenCreationFee(0);

        uint256 aliceBefore = ser9.balanceOf(alice);
        _createToken(alice, "FREE", "FRE", 1 ether, false, 0);
        assertEq(ser9.balanceOf(alice), aliceBefore);
    }

    function testCreatorCanUpdateFee() public {
        address token = _createToken(alice, "INFINITY9", "INF9", 1 ether, true, 300);

        (bool exists, address creator, uint256 mintRate, bool feeEnabled) = staking.tokenConfigs(token);
        assertTrue(exists);
        assertEq(creator, alice);
        assertEq(mintRate, 1 ether);
        assertTrue(feeEnabled);

        vm.prank(alice);
        staking.setTokenFeeBps(token, 500);
        assertEq(Series9ManagedToken(token).feeBps(), 500);

        vm.expectRevert(Series9Staking.UnauthorizedTokenCreator.selector);
        vm.prank(bob);
        staking.setTokenFeeBps(token, 700);
    }

    function testOnlyProtocolOwnerCanManageFeeExempt() public {
        address token = _createToken(alice, "FEE", "FEE", 1 ether, true, 200);

        vm.expectRevert();
        vm.prank(alice);
        staking.setFeeExempt(token, bob, true);

        staking.setFeeExempt(token, bob, true);
        assertTrue(Series9ManagedToken(token).isFeeExempt(bob));

        vm.expectRevert(Series9Staking.CannotDisableStakingExemption.selector);
        staking.setFeeExempt(token, address(staking), false);
    }

    function testMintManagedTokensUsesAggregateLockedCollateral() public {
        _stake(alice, 100 ether);

        address tokenA = _createToken(alice, "TOKENA", "TKA", 1 ether, false, 0);
        address tokenB = _createToken(alice, "TOKENB", "TKB", 2 ether, false, 0);

        vm.startPrank(alice);
        staking.mintManagedToken(tokenA, 60 ether);
        staking.mintManagedToken(tokenB, 20 ether);

        assertEq(staking.usedLockedSer9(alice), 100 ether);
        assertEq(staking.userTokenDebt(alice, tokenA), 60 ether);
        assertEq(staking.userTokenDebt(alice, tokenB), 20 ether);

        vm.expectRevert(Series9Staking.ExceedsMintLimit.selector);
        staking.mintManagedToken(tokenA, 1 ether);
        vm.stopPrank();
    }

    function testMintManagedTokenRevertsWhenExceedsMaxSupply() public {
        _stake(alice, 300 ether);
        address token = _createTokenWithPolicy(alice, "MAX", "MAX", 1 ether, false, 0, 100 ether, 20_000, 0);

        vm.startPrank(alice);
        staking.mintManagedToken(token, 100 ether);

        vm.expectRevert(abi.encodeWithSelector(Series9Staking.ExceedsMaxSupply.selector, 101 ether, 100 ether));
        staking.mintManagedToken(token, 1 ether);
        vm.stopPrank();
    }

    function testEffectiveMintRateIncreasesAsSupplyApproachesCap() public {
        _stake(alice, 5_000 ether);
        address token = _createTokenWithPolicy(alice, "DYN", "DYN", 1 ether, false, 0, 1_000 ether, 30_000, 0);

        uint256 rateAtZero = staking.effectiveMintRate(token);

        vm.startPrank(alice);
        staking.mintManagedToken(token, 400 ether);
        vm.stopPrank();

        uint256 rateAfter400 = staking.effectiveMintRate(token);
        assertGt(rateAfter400, rateAtZero);

        vm.startPrank(alice);
        staking.mintManagedToken(token, 500 ether);
        vm.stopPrank();

        uint256 rateAfter900 = staking.effectiveMintRate(token);
        assertGt(rateAfter900, rateAfter400);
    }

    function testRampStartDelaysMintRateIncrease() public {
        _stake(alice, 5_000 ether);
        address token = _createTokenWithPolicy(alice, "RAMP", "RMP", 1 ether, false, 0, 1_000 ether, 30_000, 7_000);

        assertEq(staking.effectiveMintRate(token), 1 ether);

        vm.startPrank(alice);
        staking.mintManagedToken(token, 600 ether);
        vm.stopPrank();

        // 60% < ramp start 70%: no increase yet.
        assertEq(staking.effectiveMintRate(token), 1 ether);

        vm.startPrank(alice);
        staking.mintManagedToken(token, 200 ether);
        vm.stopPrank();

        assertGt(staking.effectiveMintRate(token), 1 ether);
    }

    function testMaxMultiplier10000KeepsFixedMintRate() public {
        _stake(alice, 5_000 ether);
        address token = _createTokenWithPolicy(alice, "FIXED", "FIX", 2 ether, false, 0, 1_000 ether, 10_000, 5_000);

        vm.startPrank(alice);
        staking.mintManagedToken(token, 800 ether);
        vm.stopPrank();

        assertEq(staking.effectiveMintRate(token), 2 ether);
    }

    function testBurnLowersEffectiveMintRate() public {
        _stake(alice, 5_000 ether);
        address token = _createTokenWithPolicy(alice, "BURN", "BRN", 1 ether, false, 0, 1_000 ether, 40_000, 0);

        vm.startPrank(alice);
        staking.mintManagedToken(token, 800 ether);
        uint256 highRate = staking.effectiveMintRate(token);

        staking.burnAndUnlock(token, 400 ether);
        uint256 lowerRate = staking.effectiveMintRate(token);
        vm.stopPrank();

        assertLt(lowerRate, highRate);
    }

    function testHighUtilMintCostsMoreThanLowUtilMintForSameAmount() public {
        _stake(alice, 5_000 ether);
        address token = _createTokenWithPolicy(alice, "COST", "CST", 1 ether, false, 0, 1_000 ether, 40_000, 0);

        uint256 lowUtilCost = staking.previewMintCollateral(token, 50 ether);

        vm.startPrank(alice);
        staking.mintManagedToken(token, 800 ether);
        vm.stopPrank();

        uint256 highUtilCost = staking.previewMintCollateral(token, 50 ether);
        assertGt(highUtilCost, lowUtilCost);
    }

    function testMaxMintableDynamicPolicyIsExact() public {
        _stake(alice, 500 ether);
        address token = _createTokenWithPolicy(alice, "MXM", "MXM", 1 ether, false, 0, 1_000 ether, 30_000, 0);

        uint256 maxMintableAmount = staking.maxMintable(alice, token);
        assertGt(maxMintableAmount, 0);

        uint256 available = staking.availableUnusedLocked(alice);
        uint256 costAtMax = staking.previewMintCollateral(token, maxMintableAmount);
        assertLe(costAtMax, available);

        (uint256 maxSupply,,) = staking.tokenMintPolicies(token);
        uint256 currentSupply = Series9ManagedToken(token).totalSupply();
        uint256 remainingSupply = maxSupply - currentSupply;

        if (maxMintableAmount < remainingSupply) {
            uint256 costAtNext = staking.previewMintCollateral(token, maxMintableAmount + 1);
            assertGt(costAtNext, available);
        } else {
            vm.expectRevert(
                abi.encodeWithSelector(
                    Series9Staking.ExceedsMaxSupply.selector, currentSupply + maxMintableAmount + 1, maxSupply
                )
            );
            staking.previewMintCollateral(token, maxMintableAmount + 1);
        }

        vm.startPrank(alice);
        staking.mintManagedToken(token, maxMintableAmount);
        vm.expectRevert();
        staking.mintManagedToken(token, 1);
        vm.stopPrank();
    }

    function testMaxMintableIsZeroWhenNoUnusedLockedCollateral() public {
        _stake(alice, 100 ether);
        address token = _createTokenWithPolicy(alice, "ZERO", "ZER", 1 ether, false, 0, 1_000 ether, 10_000, 0);

        vm.prank(alice);
        staking.mintManagedToken(token, 100 ether);

        assertEq(staking.availableUnusedLocked(alice), 0);
        assertEq(staking.maxMintable(alice, token), 0);
    }

    function testMaxMintableHandlesOneWeiBoundary() public {
        _stake(alice, 1);
        address token = _createTokenWithPolicy(alice, "ONEWEI", "OWI", 1 ether, false, 0, 1_000 ether, 20_000, 0);

        assertEq(staking.maxMintable(alice, token), 1);
        assertEq(staking.previewMintCollateral(token, 1), 1);

        vm.prank(alice);
        staking.mintManagedToken(token, 1);

        assertEq(staking.maxMintable(alice, token), 0);
    }

    function testMaxMintableIsZeroAtMaxSupply() public {
        _stake(alice, 500 ether);
        address token = _createTokenWithPolicy(alice, "FULL", "FUL", 1 ether, false, 0, 100 ether, 30_000, 0);

        vm.prank(alice);
        staking.mintManagedToken(token, 100 ether);

        assertEq(staking.maxMintable(alice, token), 0);
        vm.expectRevert(abi.encodeWithSelector(Series9Staking.ExceedsMaxSupply.selector, 100 ether + 1, 100 ether));
        staking.previewMintCollateral(token, 1);
    }

    function testBurnAndUnlockOnlyUnlocksBurnEquivalent() public {
        _stake(alice, 100 ether);
        address token = _createToken(alice, "DUAL", "DUL", 2 ether, false, 0);

        vm.startPrank(alice);
        staking.mintManagedToken(token, 30 ether);

        assertEq(staking.lockedBalance(alice), 60 ether);
        assertEq(staking.usedLockedSer9(alice), 60 ether);

        staking.burnAndUnlock(token, 10 ether);
        vm.stopPrank();

        assertEq(staking.userTokenDebt(alice, token), 20 ether);
        assertEq(staking.lockedBalance(alice), 40 ether);
        assertEq(staking.usedLockedSer9(alice), 40 ether);
        assertEq(Series9ManagedToken(token).balanceOf(alice), 20 ether);
    }

    function testPartialDustBurnDoesNotUnlockAllCollateral() public {
        _stake(alice, 1 ether);
        address token = _createToken(alice, "DUST", "DST", 1, false, 0);

        vm.startPrank(alice);
        staking.mintManagedToken(token, 1 ether);
        assertEq(staking.usedLockedSer9(alice), 1);

        staking.burnAndUnlock(token, 1);

        assertEq(staking.userTokenDebt(alice, token), 1 ether - 1);
        assertEq(staking.usedLockedSer9(alice), 1);

        vm.expectRevert(Series9Staking.InsufficientUnusedLockedBalance.selector);
        staking.unlockUnused(1 ether);
        vm.stopPrank();
    }

    function testUnlockUnusedRevertsWithoutUnusedCollateral() public {
        _stake(alice, 100 ether);
        address token = _createToken(alice, "UNLOCK", "ULK", 2 ether, false, 0);

        vm.startPrank(alice);
        staking.mintManagedToken(token, 10 ether);
        vm.expectRevert(Series9Staking.InsufficientUnusedLockedBalance.selector);
        staking.unlockUnused(1 ether);

        staking.burnAndUnlock(token, 10 ether);
        staking.unstake(100 ether);
        vm.stopPrank();

        assertEq(staking.lockedBalance(alice), 0);
        assertEq(staking.usedLockedSer9(alice), 0);
    }

    function testFeeDisabledTokenCannotBeFeeStaked() public {
        _stake(alice, 100 ether);
        address token = _createToken(alice, "NOFEE", "NFE", 1 ether, false, 0);

        vm.startPrank(alice);
        staking.mintManagedToken(token, 50 ether);
        Series9ManagedToken(token).approve(address(staking), type(uint256).max);

        vm.expectRevert(Series9Staking.FeeDisabled.selector);
        staking.stakeFeeToken(token, 10 ether);
        vm.stopPrank();
    }

    function testFeeTokenStakingDistributesTransferFeeProRata() public {
        _stake(alice, 2_000 ether);

        address token = _createToken(alice, "FEECOIN", "FEE", 1 ether, true, 500);

        vm.startPrank(alice);
        staking.mintManagedToken(token, 2_000 ether);
        Series9ManagedToken(token).transfer(bob, 1_200 ether);
        vm.stopPrank();

        vm.startPrank(alice);
        Series9ManagedToken(token).approve(address(staking), type(uint256).max);
        staking.stakeFeeToken(token, 500 ether);
        vm.stopPrank();

        vm.startPrank(bob);
        Series9ManagedToken(token).approve(address(staking), type(uint256).max);
        staking.stakeFeeToken(token, 500 ether);
        Series9ManagedToken(token).transfer(charlie, 200 ether);
        vm.stopPrank();

        assertEq(staking.pendingFeeRewards(token, alice), 65 ether);
        assertEq(staking.pendingFeeRewards(token, bob), 5 ether);

        vm.startPrank(alice);
        uint256 aliceBefore = Series9ManagedToken(token).balanceOf(alice);
        staking.claimFeeRewards(token);
        uint256 aliceClaimed = Series9ManagedToken(token).balanceOf(alice) - aliceBefore;
        vm.stopPrank();

        vm.startPrank(bob);
        uint256 bobBefore = Series9ManagedToken(token).balanceOf(bob);
        staking.claimFeeRewards(token);
        uint256 bobClaimed = Series9ManagedToken(token).balanceOf(bob) - bobBefore;
        vm.stopPrank();

        assertEq(aliceClaimed, 65 ether);
        assertEq(bobClaimed, 5 ether);
    }

    function testFeeAccumulatedWithoutStakersIsDistributedWhenFirstStakerJoins() public {
        _stake(alice, 2_000 ether);
        address token = _createToken(alice, "LATEFEE", "LFE", 1 ether, true, 500);

        vm.startPrank(alice);
        staking.mintManagedToken(token, 1_000 ether);
        Series9ManagedToken(token).transfer(bob, 1_000 ether);
        vm.stopPrank();

        vm.startPrank(bob);
        Series9ManagedToken(token).approve(address(staking), type(uint256).max);
        staking.stakeFeeToken(token, 950 ether);
        assertEq(staking.pendingFeeRewards(token, bob), 50 ether - 50);

        uint256 bobBefore = Series9ManagedToken(token).balanceOf(bob);
        staking.claimFeeRewards(token);
        uint256 bobClaimed = Series9ManagedToken(token).balanceOf(bob) - bobBefore;
        vm.stopPrank();

        assertEq(bobClaimed, 50 ether - 50);
    }

    function testStakingTransfersAreFeeExempt() public {
        _stake(alice, 200 ether);
        address token = _createToken(alice, "EXEMPT", "XEM", 1 ether, true, 500);

        vm.startPrank(alice);
        staking.mintManagedToken(token, 100 ether);
        Series9ManagedToken(token).approve(address(staking), type(uint256).max);

        staking.stakeFeeToken(token, 80 ether);
        staking.unstakeFeeToken(token, 80 ether);
        vm.stopPrank();

        assertEq(Series9ManagedToken(token).balanceOf(alice), 100 ether);
        assertEq(Series9ManagedToken(token).balanceOf(address(staking)), 0);
    }

    function testSetManagedTokenImplementationAffectsFutureDeployments() public {
        Series9ManagedTokenV2 managedV2 = new Series9ManagedTokenV2();
        staking.setManagedTokenImplementation(address(managedV2));

        address token = _createToken(alice, "UPGRADE", "UPG", 1 ether, false, 0);
        assertEq(Series9ManagedTokenV2(token).version(), 2);
    }

    function testOnlyOwnerCanSetManagedTokenImplementation() public {
        Series9ManagedTokenV2 managedV2 = new Series9ManagedTokenV2();

        vm.expectRevert();
        vm.prank(alice);
        staking.setManagedTokenImplementation(address(managedV2));
    }

    function testUpgradeTokensUpgradesSer9AndAllManagedTokens() public {
        address tokenA = _createToken(alice, "A", "A", 1 ether, false, 0);
        address tokenB = _createToken(alice, "B", "B", 2 ether, true, 300);

        SER9TokenV2 ser9V2 = new SER9TokenV2();
        Series9ManagedTokenV2 managedV2 = new Series9ManagedTokenV2();

        staking.upgradeTokens(address(ser9V2), address(managedV2), bytes(""), bytes(""));

        assertEq(SER9TokenV2(address(ser9)).version(), 2);
        assertEq(Series9ManagedTokenV2(tokenA).version(), 2);
        assertEq(Series9ManagedTokenV2(tokenB).version(), 2);
        assertEq(staking.managedTokenImplementation(), address(managedV2));
    }

    function testOnlyOwnerCanUpgradeTokens() public {
        SER9TokenV2 ser9V2 = new SER9TokenV2();
        Series9ManagedTokenV2 managedV2 = new Series9ManagedTokenV2();

        vm.expectRevert();
        vm.prank(alice);
        staking.upgradeTokens(address(ser9V2), address(managedV2), bytes(""), bytes(""));
    }

    function testUpgradeTokensRevertsOnZeroAddressImplementation() public {
        Series9ManagedTokenV2 managedV2 = new Series9ManagedTokenV2();

        vm.expectRevert(abi.encodeWithSelector(Series9Staking.InvalidImplementation.selector, address(0)));
        staking.upgradeTokens(address(0), address(managedV2), bytes(""), bytes(""));
    }

    function testUpgradeTokensRevertsOnEOAImplementation() public {
        SER9TokenV2 ser9V2 = new SER9TokenV2();

        vm.expectRevert(abi.encodeWithSelector(Series9Staking.InvalidImplementation.selector, alice));
        staking.upgradeTokens(address(ser9V2), alice, bytes(""), bytes(""));
    }

    function testUpgradeTokensRevertsOnNonUUPSImplementation() public {
        SER9TokenV2 ser9V2 = new SER9TokenV2();
        NonUUPSImplementation badManagedImpl = new NonUUPSImplementation();

        vm.expectRevert(
            abi.encodeWithSelector(
                Series9Staking.ImplementationNotUUPSCompatible.selector, address(badManagedImpl)
            )
        );
        staking.upgradeTokens(address(ser9V2), address(badManagedImpl), bytes(""), bytes(""));
    }

    function testUpgradeTokensRevertsOnWrongUUIDImplementation() public {
        SER9TokenV2 ser9V2 = new SER9TokenV2();
        WrongUUIDImplementation badManagedImpl = new WrongUUIDImplementation();

        vm.expectRevert(
            abi.encodeWithSelector(
                Series9Staking.UnsupportedProxiableUUID.selector, address(badManagedImpl), bytes32(uint256(123))
            )
        );
        staking.upgradeTokens(address(ser9V2), address(badManagedImpl), bytes(""), bytes(""));
    }

    function testUpgradeTokensPrevalidationPreventsPartialUpgrade() public {
        address token = _createToken(alice, "PRE", "PRE", 1 ether, false, 0);

        SER9TokenV2 ser9V2 = new SER9TokenV2();
        NonUUPSImplementation badManagedImpl = new NonUUPSImplementation();

        vm.expectRevert();
        staking.upgradeTokens(address(ser9V2), address(badManagedImpl), bytes(""), bytes(""));

        (bool ser9HasVersion,) = address(ser9).staticcall(abi.encodeWithSelector(SER9TokenV2.version.selector));
        (bool managedHasVersion,) =
            address(token).staticcall(abi.encodeWithSelector(Series9ManagedTokenV2.version.selector));
        assertFalse(ser9HasVersion);
        assertFalse(managedHasVersion);
    }

    function testUpgradeTokensPreservesStateAndCreatorPrivileges() public {
        _stake(alice, 200 ether);
        address token = _createToken(alice, "STATE", "STA", 2 ether, true, 300);

        vm.startPrank(alice);
        staking.mintManagedToken(token, 30 ether);
        vm.stopPrank();

        uint256 stakedBefore = staking.stakedBalance(alice);
        uint256 lockedBefore = staking.lockedBalance(alice);
        uint256 usedBefore = staking.usedLockedSer9(alice);
        uint256 debtBefore = staking.userTokenDebt(alice, token);
        uint256 feeBpsBefore = Series9ManagedToken(token).feeBps();

        SER9TokenV2 ser9V2 = new SER9TokenV2();
        Series9ManagedTokenV2 managedV2 = new Series9ManagedTokenV2();
        staking.upgradeTokens(address(ser9V2), address(managedV2), bytes(""), bytes(""));

        assertEq(staking.stakedBalance(alice), stakedBefore);
        assertEq(staking.lockedBalance(alice), lockedBefore);
        assertEq(staking.usedLockedSer9(alice), usedBefore);
        assertEq(staking.userTokenDebt(alice, token), debtBefore);
        assertEq(Series9ManagedToken(token).feeBps(), feeBpsBefore);

        vm.prank(alice);
        staking.setTokenFeeBps(token, 400);
        assertEq(Series9ManagedToken(token).feeBps(), 400);
    }

    function testUpgradeTokensWorksForManyManagedTokens() public {
        address[] memory tokens = new address[](8);
        for (uint256 i = 0; i < tokens.length; ++i) {
            string memory suffix = vm.toString(i);
            tokens[i] = _createToken(
                alice, string.concat("TOKEN", suffix), string.concat("TK", suffix), 1 ether + i, false, 0
            );
        }

        SER9TokenV2 ser9V2 = new SER9TokenV2();
        Series9ManagedTokenV2 managedV2 = new Series9ManagedTokenV2();
        staking.upgradeTokens(address(ser9V2), address(managedV2), bytes(""), bytes(""));

        for (uint256 i = 0; i < tokens.length; ++i) {
            assertEq(Series9ManagedTokenV2(tokens[i]).version(), 2);
        }
    }

    function testPauseBlocksUserActions() public {
        vm.startPrank(alice);
        ser9.approve(address(staking), type(uint256).max);
        staking.stake(100 ether);
        vm.stopPrank();

        staking.pause();

        vm.startPrank(alice);
        vm.expectRevert();
        staking.stake(50 ether);

        vm.expectRevert();
        staking.unstake(50 ether);
        vm.stopPrank();

        staking.unpause();

        vm.prank(alice);
        staking.unstake(50 ether);
        assertEq(staking.stakedBalance(alice), 50 ether);
    }

    function testOnlyOwnerCanPauseAndUnpause() public {
        vm.expectRevert();
        vm.prank(alice);
        staking.pause();

        staking.pause();

        vm.expectRevert();
        vm.prank(alice);
        staking.unpause();
    }

    function testSetSer9StakingContract() public {
        address newStaking = makeAddr("newStaking");

        staking.setSer9StakingContract(newStaking);

        vm.prank(newStaking);
        ser9.mint(alice, 1 ether);
        assertEq(ser9.balanceOf(alice), 10_001 ether);
    }

    function testNonOwnerCannotSetSer9StakingContract() public {
        vm.expectRevert();
        vm.prank(alice);
        staking.setSer9StakingContract(makeAddr("newStaking"));
    }

    // --- fuzz tests ---

    function testFuzzStakeUnstakePreservesBalance(uint256 stakeAmount) public {
        stakeAmount = bound(stakeAmount, 1, 10_000 ether);

        vm.startPrank(alice);
        ser9.approve(address(staking), type(uint256).max);
        uint256 balanceBefore = ser9.balanceOf(alice);

        staking.stake(stakeAmount);
        assertEq(staking.stakedBalance(alice), stakeAmount);

        staking.unstake(stakeAmount);
        assertEq(staking.stakedBalance(alice), 0);
        assertEq(ser9.balanceOf(alice), balanceBefore);
        vm.stopPrank();
    }

    function testFuzzMintBurnCollateralAccounting(uint256 mintAmount) public {
        mintAmount = bound(mintAmount, 1, 99 ether);

        _stake(alice, 100 ether);
        address token = _createToken(alice, "FUZZ", "FZZ", 1 ether, false, 0);

        vm.startPrank(alice);
        staking.mintManagedToken(token, mintAmount);
        staking.burnAndUnlock(token, mintAmount);
        vm.stopPrank();

        assertEq(staking.userTokenDebt(alice, token), 0);
        assertEq(staking.usedLockedSer9(alice), 0);
        assertEq(staking.lockedBalance(alice), 0);
    }

    function testFuzzMultiStakerRewardProportionality(uint256 aliceAmount, uint256 bobAmount) public {
        aliceAmount = bound(aliceAmount, 1 ether, 5_000 ether);
        bobAmount = bound(bobAmount, 1 ether, 5_000 ether);

        vm.startPrank(alice);
        ser9.approve(address(staking), type(uint256).max);
        staking.stake(aliceAmount);
        vm.stopPrank();

        vm.startPrank(bob);
        ser9.approve(address(staking), type(uint256).max);
        staking.stake(bobAmount);
        vm.stopPrank();

        vm.roll(block.number + 100);

        uint256 aliceEarned = staking.earned(alice);
        uint256 bobEarned = staking.earned(bob);
        uint256 totalEarned = aliceEarned + bobEarned;

        // Both unlocked: weight = staked * 2, proportional to stake amounts
        assertApproxEqRel(aliceEarned * (aliceAmount + bobAmount), totalEarned * aliceAmount, 1e14);
    }

    // --- edge case tests ---

    function testCannotStakeZero() public {
        vm.startPrank(alice);
        ser9.approve(address(staking), type(uint256).max);
        vm.expectRevert(Series9Staking.ZeroAmount.selector);
        staking.stake(0);
        vm.stopPrank();
    }

    function testCannotUnstakeMoreThanStaked() public {
        vm.startPrank(alice);
        ser9.approve(address(staking), type(uint256).max);
        staking.stake(10 ether);

        vm.expectRevert(Series9Staking.InsufficientStakedBalance.selector);
        staking.unstake(11 ether);
        vm.stopPrank();
    }

    function testCannotClaimZeroRewards() public {
        vm.expectRevert(Series9Staking.NoRewards.selector);
        vm.prank(alice);
        staking.claimRewards();
    }

    function testStakeAndImmediateUnstake() public {
        vm.startPrank(alice);
        ser9.approve(address(staking), type(uint256).max);
        uint256 balanceBefore = ser9.balanceOf(alice);

        staking.stake(100 ether);
        staking.unstake(100 ether);
        vm.stopPrank();

        assertEq(ser9.balanceOf(alice), balanceBefore);
        assertEq(staking.totalStaked(), 0);
    }

    // --- fee recipient tests ---

    function testOwnerCanSetTokenFeeRecipient() public {
        address token = _createToken(alice, "FEERCPT", "FRC", 1 ether, true, 300);
        address newRecipient = makeAddr("newRecipient");

        staking.setTokenFeeRecipient(token, newRecipient);
        assertEq(Series9ManagedToken(token).feeRecipient(), newRecipient);
    }

    function testNonOwnerCannotSetTokenFeeRecipient() public {
        address token = _createToken(alice, "FEERCPT2", "FR2", 1 ether, true, 300);

        vm.expectRevert();
        vm.prank(alice);
        staking.setTokenFeeRecipient(token, makeAddr("newRecipient"));
    }

    function testCannotSetFeeRecipientToZeroAddress() public {
        address token = _createToken(alice, "FEERCPT3", "FR3", 1 ether, true, 300);

        vm.expectRevert(Series9ManagedToken.InvalidFeeRecipient.selector);
        staking.setTokenFeeRecipient(token, address(0));
    }

    function _stake(address user, uint256 stakeAmount) internal {
        vm.startPrank(user);
        ser9.approve(address(staking), type(uint256).max);
        staking.stake(stakeAmount);
        vm.stopPrank();
    }

    function _createToken(
        address creator,
        string memory name,
        string memory symbol,
        uint256 mintRate,
        bool feeEnabled,
        uint16 feeBps
    ) internal returns (address token) {
        vm.startPrank(creator);
        ser9.approve(address(staking), type(uint256).max);
        token = staking.createManagedToken(name, symbol, mintRate, feeEnabled, feeBps);
        vm.stopPrank();
    }

    function _createTokenWithPolicy(
        address creator,
        string memory name,
        string memory symbol,
        uint256 mintRate,
        bool feeEnabled,
        uint16 feeBps,
        uint256 maxSupply,
        uint256 maxMultiplierBps,
        uint16 rampStartBps
    ) internal returns (address token) {
        vm.startPrank(creator);
        ser9.approve(address(staking), type(uint256).max);
        token = staking.createManagedTokenWithPolicy(
            name, symbol, mintRate, feeEnabled, feeBps, maxSupply, maxMultiplierBps, rampStartBps
        );
        vm.stopPrank();
    }
}
