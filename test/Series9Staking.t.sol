// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";
import {StdStorage, stdStorage} from "forge-std/StdStorage.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC1822Proxiable} from "openzeppelin-contracts/contracts/interfaces/draft-IERC1822.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeCast} from "openzeppelin-contracts/contracts/utils/math/SafeCast.sol";

import {SER9Token} from "../src/SER9Token.sol";
import {Series9Staking} from "../src/Series9Staking.sol";
import {IPermit2} from "../src/interfaces/IPermit2.sol";
import {IMonadStaking} from "../src/interfaces/IMonadStaking.sol";

contract SER9TokenV2 is SER9Token {
    function version() external pure returns (uint256) {
        return 2;
    }
}



contract NonUUPSImplementation {}

contract WrongUUIDImplementation is IERC1822Proxiable {
    // forge-lint: disable-next-line(mixed-case-function)
    function proxiableUUID() external pure returns (bytes32) {
        return bytes32(uint256(123));
    }
}

contract StakingContractStub {}

contract Series9StakingHarness is Series9Staking {
    function exposeDelegateMonadAmountToValidator(uint64 validatorId, uint256 amount) external returns (bool) {
        return _delegateMonadAmountToValidator(validatorId, amount);
    }

    function exposeQueueUnstakeFromDelegations(uint256 amount, uint64 epoch, uint256 maxValidators)
        external
        returns (uint256 queuedAmount, uint64 maxClaimableEpoch)
    {
        return _queueUnstakeFromDelegations(amount, epoch, maxValidators);
    }

    function exposeUpdateMonadTargets() external {
        _updateMonadTargets();
    }

    function exposeTargetDelegatedPrincipal() external view returns (uint256) {
        return _targetDelegatedPrincipal();
    }

    function pendingUndelegateTicketsLength() external view returns (uint256) {
        return pendingUndelegateTickets.length;
    }

    function trackedValidatorsLength() external view returns (uint256) {
        return trackedValidators.length;
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

        require(IERC20(token).transferFrom(from, to, amount), "Permit2: transfer failed");
    }
}

contract MonadStakingMock is IMonadStaking {
    struct ValidatorInfo {
        uint256 stake;
        uint256 accRewardPerToken;
        uint256 commission;
        uint256 unclaimedRewards;
    }

    struct DelegatorInfo {
        uint256 stake;
        uint256 accRewardPerToken;
        uint256 unclaimedRewards;
    }

    struct WithdrawalRequestInfo {
        uint256 amount;
        uint64 claimableEpoch;
    }

    uint64 internal currentEpoch;
    bool internal currentInDelayPeriod;
    bool internal revertEpochRead;
    uint64[] internal executionValset;
    uint16 internal withdrawSlashBps;

    mapping(uint64 => ValidatorInfo) internal validatorInfo;
    mapping(uint64 => mapping(address => DelegatorInfo)) internal delegatorInfo;
    mapping(uint64 => mapping(address => mapping(uint8 => WithdrawalRequestInfo))) internal withdrawalInfo;
    mapping(uint64 => mapping(address => uint256)) internal pendingRewards;

    function setEpoch(uint64 epoch_, bool inDelayPeriod_) external {
        currentEpoch = epoch_;
        currentInDelayPeriod = inDelayPeriod_;
    }

    function setEpochReadFailure(bool shouldFail) external {
        revertEpochRead = shouldFail;
    }

    /// @notice Simulate Monad slashing delegated/unbonding stake: withdraw returns only
    ///         (10000 - bps)/10000 of the requested amount; the remainder stays in the mock.
    function setWithdrawSlashBps(uint16 bps) external {
        withdrawSlashBps = bps;
    }

    function setExecutionValidatorSet(uint64[] calldata validatorIds) external {
        delete executionValset;
        for (uint256 i = 0; i < validatorIds.length; ++i) {
            executionValset.push(validatorIds[i]);
        }
    }

    function setValidator(uint64 validatorId, uint256 stake_, uint256 accRewardPerToken_, uint256 commission_) external {
        validatorInfo[validatorId].stake = stake_;
        validatorInfo[validatorId].accRewardPerToken = accRewardPerToken_;
        validatorInfo[validatorId].commission = commission_;
    }

    function bumpValidatorAccRewardPerToken(uint64 validatorId, uint256 delta) external {
        validatorInfo[validatorId].accRewardPerToken += delta;
    }

    function setDelegatorRewards(uint64 validatorId, address delegator, uint256 rewardAmount) external {
        pendingRewards[validatorId][delegator] = rewardAmount;
    }

    function delegate(uint64 validatorId) external payable returns (bool success) {
        validatorInfo[validatorId].stake += msg.value;
        delegatorInfo[validatorId][msg.sender].stake += msg.value;
        return true;
    }

    function undelegate(uint64 validatorId, uint256 amount, uint8 withdrawId) external returns (bool success) {
        DelegatorInfo storage info = delegatorInfo[validatorId][msg.sender];
        require(info.stake >= amount, "mock: insufficient stake");

        info.stake -= amount;
        validatorInfo[validatorId].stake -= amount;
        withdrawalInfo[validatorId][msg.sender][withdrawId] =
            WithdrawalRequestInfo({amount: amount, claimableEpoch: currentEpoch + 5});
        return true;
    }

    function withdraw(uint64 validatorId, uint8 withdrawId) external returns (bool success) {
        WithdrawalRequestInfo storage info = withdrawalInfo[validatorId][msg.sender][withdrawId];
        require(info.amount > 0, "mock: no withdrawal");
        require(currentEpoch >= info.claimableEpoch, "mock: not matured");

        uint256 amount = info.amount;
        info.amount = 0;
        info.claimableEpoch = 0;

        uint256 payout = amount - (amount * withdrawSlashBps) / 10_000;
        (bool ok,) = msg.sender.call{value: payout}("");
        require(ok, "mock: transfer failed");
        return true;
    }

    function claimRewards(uint64 validatorId) external returns (bool success) {
        uint256 rewardAmount = pendingRewards[validatorId][msg.sender];
        if (rewardAmount == 0) {
            return true;
        }

        pendingRewards[validatorId][msg.sender] = 0;
        (bool ok,) = msg.sender.call{value: rewardAmount}("");
        require(ok, "mock: reward transfer failed");
        return true;
    }

    function getExecutionValidatorSet(uint32 startIndex)
        external
        view
        returns (bool isDone, uint32 nextIndex, uint64[] memory valIds)
    {
        uint256 length = executionValset.length;
        if (startIndex >= length) {
            return (true, startIndex, new uint64[](0));
        }

        uint256 remaining = length - startIndex;
        valIds = new uint64[](remaining);
        for (uint256 i = 0; i < remaining; ++i) {
            valIds[i] = executionValset[startIndex + i];
        }

        nextIndex = SafeCast.toUint32(length);
        isDone = true;
    }

    function getValidator(uint64 validatorId)
        external
        view
        returns (
            address authAddress,
            uint64 flags,
            uint256 stake_,
            uint256 accRewardPerToken,
            uint256 commission,
            uint256 unclaimedRewards,
            uint256 consensusStake,
            uint256 consensusCommission,
            uint256 snapshotStake,
            uint256 snapshotCommission,
            bytes memory secpPubkey,
            bytes memory blsPubkey
        )
    {
        ValidatorInfo storage info = validatorInfo[validatorId];
        return (
            address(0),
            0,
            info.stake,
            info.accRewardPerToken,
            info.commission,
            info.unclaimedRewards,
            0,
            0,
            0,
            0,
            "",
            ""
        );
    }

    function getDelegator(uint64 validatorId, address delegator)
        external
        view
        returns (
            uint256 stake_,
            uint256 accRewardPerToken,
            uint256 unclaimedRewards,
            uint256 deltaStake,
            uint256 nextDeltaStake,
            uint64 deltaEpoch,
            uint64 nextDeltaEpoch
        )
    {
        DelegatorInfo storage info = delegatorInfo[validatorId][delegator];
        return (info.stake, info.accRewardPerToken, info.unclaimedRewards, 0, 0, 0, 0);
    }

    function getEpoch() external view returns (uint64 epoch, bool inEpochDelayPeriod) {
        require(!revertEpochRead, "mock: epoch read failed");
        return (currentEpoch, currentInDelayPeriod);
    }
}

contract Series9StakingTest is Test {
    using stdStorage for StdStorage;
    using SafeCast for uint256;

    SER9Token internal ser9;
    Series9StakingHarness internal staking;
    Permit2Mock internal permit2;
    MonadStakingMock internal monadStakingMock;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal charlie = makeAddr("charlie");

    uint256 internal constant INITIAL_SUPPLY = 1_000_000_000_000 ether;
    uint256 internal constant REWARD_PER_BLOCK = 1 ether;
    uint256 internal constant CREATION_FEE = 1 ether;
    uint256 internal constant MONAD_BLOCKS_PER_YEAR = 31_536_000;
    uint256 internal constant MONAD_DELEGATED_SHARE_BPS = 10_000;

    function setUp() public {
        SER9Token ser9Implementation = new SER9Token();
        Series9StakingHarness stakingImplementation = new Series9StakingHarness();

        ser9 = SER9Token(
            address(new ERC1967Proxy(address(ser9Implementation), abi.encodeCall(SER9Token.initialize, (address(this)))))
        );

        staking = Series9StakingHarness(
            payable(
                new ERC1967Proxy(
                    address(stakingImplementation),
                    abi.encodeCall(
                        Series9Staking.initialize,
                        (address(ser9), REWARD_PER_BLOCK, address(this), CREATION_FEE)
                    )
                )
            )
        );

        permit2 = new Permit2Mock();
        staking.setPermit2(address(permit2));

        ser9.setStakingContract(address(staking));
        ser9.transferOwnership(address(staking));

        assertTrue(ser9.transfer(alice, 10_000 ether));
        assertTrue(ser9.transfer(bob, 10_000 ether));
        assertTrue(ser9.transfer(charlie, 10_000 ether));

        _installMonadPrecompileMock();
    }

    function testInitialSupplyIsOneTrillion() public view {
        assertEq(ser9.totalSupply(), INITIAL_SUPPLY);
    }

    function testInitializeSetsMonadRewardDefaults() public view {
        assertEq(staking.monadRewardRatePerBlock(), REWARD_PER_BLOCK / 8);
        assertEq(staking.monadLastUpdateBlock(), block.number);
    }

    function testCannotStakeBeforeInitialize() public {
        Series9Staking uninitializedStaking = new Series9Staking();

        vm.expectRevert(Series9Staking.NotInitialized.selector);
        uninitializedStaking.stake(1 ether);
    }

    function testCannotStakeMonadBeforeInitialize() public {
        Series9Staking uninitializedStaking = new Series9Staking();

        vm.expectRevert(Series9Staking.NotInitialized.selector);
        uninitializedStaking.stakeMonad{value: 1 ether}();
    }

    function testOwnerCannotMintSER9Directly() public {
        vm.expectRevert(SER9Token.UnauthorizedMinter.selector);
        ser9.mint(alice, 1 ether);
    }

    function testStakingContractAddressCanBeUpdated() public {
        address oldStaking = address(staking);
        address newStaking = address(new StakingContractStub());

        vm.prank(address(staking));
        ser9.setStakingContract(newStaking);

        vm.expectRevert(SER9Token.UnauthorizedMinter.selector);
        vm.prank(oldStaking);
        ser9.mint(alice, 1 ether);

        vm.prank(newStaking);
        ser9.mint(alice, 1 ether);
        assertEq(ser9.balanceOf(alice), 10_001 ether);
    }

    function testStakingContractAddressRejectsEOA() public {
        vm.prank(address(staking));
        vm.expectRevert(SER9Token.InvalidStakingAddress.selector);
        ser9.setStakingContract(makeAddr("newStaking"));
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




    function testPermit2PathRevertsWhenPermit2NotConfigured() public {
        // Re-deploy staking without Permit2 setup to verify guard behavior.
        Series9Staking stakingImplementation = new Series9Staking();
        Series9Staking stakingWithoutPermit2 = Series9Staking(
            payable(
                new ERC1967Proxy(
                    address(stakingImplementation),
                    abi.encodeCall(
                        Series9Staking.initialize,
                        (address(ser9), REWARD_PER_BLOCK, address(this), CREATION_FEE)
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





































    function testUpgradeSer9UsesExplicitPath() public {
        SER9TokenV2 ser9V2 = new SER9TokenV2();

        staking.upgradeSer9(address(ser9V2), bytes(""));

        assertEq(SER9TokenV2(address(ser9)).version(), 2);
    }

    function testOnlyOwnerCanUpgradeSer9() public {
        SER9TokenV2 ser9V2 = new SER9TokenV2();

        vm.expectRevert();
        vm.prank(alice);
        staking.upgradeSer9(address(ser9V2), bytes(""));
    }

    function testUpgradeSer9RevertsOnZeroAddressImplementation() public {
        vm.expectRevert(abi.encodeWithSelector(Series9Staking.InvalidImplementation.selector, address(0)));
        staking.upgradeSer9(address(0), bytes(""));
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

    function testPausedMaturedSer9ClaimStillSucceeds() public {
        vm.startPrank(alice);
        ser9.approve(address(staking), type(uint256).max);
        staking.stake(100 ether);
        staking.unstake(100 ether);
        vm.stopPrank();

        monadStakingMock.setEpoch(6, false);
        staking.pause();

        uint256 balanceBefore = ser9.balanceOf(alice);
        vm.prank(alice);
        staking.claimUnstaked(0);

        assertEq(ser9.balanceOf(alice), balanceBefore + 100 ether);
    }

    function testSetSer9StakingContract() public {
        address newStaking = address(new StakingContractStub());

        staking.setSer9StakingContract(newStaking);

        vm.prank(newStaking);
        ser9.mint(alice, 1 ether);
        assertEq(ser9.balanceOf(alice), 10_001 ether);
    }

    function testSetSer9StakingContractRejectsEOA() public {
        vm.expectRevert(SER9Token.InvalidStakingAddress.selector);
        staking.setSer9StakingContract(makeAddr("newStaking"));
    }

    function testNonOwnerCannotSetSer9StakingContract() public {
        vm.expectRevert();
        vm.prank(alice);
        staking.setSer9StakingContract(makeAddr("newStaking"));
    }

    // --- fuzz tests ---

    function testFuzzStakeUnstakeClaimPreservesBalance(uint256 stakeAmount) public {
        stakeAmount = bound(stakeAmount, 1, 10_000 ether);

        vm.startPrank(alice);
        ser9.approve(address(staking), type(uint256).max);
        uint256 balanceBefore = ser9.balanceOf(alice);

        staking.stake(stakeAmount);
        assertEq(staking.stakedBalance(alice), stakeAmount);

        staking.unstake(stakeAmount);
        assertEq(staking.stakedBalance(alice), 0);
        assertEq(ser9.balanceOf(alice), balanceBefore - stakeAmount);

        monadStakingMock.setEpoch(6, false);
        staking.claimUnstaked(0);
        assertEq(ser9.balanceOf(alice), balanceBefore);
        vm.stopPrank();
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

    function testStakeAndDelayedUnstakeClaim() public {
        vm.startPrank(alice);
        ser9.approve(address(staking), type(uint256).max);
        uint256 balanceBefore = ser9.balanceOf(alice);

        staking.stake(100 ether);
        staking.unstake(100 ether);

        (uint256 amount, uint64 requestEpoch, uint64 minClaimEpoch, bool claimed) = staking.ser9UnstakeRequest(alice, 0);
        assertEq(amount, 100 ether);
        assertEq(requestEpoch, 1);
        assertEq(minClaimEpoch, 6);
        assertFalse(claimed);
        assertEq(ser9.balanceOf(alice), balanceBefore - 100 ether);

        monadStakingMock.setEpoch(5, false);
        vm.expectRevert(abi.encodeWithSelector(Series9Staking.UnstakeRequestNotClaimable.selector, uint64(5), uint64(6)));
        staking.claimUnstaked(0);

        monadStakingMock.setEpoch(6, false);
        staking.claimUnstaked(0);
        vm.stopPrank();

        assertEq(ser9.balanceOf(alice), balanceBefore);
        assertEq(staking.totalStaked(), 0);
    }


    // --- fee recipient tests ---










    function testInitializeV2SetsDefaultMonadRewardRate() public {
        staking.setMonadRewardRatePerBlock(3 ether);
        uint256 initialMonadUpdateBlock = staking.monadLastUpdateBlock();

        staking.initializeV2();

        assertEq(staking.monadRewardRatePerBlock(), 3 ether);
        assertEq(staking.monadLastUpdateBlock(), initialMonadUpdateBlock);
    }

    function testStakeMonadAccruesAndClaimsSER9Rewards() public {
        staking.initializeV2();
        vm.deal(alice, 20 ether);

        vm.startPrank(alice);
        staking.stakeMonad{value: 8 ether}();
        vm.roll(block.number + 8);

        uint256 beforeBalance = ser9.balanceOf(alice);
        staking.claimRewards();
        uint256 claimed = ser9.balanceOf(alice) - beforeBalance;
        vm.stopPrank();

        assertEq(claimed, 1 ether);
    }

    function testRebalanceDelegatesEntireStake() public {
        staking.initializeV2();
        staking.initializeV3();
        _installMonadPrecompileMock();
        _configureValidatorSet123456();

        vm.deal(alice, 20 ether);
        vm.prank(alice);
        staking.stakeMonad{value: 10 ether}();

        staking.updateMonadTargets();
        staking.rebalanceMonadDelegations();

        assertEq(staking.cachedMonadObservedApy(), 0);
        assertEq(staking.cachedMonadDelegatedShareBps(), MONAD_DELEGATED_SHARE_BPS);
        assertEq(staking.exposeTargetDelegatedPrincipal(), 10 ether);
        assertEq(staking.totalDelegatedMonad(), 10 ether);
        assertEq(address(staking).balance, 0);
    }

    function testStakeMonadAutoDelegatesUsingExistingTargets() public {
        staking.initializeV2();
        staking.initializeV3();
        _installMonadPrecompileMock();
        _configureValidatorSet123456();

        vm.deal(alice, 20 ether);
        vm.prank(alice);
        staking.stakeMonad{value: 10 ether}();
        staking.updateMonadTargets();
        staking.rebalanceMonadDelegations();

        assertEq(staking.totalDelegatedMonad(), 10 ether);

        vm.deal(bob, 20 ether);
        vm.prank(bob);
        staking.stakeMonad{value: 3 ether}();

        uint64 lastTargetValidatorId = staking.targetValidatorIds(4);
        assertEq(staking.totalDelegatedMonad(), 13 ether);
        assertEq(staking.validatorDelegatedAmount(lastTargetValidatorId), 2.6 ether);
        assertEq(address(staking).balance, 0);
    }

    function testHarvestMonadValidatorRewardsClaimsAllTrackedValidators() public {
        staking.initializeV2();
        staking.initializeV3();
        _installMonadPrecompileMock();
        _configureValidatorSet123456();

        vm.deal(alice, 20 ether);
        vm.prank(alice);
        staking.stakeMonad{value: 10 ether}();
        staking.updateMonadTargets();
        staking.rebalanceMonadDelegations();

        monadStakingMock.setDelegatorRewards(1, address(staking), 1 ether);
        monadStakingMock.setDelegatorRewards(5, address(staking), 2 ether);

        staking.setMonadRebalanceKeeper(bob, true);
        vm.prank(bob);
        staking.harvestMonadValidatorRewards();

        assertEq(staking.protocolMonadYieldAccrued(), 3 ether);
        assertEq(address(staking).balance, 3 ether);
    }

    function testOwnerCanClaimMonadValidatorReward() public {
        staking.initializeV2();
        staking.initializeV3();
        _installMonadPrecompileMock();
        _configureValidatorSet123456();

        vm.deal(alice, 20 ether);
        vm.prank(alice);
        staking.stakeMonad{value: 10 ether}();
        staking.rebalanceMonadDelegations();

        monadStakingMock.setDelegatorRewards(3, address(staking), 5 ether);

        uint256 beforeBalance = address(staking).balance;
        staking.claimMonadValidatorReward(3);

        assertEq(staking.protocolMonadYieldAccrued(), 5 ether);
        assertEq(address(staking).balance, beforeBalance + 5 ether);
    }

    function testNonOwnerCannotClaimMonadValidatorReward() public {
        vm.expectRevert();
        vm.prank(alice);
        staking.claimMonadValidatorReward(1);
    }

    function testOwnerCanDelegateUnstakedMonad() public {
        staking.initializeV2();
        staking.initializeV3();
        _installMonadPrecompileMock();
        _configureValidatorSet123456();

        vm.deal(alice, 20 ether);
        vm.prank(alice);
        staking.stakeMonad{value: 10 ether}();

        // Before rebalance, targets are not set so auto-delegate does nothing.
        assertEq(staking.totalDelegatedMonad(), 0);

        // Update targets and rebalance to delegate the staked MONAD.
        staking.updateMonadTargets();
        staking.rebalanceMonadDelegations();
        assertEq(staking.totalDelegatedMonad(), 10 ether);

        // Calling delegateUnstakedMonad as owner is a no-op when everything is already delegated.
        staking.delegateUnstakedMonad();
        assertEq(staking.totalDelegatedMonad(), 10 ether);
    }

    function testNonOwnerCannotDelegateUnstakedMonad() public {
        vm.expectRevert();
        vm.prank(alice);
        staking.delegateUnstakedMonad();
    }

    function testHarvestClaimsAllFiveDelegatedValidatorsViaDirectCall() public {
        staking.initializeV2();
        staking.initializeV3();
        _installMonadPrecompileMock();
        _configureValidatorSet123456();

        vm.deal(alice, 20 ether);
        vm.prank(alice);
        staking.stakeMonad{value: 10 ether}();
        staking.updateMonadTargets();
        staking.rebalanceMonadDelegations();

        // All five targets carry stake after a rebalance with equal scores.
        for (uint64 i = 1; i <= 5; ++i) {
            assertEq(staking.validatorDelegatedAmount(i), 2 ether);
            monadStakingMock.setDelegatorRewards(i, address(staking), uint256(i) * 1 ether);
        }

        staking.harvestMonadValidatorRewards();

        // Every delegated validator is harvested: 1+2+3+4+5 = 15 ether.
        assertEq(staking.protocolMonadYieldAccrued(), 15 ether);
    }

    function testHarvestClaimsResidualRewardsFromFullyUndelegatedValidators() public {
        staking.initializeV2();
        staking.initializeV3();
        _installMonadPrecompileMock();
        _configureValidatorSet123456();

        vm.deal(alice, 20 ether);
        vm.prank(alice);
        staking.stakeMonad{value: 10 ether}();
        staking.updateMonadTargets();
        staking.rebalanceMonadDelegations();

        // Fully exit every validator: active delegation and pending both drop to zero.
        vm.prank(alice);
        staking.requestUnstakeMonad(10 ether);
        monadStakingMock.setEpoch(6, false);
        staking.processMaturedMonadUndelegations(0);
        assertEq(staking.totalDelegatedMonad(), 0);
        assertEq(staking.totalPendingUndelegateMonad(), 0);

        // Rewards still sit on a validator that now has zero active delegation.
        monadStakingMock.setDelegatorRewards(3, address(staking), 1 ether);

        staking.harvestMonadValidatorRewards();

        // Harvest must still claim the residual reward before compacting the validator out.
        assertEq(staking.protocolMonadYieldAccrued(), 1 ether);
        assertEq(staking.trackedValidatorsLength(), 0);
    }

    function testTransferExcessMonadYieldOnlyTransfersHarvestedYield() public {
        staking.initializeV2();
        _installMonadPrecompileMock();
        _configureValidatorSet123456();
        staking.setMonadRebalanceKeeper(bob, true);

        vm.deal(alice, 20 ether);
        vm.prank(alice);
        staking.stakeMonad{value: 10 ether}();
        staking.updateMonadTargets();
        staking.rebalanceMonadDelegations();

        monadStakingMock.setDelegatorRewards(1, address(staking), 2 ether);

        vm.prank(bob);
        staking.harvestMonadValidatorRewards();

        vm.prank(alice);
        uint256 requestId = staking.requestUnstakeMonad(4 ether);

        monadStakingMock.setEpoch(6, false);
        staking.updateMonadTargets();
        staking.rebalanceMonadDelegations();

        uint256 bobBefore = bob.balance;

        // Protocol yield withdrawal is owner-only; a keeper must be rejected.
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", bob));
        staking.transferExcessMonadYield(payable(bob), 2 ether);

        staking.transferExcessMonadYield(payable(bob), 2 ether);

        assertEq(bob.balance, bobBefore + 2 ether);
        assertEq(staking.protocolMonadYieldAccrued(), 0);

        uint256 aliceBefore = alice.balance;
        vm.prank(alice);
        staking.claimUnstakedMonad(requestId);

        assertEq(alice.balance, aliceBefore + 4 ether);
    }

    function testRequestUnstakeMonadIsAlwaysDelayed() public {
        staking.initializeV2();
        _installMonadPrecompileMock();
        vm.deal(alice, 20 ether);

        vm.prank(alice);
        staking.stakeMonad{value: 5 ether}();

        vm.prank(alice);
        uint256 requestId = staking.requestUnstakeMonad(2 ether);

        monadStakingMock.setEpoch(5, false);
        vm.expectRevert(abi.encodeWithSelector(Series9Staking.UnstakeRequestNotClaimable.selector, uint64(5), uint64(6)));
        vm.prank(alice);
        staking.claimUnstakedMonad(requestId);

        monadStakingMock.setEpoch(6, false);
        uint256 aliceBefore = alice.balance;

        vm.prank(alice);
        staking.claimUnstakedMonad(requestId);
        assertEq(alice.balance, aliceBefore + 2 ether);
    }

    function testEpochReadFailureFailsClosed() public {
        vm.startPrank(alice);
        ser9.approve(address(staking), type(uint256).max);
        staking.stake(100 ether);
        monadStakingMock.setEpochReadFailure(true);

        vm.expectRevert(Series9Staking.MonadEpochReadFailed.selector);
        staking.unstake(100 ether);
        vm.stopPrank();
    }

    function testRebalanceSelectsTopFiveAndAccruesProtocolYield() public {
        staking.initializeV2();
        staking.initializeV3();
        _installMonadPrecompileMock();
        _configureValidatorSet123456();

        vm.deal(alice, 20 ether);
        vm.prank(alice);
        staking.stakeMonad{value: 10 ether}();

        vm.expectRevert(Series9Staking.UnauthorizedRebalanceOperator.selector);
        vm.prank(bob);
        staking.rebalanceMonadDelegations();

        staking.setMonadRebalanceKeeper(bob, true);

        vm.prank(bob);
        staking.updateMonadTargets();
        vm.prank(bob);
        staking.rebalanceMonadDelegations();

        assertEq(staking.targetValidatorCount(), 5);
        assertEq(staking.totalDelegatedMonad(), 10 ether);
        assertEq(staking.targetValidatorIds(0), 1);
        assertEq(staking.cachedMonadDelegatedShareBps(), MONAD_DELEGATED_SHARE_BPS);

        vm.roll(block.number + 10);
        monadStakingMock.bumpValidatorAccRewardPerToken(6, 1_000 ether);
        monadStakingMock.bumpValidatorAccRewardPerToken(1, 100 ether);
        monadStakingMock.setDelegatorRewards(1, address(staking), 1 ether);

        vm.prank(bob);
        staking.updateMonadTargets();
        vm.prank(bob);
        staking.rebalanceMonadDelegations();

        assertEq(staking.protocolMonadYieldAccrued(), 1 ether);
        assertEq(staking.cachedMonadDelegatedShareBps(), MONAD_DELEGATED_SHARE_BPS);
        assertEq(staking.totalDelegatedMonad() + staking.totalPendingUndelegateMonad(), 10 ether);

        bool hasValidatorSix;
        for (uint256 i = 0; i < staking.targetValidatorCount(); ++i) {
            if (staking.targetValidatorIds(i) == 6) {
                hasValidatorSix = true;
                break;
            }
        }
        assertTrue(hasValidatorSix);
    }

    function testDelayedUnstakeClaimRequiresPermissionlessMaturedProcessorWhenLiquidityIsStillPending() public {
        staking.initializeV2();
        _installMonadPrecompileMock();
        _configureValidatorSet123456();

        vm.deal(alice, 20 ether);
        vm.prank(alice);
        staking.stakeMonad{value: 10 ether}();
        staking.rebalanceMonadDelegations();
        _rebalanceMonadDelegationsToObservedApy(2 ether);

        vm.prank(alice);
        uint256 requestId = staking.requestUnstakeMonad(4 ether);

        (,, uint64 minClaimEpoch,) = staking.monadUnstakeRequest(alice, requestId);
        assertEq(minClaimEpoch, 6);

        monadStakingMock.setEpoch(6, false);

        vm.expectRevert(abi.encodeWithSelector(Series9Staking.InsufficientLiquidMonad.selector, 4 ether, 0));
        vm.prank(alice);
        staking.claimUnstakedMonad(requestId);

        staking.processMaturedMonadUndelegations(0);

        uint256 aliceBefore = alice.balance;
        vm.prank(alice);
        staking.claimUnstakedMonad(requestId);

        assertEq(alice.balance, aliceBefore + 4 ether);
    }

    function testPausedMaturedMonadClaimStillSucceeds() public {
        staking.initializeV2();
        _installMonadPrecompileMock();
        vm.deal(alice, 20 ether);

        vm.prank(alice);
        staking.stakeMonad{value: 5 ether}();

        vm.prank(alice);
        uint256 requestId = staking.requestUnstakeMonad(2 ether);

        monadStakingMock.setEpoch(6, false);
        staking.pause();

        uint256 aliceBefore = alice.balance;
        vm.prank(alice);
        staking.claimUnstakedMonad(requestId);

        assertEq(alice.balance, aliceBefore + 2 ether);
    }

    function testMonadWithdrawShortfallRecordsDeficitOnSlash() public {
        staking.initializeV2();
        _installMonadPrecompileMock();
        _configureValidatorsRange(1, 1);

        vm.deal(alice, 20 ether);
        vm.prank(alice);
        staking.stakeMonad{value: 10 ether}();

        assertTrue(staking.exposeDelegateMonadAmountToValidator(1, 10 ether));

        vm.prank(alice);
        staking.requestUnstakeMonad(4 ether);

        // Simulate Monad slashing 25% of the unbonding stake during the withdrawal delay.
        monadStakingMock.setWithdrawSlashBps(2500);
        monadStakingMock.setEpoch(6, false);

        vm.expectEmit(true, true, false, true, address(staking));
        emit Series9Staking.MonadWithdrawShortfall(1, 0, 4 ether, 3 ether, 1 ether);

        uint256 processed = staking.processMaturedMonadUndelegations(0);
        assertEq(processed, 1);

        // 25% of 4 MON = 1 MON shortfall recorded; principal bookkeeping still cleared.
        assertEq(staking.monadSlashingDeficit(), 1 ether);
        assertEq(staking.totalPendingUndelegateMonad(), 0);
    }

    function testMonadWithdrawNoShortfallWhenFullReturn() public {
        staking.initializeV2();
        _installMonadPrecompileMock();
        _configureValidatorsRange(1, 1);

        vm.deal(alice, 20 ether);
        vm.prank(alice);
        staking.stakeMonad{value: 10 ether}();

        assertTrue(staking.exposeDelegateMonadAmountToValidator(1, 10 ether));

        vm.prank(alice);
        staking.requestUnstakeMonad(4 ether);

        monadStakingMock.setEpoch(6, false);
        uint256 processed = staking.processMaturedMonadUndelegations(0);

        assertEq(processed, 1);
        assertEq(staking.monadSlashingDeficit(), 0);
        assertEq(staking.totalPendingUndelegateMonad(), 0);
    }

    function testPausedMaturedMonadClaimStillNeedsExternalMaturedProcessor() public {
        staking.initializeV2();
        _installMonadPrecompileMock();
        _configureValidatorSet123456();

        vm.deal(alice, 20 ether);
        vm.prank(alice);
        staking.stakeMonad{value: 10 ether}();
        staking.rebalanceMonadDelegations();
        _rebalanceMonadDelegationsToObservedApy(2 ether);

        vm.prank(alice);
        uint256 requestId = staking.requestUnstakeMonad(4 ether);

        monadStakingMock.setEpoch(6, false);
        staking.pause();

        vm.expectRevert(abi.encodeWithSelector(Series9Staking.InsufficientLiquidMonad.selector, 4 ether, 0));
        vm.prank(alice);
        staking.claimUnstakedMonad(requestId);

        vm.prank(bob);
        staking.processMaturedMonadUndelegations(0);

        uint256 aliceBefore = alice.balance;
        vm.prank(alice);
        staking.claimUnstakedMonad(requestId);

        assertEq(alice.balance, aliceBefore + 4 ether);
        assertEq(staking.totalPendingUndelegateMonad(), 0);
    }

    function testRequestUnstakeMonadKeepsMinClaimEpochMaxUntilAllCoverageIsQueuedAcrossBatches() public {
        staking.initializeV2();
        _installMonadPrecompileMock();
        _configureValidatorsRange(1, 30);

        vm.deal(alice, 100 ether);
        vm.prank(alice);
        staking.stakeMonad{value: 60 ether}();

        for (uint64 validatorId = 1; validatorId <= 30; ++validatorId) {
            staking.exposeDelegateMonadAmountToValidator(validatorId, 2 ether);
        }

        vm.prank(alice);
        uint256 requestId = staking.requestUnstakeMonad(60 ether);

        (uint256 amount,, uint64 minClaimEpoch, bool claimed) = staking.monadUnstakeRequest(alice, requestId);
        assertEq(amount, 60 ether);
        assertEq(minClaimEpoch, type(uint64).max);
        assertFalse(claimed);
        assertEq(staking.totalPendingUndelegateMonad(), 50 ether);

        uint64 coverageEpoch = staking.processPendingMonadUnstakeCoverage(0);
        assertEq(coverageEpoch, 6);

        (,, minClaimEpoch,) = staking.monadUnstakeRequest(alice, requestId);
        assertEq(minClaimEpoch, 6);
        assertEq(staking.totalPendingUndelegateMonad(), 60 ether);
    }

    function testWithdrawIdExhaustionLeavesRequestPendingInsteadOfReverting() public {
        staking.initializeV2();
        _installMonadPrecompileMock();
        _configureValidatorsRange(1, 1);

        vm.deal(alice, 400 ether);
        vm.prank(alice);
        staking.stakeMonad{value: 300 ether}();

        assertTrue(staking.exposeDelegateMonadAmountToValidator(1, 300 ether));

        for (uint256 i = 0; i < 256; ++i) {
            vm.prank(alice);
            staking.requestUnstakeMonad(1 ether);
        }

        assertEq(staking.totalPendingUndelegateMonad(), 256 ether);

        vm.prank(alice);
        uint256 requestId = staking.requestUnstakeMonad(1 ether);

        (uint256 amount,, uint64 minClaimEpoch, bool claimed) = staking.monadUnstakeRequest(alice, requestId);
        assertEq(amount, 1 ether);
        assertEq(minClaimEpoch, type(uint64).max);
        assertFalse(claimed);
        assertEq(staking.totalPendingUndelegateMonad(), 256 ether);
    }

    function testClaimNeedingMoreThanOneMaturedWithdrawBatchDoesNotProgressOnRevert() public {
        staking.initializeV2();
        _installMonadPrecompileMock();
        _configureValidatorsRange(1, 30);

        vm.deal(alice, 100 ether);
        vm.prank(alice);
        staking.stakeMonad{value: 60 ether}();

        for (uint64 validatorId = 1; validatorId <= 30; ++validatorId) {
            staking.exposeDelegateMonadAmountToValidator(validatorId, 2 ether);
        }

        vm.prank(alice);
        uint256 requestId = staking.requestUnstakeMonad(60 ether);

        staking.processPendingMonadUnstakeCoverage(0);
        monadStakingMock.setEpoch(6, false);

        vm.expectRevert(abi.encodeWithSelector(Series9Staking.InsufficientLiquidMonad.selector, 60 ether, 0));
        vm.prank(alice);
        staking.claimUnstakedMonad(requestId);

        assertEq(staking.totalPendingUndelegateMonad(), 60 ether);

        uint256 processedFirstCall = staking.processMaturedMonadUndelegations(0);
        assertEq(processedFirstCall, 25);
        assertEq(staking.totalPendingUndelegateMonad(), 10 ether);

        vm.expectRevert(abi.encodeWithSelector(Series9Staking.InsufficientLiquidMonad.selector, 60 ether, 50 ether));
        vm.prank(alice);
        staking.claimUnstakedMonad(requestId);

        assertEq(staking.totalPendingUndelegateMonad(), 10 ether);

        uint256 processedSecondCall = staking.processMaturedMonadUndelegations(0);
        assertEq(processedSecondCall, 5);
        assertEq(staking.totalPendingUndelegateMonad(), 0);

        uint256 aliceBefore = alice.balance;
        vm.prank(alice);
        staking.claimUnstakedMonad(requestId);
        assertEq(alice.balance, aliceBefore + 60 ether);
    }

    function testPermissionlessMaturedMonadUndelegationProcessing() public {
        staking.initializeV2();
        _installMonadPrecompileMock();
        _configureValidatorSet123456();

        vm.deal(alice, 20 ether);
        vm.prank(alice);
        staking.stakeMonad{value: 10 ether}();
        staking.rebalanceMonadDelegations();
        _rebalanceMonadDelegationsToObservedApy(2 ether);

        vm.prank(alice);
        uint256 requestId = staking.requestUnstakeMonad(4 ether);

        monadStakingMock.setEpoch(6, false);

        vm.prank(bob);
        uint256 processed = staking.processMaturedMonadUndelegations(0);

        assertGt(processed, 0);
        assertEq(staking.totalPendingUndelegateMonad(), 0);

        uint256 aliceBefore = alice.balance;
        vm.prank(alice);
        staking.claimUnstakedMonad(requestId);
        assertEq(alice.balance, aliceBefore + 4 ether);
    }

    function testMaturedMonadUndelegationProcessingMakesBoundedProgressAcrossCalls() public {
        staking.initializeV2();
        _installMonadPrecompileMock();
        _configureValidatorSet123456();

        vm.deal(alice, 100 ether);
        vm.prank(alice);
        staking.stakeMonad{value: 60 ether}();
        staking.rebalanceMonadDelegations();
        _rebalanceMonadDelegationsToObservedApy(2 ether);

        for (uint256 i = 0; i < 30; ++i) {
            vm.prank(alice);
            staking.requestUnstakeMonad(1 ether);
        }

        assertEq(staking.totalPendingUndelegateMonad(), 30 ether);

        monadStakingMock.setEpoch(6, false);

        uint256 processedFirstCall = staking.processMaturedMonadUndelegations(0);
        assertGt(processedFirstCall, 0);
        assertGt(staking.totalPendingUndelegateMonad(), 0);

        uint256 processedSecondCall = staking.processMaturedMonadUndelegations(0);
        assertGt(processedSecondCall, 0);
        assertEq(staking.totalPendingUndelegateMonad(), 0);
        assertEq(staking.pendingUndelegateTicketsLength(), 0);
    }

    function testRebalanceScansPastFirstHundredValidators() public {
        staking.initializeV2();
        _installMonadPrecompileMock();
        _configureValidatorsRange(1, 120);

        vm.deal(alice, 20 ether);
        vm.prank(alice);
        staking.stakeMonad{value: 10 ether}();

        staking.updateMonadTargets();
        staking.rebalanceMonadDelegations();

        vm.roll(block.number + 10);
        for (uint64 validatorId = 116; validatorId <= 120; ++validatorId) {
            monadStakingMock.bumpValidatorAccRewardPerToken(validatorId, 5_000 ether);
        }

        staking.updateMonadTargets();
        staking.rebalanceMonadDelegations();

        for (uint256 i = 0; i < 5; ++i) {
            assertEq(staking.targetValidatorIds(i), 116 + i);
        }
    }

    function testHarvestCompactsInactiveTrackedValidators() public {
        staking.initializeV2();
        _installMonadPrecompileMock();
        _configureValidatorSet123456();

        vm.deal(alice, 20 ether);
        vm.prank(alice);
        staking.stakeMonad{value: 10 ether}();
        staking.updateMonadTargets();
        staking.rebalanceMonadDelegations();

        assertEq(staking.trackedValidatorsLength(), 5);

        vm.prank(alice);
        staking.requestUnstakeMonad(10 ether);

        monadStakingMock.setEpoch(6, false);
        staking.processMaturedMonadUndelegations(0);
        assertEq(staking.totalPendingUndelegateMonad(), 0);

        staking.harvestMonadValidatorRewards();
        assertEq(staking.trackedValidatorsLength(), 0);
    }

    function testMonadUnstakeClaimNoLongerNeedsKeeperRebalanceAfterQueuedUndelegationMatures() public {
        staking.initializeV2();
        _installMonadPrecompileMock();
        _configureValidatorSet123456();

        vm.deal(alice, 20 ether);
        vm.prank(alice);
        staking.stakeMonad{value: 10 ether}();
        staking.rebalanceMonadDelegations();
        _rebalanceMonadDelegationsToObservedApy(2 ether);

        vm.deal(bob, 10 ether);
        vm.prank(bob);
        staking.stakeMonad{value: 3 ether}();

        vm.prank(bob);
        uint256 requestId = staking.requestUnstakeMonad(2 ether);

        (,, uint64 minClaimEpoch,) = staking.monadUnstakeRequest(bob, requestId);
        assertEq(minClaimEpoch, 6);
        assertEq(staking.totalDelegatedMonad(), 11 ether);

        monadStakingMock.setEpoch(6, false);

        vm.expectRevert(abi.encodeWithSelector(Series9Staking.InsufficientLiquidMonad.selector, 2 ether, 0));
        vm.prank(bob);
        staking.claimUnstakedMonad(requestId);

        staking.processMaturedMonadUndelegations(0);

        uint256 bobBefore = bob.balance;

        vm.prank(bob);
        staking.claimUnstakedMonad(requestId);

        assertEq(bob.balance, bobBefore + 2 ether);
        assertEq(staking.totalDelegatedMonad(), 11 ether);
        assertEq(staking.totalPendingUndelegateMonad(), 0);
    }

    function testMonadUnstakeDoesNotDoubleQueueWhenPendingUndelegationAlreadyCoversShortfall() public {
        staking.initializeV2();
        _installMonadPrecompileMock();
        _configureValidatorSet123456();

        vm.deal(alice, 20 ether);
        vm.prank(alice);
        staking.stakeMonad{value: 10 ether}();
        staking.rebalanceMonadDelegations();
        _rebalanceMonadDelegationsToObservedApy(2 ether);

        vm.prank(alice);
        staking.requestUnstakeMonad(4 ether);

        assertEq(staking.totalPendingUndelegateMonad(), 4 ether);
        assertEq(staking.totalDelegatedMonad(), 6 ether);

        vm.deal(bob, 20 ether);
        vm.prank(bob);
        staking.stakeMonad{value: 4 ether}();

        vm.prank(bob);
        staking.requestUnstakeMonad(2 ether);

        assertEq(staking.totalPendingUndelegateMonad(), 4 ether);
        assertEq(staking.totalDelegatedMonad(), 6 ether);
    }

    function testQueueUnstakeUsesLowestKnownScoresBeforeHigherScoresAndUnknowns() public {
        staking.initializeV2();
        _installMonadPrecompileMock();
        _configureValidatorsRange(1, 4);

        vm.deal(address(staking), 4 ether);
        for (uint64 validatorId = 1; validatorId <= 4; ++validatorId) {
            assertTrue(staking.exposeDelegateMonadAmountToValidator(validatorId, 1 ether));
        }

        staking.exposeUpdateMonadTargets();

        assertFalse(staking.hasCachedValidatorScore(1));
        assertFalse(staking.hasCachedValidatorScore(2));
        assertFalse(staking.hasCachedValidatorScore(3));
        assertFalse(staking.hasCachedValidatorScore(4));

        vm.roll(block.number + 10);

        uint64[] memory scoredValidatorIds = new uint64[](3);
        scoredValidatorIds[0] = 1;
        scoredValidatorIds[1] = 2;
        scoredValidatorIds[2] = 3;
        monadStakingMock.setExecutionValidatorSet(scoredValidatorIds);

        monadStakingMock.setValidator(1, 1 ether, 2_000 ether, 0);
        monadStakingMock.setValidator(2, 1 ether, 1_000 ether, 0.2 ether);
        monadStakingMock.setValidator(3, 1 ether, 3_000 ether, 0.5 ether);

        staking.exposeUpdateMonadTargets();

        assertTrue(staking.hasCachedValidatorScore(1));
        assertTrue(staking.hasCachedValidatorScore(2));
        assertTrue(staking.hasCachedValidatorScore(3));
        assertFalse(staking.hasCachedValidatorScore(4));
        assertGt(staking.cachedValidatorScore(1), 0);
        assertEq(staking.cachedValidatorScore(2), 0);
        assertEq(staking.cachedValidatorScore(1), staking.cachedValidatorScore(3));

        (uint256 queuedAmount, uint64 maxClaimableEpoch) = staking.exposeQueueUnstakeFromDelegations(3 ether, 1, 4);

        assertEq(queuedAmount, 3 ether);
        assertEq(maxClaimableEpoch, 6);
        assertEq(staking.pendingUndelegateTicketsLength(), 3);

        (uint64 validatorId0, uint8 withdrawId0, uint256 amount0, uint64 claimableEpoch0, bool withdrawn0) =
            staking.pendingUndelegateTickets(0);
        (uint64 validatorId1, uint8 withdrawId1, uint256 amount1, uint64 claimableEpoch1, bool withdrawn1) =
            staking.pendingUndelegateTickets(1);
        (uint64 validatorId2, uint8 withdrawId2, uint256 amount2, uint64 claimableEpoch2, bool withdrawn2) =
            staking.pendingUndelegateTickets(2);

        assertEq(validatorId0, 2);
        assertEq(validatorId1, 3);
        assertEq(validatorId2, 1);
        assertEq(withdrawId0, 0);
        assertEq(withdrawId1, 0);
        assertEq(withdrawId2, 0);
        assertEq(amount0, 1 ether);
        assertEq(amount1, 1 ether);
        assertEq(amount2, 1 ether);
        assertEq(claimableEpoch0, 6);
        assertEq(claimableEpoch1, 6);
        assertEq(claimableEpoch2, 6);
        assertFalse(withdrawn0);
        assertFalse(withdrawn1);
        assertFalse(withdrawn2);

        assertEq(staking.validatorDelegatedAmount(1), 0);
        assertEq(staking.validatorDelegatedAmount(2), 0);
        assertEq(staking.validatorDelegatedAmount(3), 0);
        assertEq(staking.validatorDelegatedAmount(4), 1 ether);
        assertEq(staking.monadUndelegateValidatorCursor(), 0);
        assertEq(staking.totalPendingUndelegateMonad(), 3 ether);
    }

    function testQueueUnstakeOnlyReordersInsideCurrentCursorWindow() public {
        staking.initializeV2();
        _installMonadPrecompileMock();
        _configureValidatorsRange(1, 5);

        vm.deal(address(staking), 5 ether);
        for (uint64 candidateValidatorId = 1; candidateValidatorId <= 5; ++candidateValidatorId) {
            assertTrue(staking.exposeDelegateMonadAmountToValidator(candidateValidatorId, 1 ether));
        }

        staking.exposeUpdateMonadTargets();
        vm.roll(block.number + 10);

        monadStakingMock.setValidator(1, 1 ether, 1_000 ether, 0);
        monadStakingMock.setValidator(2, 1 ether, 1_200 ether, 0);
        monadStakingMock.setValidator(3, 1 ether, 1_300 ether, 0);
        monadStakingMock.setValidator(4, 1 ether, 1_400 ether, 0);
        monadStakingMock.setValidator(5, 1 ether, 1_500 ether, 0);

        staking.exposeUpdateMonadTargets();

        stdstore.target(address(staking)).sig("monadUndelegateValidatorCursor()").checked_write(uint256(2));

        (uint256 queuedAmount, uint64 maxClaimableEpoch) = staking.exposeQueueUnstakeFromDelegations(1 ether, 1, 2);

        assertEq(queuedAmount, 1 ether);
        assertEq(maxClaimableEpoch, 6);
        assertEq(staking.pendingUndelegateTicketsLength(), 1);
        assertEq(staking.monadUndelegateValidatorCursor(), 4);

        (uint64 validatorId, uint8 withdrawId, uint256 amount, uint64 claimableEpoch, bool withdrawn) =
            staking.pendingUndelegateTickets(0);
        assertEq(validatorId, 3);
        assertEq(withdrawId, 0);
        assertEq(amount, 1 ether);
        assertEq(claimableEpoch, 6);
        assertFalse(withdrawn);

        for (uint256 i = 0; i < 5; ++i) {
            assertEq(staking.trackedValidators(i), i + 1);
        }

        assertEq(staking.validatorDelegatedAmount(1), 1 ether);
        assertEq(staking.validatorDelegatedAmount(2), 1 ether);
        assertEq(staking.validatorDelegatedAmount(3), 0);
        assertEq(staking.validatorDelegatedAmount(4), 1 ether);
        assertEq(staking.validatorDelegatedAmount(5), 1 ether);
    }

    function _installMonadPrecompileMock() internal {
        MonadStakingMock mockImplementation = new MonadStakingMock();
        address precompileAddress = address(uint160(0x1000));
        vm.etch(precompileAddress, address(mockImplementation).code);

        monadStakingMock = MonadStakingMock(precompileAddress);
        monadStakingMock.setEpoch(1, false);
        vm.deal(precompileAddress, 1_000_000 ether);
    }

    function _configureValidatorSet123456() internal {
        uint64[] memory validatorIds = new uint64[](6);
        validatorIds[0] = 1;
        validatorIds[1] = 2;
        validatorIds[2] = 3;
        validatorIds[3] = 4;
        validatorIds[4] = 5;
        validatorIds[5] = 6;

        monadStakingMock.setExecutionValidatorSet(validatorIds);
        for (uint64 i = 1; i <= 6; ++i) {
            monadStakingMock.setValidator(i, 0, 1_000 ether, 0);
        }
    }

    function _configureValidatorsRange(uint64 startValidatorId, uint64 endValidatorId) internal {
        uint256 validatorCount = uint256(endValidatorId - startValidatorId + 1);
        uint64[] memory validatorIds = new uint64[](validatorCount);

        for (uint64 validatorId = startValidatorId; validatorId <= endValidatorId; ++validatorId) {
            validatorIds[validatorId - startValidatorId] = validatorId;
            monadStakingMock.setValidator(validatorId, 0, 1_000 ether, 0);
        }

        monadStakingMock.setExecutionValidatorSet(validatorIds);
    }

    function _rebalanceMonadDelegationsToObservedApy(uint256 observedApy) internal {
        uint256 deltaBlocks = 10;
        vm.roll(block.number + deltaBlocks);

        uint256 deltaAcc = observedApy == 0
            ? 0
            : (observedApy * deltaBlocks + MONAD_BLOCKS_PER_YEAR - 1) / MONAD_BLOCKS_PER_YEAR;

        for (uint64 validatorId = 1; validatorId <= 5; ++validatorId) {
            monadStakingMock.bumpValidatorAccRewardPerToken(validatorId, deltaAcc);
        }

        staking.updateMonadTargets();
        staking.rebalanceMonadDelegations();
    }

    function _stake(address user, uint256 stakeAmount) internal {
        vm.startPrank(user);
        ser9.approve(address(staking), type(uint256).max);
        staking.stake(stakeAmount);
        vm.stopPrank();
    }
}
