// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";
import {StdStorage, stdStorage} from "forge-std/StdStorage.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC1822Proxiable} from "openzeppelin-contracts/contracts/interfaces/draft-IERC1822.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeCast} from "openzeppelin-contracts/contracts/utils/math/SafeCast.sol";

import {SER9Token} from "../src/SER9Token.sol";
import {Series9ManagedToken} from "../src/Series9ManagedToken.sol";
import {Series9Staking} from "../src/Series9Staking.sol";
import {IPermit2} from "../src/interfaces/IPermit2.sol";
import {IMonadStaking} from "../src/interfaces/IMonadStaking.sol";

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

contract Series9ManagedTokenV3 is Series9ManagedToken {
    function version() external pure returns (uint256) {
        return 3;
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

        (bool ok,) = msg.sender.call{value: amount}("");
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
        Series9ManagedToken managedTokenImplementation = new Series9ManagedToken();
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
                        (address(ser9), REWARD_PER_BLOCK, address(this), address(managedTokenImplementation), CREATION_FEE)
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

    function testCreateManagedTokenWithPermit2() public {
        vm.startPrank(alice);
        ser9.approve(address(permit2), type(uint256).max);

        IPermit2.PermitSingle memory permitSingle = IPermit2.PermitSingle({
            details: IPermit2.PermitDetails({
                token: address(ser9),
                // forge-lint: disable-next-line(unsafe-typecast)
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
                // forge-lint: disable-next-line(unsafe-typecast)
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
            payable(
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

        uint256 available = staking.availableMintCollateral(alice);
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
        assertEq(staking.availableMintCollateral(alice), 0);
        assertEq(staking.maxMintable(alice, token), 0);
    }

    function testAvailableUnusedLockedReflectsLegacyResidualLocksOnly() public {
        _stake(alice, 100 ether);

        stdstore.target(address(staking)).sig("lockedBalance(address)").with_key(alice).checked_write(60 ether);
        stdstore.target(address(staking)).sig("usedLockedSer9(address)").with_key(alice).checked_write(40 ether);

        assertEq(staking.availableUnusedLocked(alice), 20 ether);
        assertEq(staking.availableMintCollateral(alice), 60 ether);
    }

    function testBurnAndUnlockAutoUnlocksLegacyUnusedLockedBalance() public {
        _stake(alice, 100 ether);
        address token = _createToken(alice, "AUTOBURN", "ABR", 2 ether, false, 0);

        vm.startPrank(alice);
        staking.mintManagedToken(token, 30 ether);
        vm.stopPrank();

        stdstore.target(address(staking)).sig("lockedBalance(address)").with_key(alice).checked_write(80 ether);

        vm.prank(alice);
        staking.burnAndUnlock(token, 10 ether);

        assertEq(staking.userTokenDebt(alice, token), 20 ether);
        assertEq(staking.usedLockedSer9(alice), 40 ether);
        assertEq(staking.lockedBalance(alice), 40 ether);
        assertEq(staking.availableUnusedLocked(alice), 0);
    }

    function testUnstakeAutoUnlocksLegacyUnusedLockedBalance() public {
        _stake(alice, 100 ether);
        address token = _createToken(alice, "AUTOUNSTAKE", "AUS", 2 ether, false, 0);

        vm.startPrank(alice);
        staking.mintManagedToken(token, 20 ether);
        stdstore.target(address(staking)).sig("lockedBalance(address)").with_key(alice).checked_write(60 ether);
        staking.unstake(60 ether);
        vm.stopPrank();

        assertEq(staking.lockedBalance(alice), 40 ether);
        assertEq(staking.usedLockedSer9(alice), 40 ether);
        assertEq(staking.stakedBalance(alice), 40 ether);
        assertEq(staking.availableUnusedLocked(alice), 0);
    }

    function testMintManagedTokenAutoUnlocksLegacyUnusedLockedBalance() public {
        _stake(alice, 100 ether);
        address token = _createToken(alice, "AUTOMINT", "AMT", 2 ether, false, 0);

        vm.startPrank(alice);
        staking.mintManagedToken(token, 20 ether);
        vm.stopPrank();

        stdstore.target(address(staking)).sig("lockedBalance(address)").with_key(alice).checked_write(60 ether);

        vm.prank(alice);
        staking.mintManagedToken(token, 10 ether);

        assertEq(staking.userTokenDebt(alice, token), 30 ether);
        assertEq(staking.usedLockedSer9(alice), 60 ether);
        assertEq(staking.lockedBalance(alice), 60 ether);
        assertEq(staking.availableUnusedLocked(alice), 0);
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
        assertTrue(Series9ManagedToken(token).transfer(bob, 1_200 ether));
        vm.stopPrank();

        vm.startPrank(alice);
        Series9ManagedToken(token).approve(address(staking), type(uint256).max);
        staking.stakeFeeToken(token, 500 ether);
        vm.stopPrank();

        vm.startPrank(bob);
        Series9ManagedToken(token).approve(address(staking), type(uint256).max);
        staking.stakeFeeToken(token, 500 ether);
        assertTrue(Series9ManagedToken(token).transfer(charlie, 200 ether));
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
        assertTrue(Series9ManagedToken(token).transfer(bob, 1_000 ether));
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

    function testOwnerCanUpgradeManagedTokenIndividually() public {
        address tokenA = _createToken(alice, "A", "A", 1 ether, false, 0);
        address tokenB = _createToken(alice, "B", "B", 2 ether, true, 300);

        Series9ManagedTokenV2 managedV2 = new Series9ManagedTokenV2();
        staking.setManagedTokenImplementation(address(managedV2));
        staking.upgradeManagedToken(tokenA, bytes(""));

        assertEq(Series9ManagedTokenV2(tokenA).version(), 2);
        (bool tokenBHasVersion,) = address(tokenB).staticcall(abi.encodeWithSelector(Series9ManagedTokenV2.version.selector));
        assertFalse(tokenBHasVersion);
        assertEq(staking.managedTokenImplementation(), address(managedV2));
    }

    function testOnlyOwnerCanUpgradeManagedToken() public {
        address token = _createToken(alice, "A", "A", 1 ether, false, 0);
        Series9ManagedTokenV2 managedV2 = new Series9ManagedTokenV2();
        staking.setManagedTokenImplementation(address(managedV2));

        vm.expectRevert();
        vm.prank(alice);
        staking.upgradeManagedToken(token, bytes(""));
    }

    function testSetManagedTokenImplementationRevertsOnZeroAddressImplementation() public {
        vm.expectRevert(abi.encodeWithSelector(Series9Staking.InvalidImplementation.selector, address(0)));
        staking.setManagedTokenImplementation(address(0));
    }

    function testSetManagedTokenImplementationRevertsOnEOAImplementation() public {
        vm.expectRevert(abi.encodeWithSelector(Series9Staking.InvalidImplementation.selector, alice));
        staking.setManagedTokenImplementation(alice);
    }

    function testSetManagedTokenImplementationRevertsOnNonUUPSImplementation() public {
        NonUUPSImplementation badManagedImpl = new NonUUPSImplementation();

        vm.expectRevert(
            abi.encodeWithSelector(
                Series9Staking.ImplementationNotUUPSCompatible.selector, address(badManagedImpl)
            )
        );
        staking.setManagedTokenImplementation(address(badManagedImpl));
    }

    function testSetManagedTokenImplementationRevertsOnWrongUUIDImplementation() public {
        WrongUUIDImplementation badManagedImpl = new WrongUUIDImplementation();

        vm.expectRevert(
            abi.encodeWithSelector(
                Series9Staking.UnsupportedProxiableUUID.selector, address(badManagedImpl), bytes32(uint256(123))
            )
        );
        staking.setManagedTokenImplementation(address(badManagedImpl));
    }

    function testManagedTokenCanRequestItsOwnUpgradeFromStaking() public {
        address token = _createToken(alice, "PRE", "PRE", 1 ether, false, 0);
        Series9ManagedTokenV2 managedV2 = new Series9ManagedTokenV2();
        Series9ManagedTokenV3 managedV3 = new Series9ManagedTokenV3();

        staking.setManagedTokenImplementation(address(managedV2));
        staking.upgradeManagedToken(token, bytes(""));
        assertEq(Series9ManagedTokenV2(token).version(), 2);

        staking.setManagedTokenImplementation(address(managedV3));
        Series9ManagedToken(token).requestUpgrade();
        assertEq(Series9ManagedTokenV3(token).version(), 3);
    }

    function testManagedTokenAutoRequestsUpgradeOnTransfer() public {
        _stake(alice, 200 ether);
        address token = _createToken(alice, "AUTO", "AUT", 1 ether, false, 0);

        vm.prank(alice);
        staking.mintManagedToken(token, 20 ether);

        Series9ManagedTokenV2 managedV2 = new Series9ManagedTokenV2();
        staking.setManagedTokenImplementation(address(managedV2));

        vm.prank(alice);
        assertTrue(Series9ManagedToken(token).transfer(bob, 5 ether));

        assertEq(Series9ManagedTokenV2(token).version(), 2);
        assertEq(Series9ManagedToken(token).balanceOf(bob), 5 ether);
    }

    function testManagedTokenUpgradePreservesStateAndCreatorPrivileges() public {
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

        Series9ManagedTokenV2 managedV2 = new Series9ManagedTokenV2();
        staking.setManagedTokenImplementation(address(managedV2));
        staking.upgradeManagedToken(token, bytes(""));

        assertEq(staking.stakedBalance(alice), stakedBefore);
        assertEq(staking.lockedBalance(alice), lockedBefore);
        assertEq(staking.usedLockedSer9(alice), usedBefore);
        assertEq(staking.userTokenDebt(alice, token), debtBefore);
        assertEq(Series9ManagedToken(token).feeBps(), feeBpsBefore);

        vm.prank(alice);
        staking.setTokenFeeBps(token, 400);
        assertEq(Series9ManagedToken(token).feeBps(), 400);
    }

    function testManagedTokensUpgradeIndividuallyWithoutBatchSemantics() public {
        address[] memory tokens = new address[](8);
        for (uint256 i = 0; i < tokens.length; ++i) {
            string memory suffix = vm.toString(i);
            tokens[i] = _createToken(
                alice, string.concat("TOKEN", suffix), string.concat("TK", suffix), 1 ether + i, false, 0
            );
        }

        Series9ManagedTokenV2 managedV2 = new Series9ManagedTokenV2();
        staking.setManagedTokenImplementation(address(managedV2));

        staking.upgradeManagedToken(tokens[0], bytes(""));
        staking.upgradeManagedToken(tokens[3], bytes(""));
        staking.upgradeManagedToken(tokens[7], bytes(""));

        assertEq(Series9ManagedTokenV2(tokens[0]).version(), 2);
        assertEq(Series9ManagedTokenV2(tokens[3]).version(), 2);
        assertEq(Series9ManagedTokenV2(tokens[7]).version(), 2);

        (bool tokenOneHasVersion,) =
            address(tokens[1]).staticcall(abi.encodeWithSelector(Series9ManagedTokenV2.version.selector));
        (bool tokenTwoHasVersion,) =
            address(tokens[2]).staticcall(abi.encodeWithSelector(Series9ManagedTokenV2.version.selector));
        assertFalse(tokenOneHasVersion);
        assertFalse(tokenTwoHasVersion);
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

    function testSer9UnstakeRequestRespectsUnlockedBalance() public {
        _stake(alice, 100 ether);
        address token = _createToken(alice, "LOCK", "LCK", 2 ether, false, 0);

        vm.startPrank(alice);
        staking.mintManagedToken(token, 20 ether);
        vm.expectRevert(Series9Staking.InsufficientUnlockedBalance.selector);
        staking.unstake(61 ether);

        vm.stopPrank();
    }

    // --- fee recipient tests ---

    function testOwnerCanSetTokenFeeRecipient() public {
        address token = _createToken(alice, "FEERCPT", "FRC", 1 ether, true, 300);
        address newRecipient = makeAddr("newRecipient");

        staking.setTokenFeeRecipient(token, newRecipient);
        assertEq(Series9ManagedToken(token).feeRecipient(), newRecipient);
        assertTrue(Series9ManagedToken(token).isFeeExempt(newRecipient));
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
        staking.rebalanceMonadDelegations();

        monadStakingMock.setDelegatorRewards(1, address(staking), 1 ether);
        monadStakingMock.setDelegatorRewards(5, address(staking), 2 ether);

        staking.setMonadRebalanceKeeper(bob, true);
        vm.prank(bob);
        staking.harvestMonadValidatorRewards();

        assertEq(staking.protocolMonadYieldAccrued(), 3 ether);
        assertEq(address(staking).balance, 3 ether);
    }

    function testHarvestClaimsAllFiveDelegatedValidatorsViaDirectCall() public {
        staking.initializeV2();
        staking.initializeV3();
        _installMonadPrecompileMock();
        _configureValidatorSet123456();

        vm.deal(alice, 20 ether);
        vm.prank(alice);
        staking.stakeMonad{value: 10 ether}();
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
        staking.rebalanceMonadDelegations();

        monadStakingMock.setDelegatorRewards(1, address(staking), 2 ether);

        vm.prank(bob);
        staking.harvestMonadValidatorRewards();

        vm.prank(alice);
        uint256 requestId = staking.requestUnstakeMonad(4 ether);

        monadStakingMock.setEpoch(6, false);
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

        staking.rebalanceMonadDelegations();

        vm.roll(block.number + 10);
        for (uint64 validatorId = 116; validatorId <= 120; ++validatorId) {
            monadStakingMock.bumpValidatorAccRewardPerToken(validatorId, 5_000 ether);
        }

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

        staking.rebalanceMonadDelegations();
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
