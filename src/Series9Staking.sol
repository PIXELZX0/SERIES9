// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Initializable} from "openzeppelin-contracts/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "openzeppelin-contracts/contracts/proxy/utils/UUPSUpgradeable.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC1822Proxiable} from "openzeppelin-contracts/contracts/interfaces/draft-IERC1822.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
import {SafeCast} from "openzeppelin-contracts/contracts/utils/math/SafeCast.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {OwnableUpgradeable} from "openzeppelin-contracts-upgradeable/contracts/access/OwnableUpgradeable.sol";
import {PausableUpgradeable} from "openzeppelin-contracts-upgradeable/contracts/utils/PausableUpgradeable.sol";

import {SER9Token} from "./SER9Token.sol";
import {Series9ManagedToken} from "./Series9ManagedToken.sol";
import {IPermit2} from "./interfaces/IPermit2.sol";
import {IMonadStaking} from "./interfaces/IMonadStaking.sol";

contract Series9Staking is Initializable, OwnableUpgradeable, PausableUpgradeable, ReentrancyGuard, UUPSUpgradeable {
    using SafeERC20 for IERC20;

    uint256 private constant PRECISION = 1e18;
    uint256 private constant BPS_DENOMINATOR = 10_000;
    uint256 private constant MONAD_SCORE_PRECISION = 1e18;
    uint256 private constant MONAD_BLOCKS_PER_YEAR = 31_536_000;
    uint256 private constant MONAD_DELEGATED_SHARE_FLOOR_BPS = BPS_DENOMINATOR;
    uint256 private constant MONAD_TARGET_COUNT = 5;
    uint256 private constant MONAD_VALIDATOR_BATCH_LIMIT = 25;
    uint256 private constant MONAD_TICKET_BATCH_LIMIT = 25;
    uint256 private constant MONAD_COMPACTION_BATCH_LIMIT = 50;
    uint64 private constant UNSTAKE_DELAY_EPOCHS = 5;
    uint64 private constant MONAD_MAX_UNSTAKE_DELAY_EPOCHS = 30;
    uint64 private constant MONAD_PRECOMPILE_ADDRESS = 0x1000;
    bytes32 private constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    struct TokenConfig {
        bool exists;
        address creator;
        uint256 mintRate;
        bool feeEnabled;
    }

    struct FeePool {
        uint256 totalStaked;
        uint256 accFeePerShare;
        uint256 rewardBalance;
        uint256 undistributedRewards;
    }

    struct TokenMintPolicy {
        uint256 maxSupply;
        uint256 maxMultiplierBps;
        uint16 rampStartBps;
    }

    struct ValidatorSample {
        uint256 accRewardPerToken;
        uint256 sampledBlock;
        uint256 commission;
    }

    struct PendingUndelegateTicket {
        uint64 validatorId;
        uint8 withdrawId;
        uint256 amount;
        uint64 claimableEpoch;
        bool withdrawn;
    }

    struct MonadUnstakeRequest {
        uint256 amount;
        uint64 requestEpoch;
        uint64 minClaimEpoch;
        bool claimed;
        uint256 uncoveredAmount;
    }

    struct MonadUnstakeRequestRef {
        address user;
        uint256 requestId;
    }

    struct Ser9UnstakeRequest {
        uint256 amount;
        uint64 requestEpoch;
        uint64 minClaimEpoch;
        bool claimed;
    }

    struct CandidateScore {
        uint64 validatorId;
        uint256 score;
        uint256 commission;
    }

    struct UnstakeCandidate {
        uint64 validatorId;
        uint256 score;
        uint256 commission;
        bool hasKnownScore;
    }

    SER9Token public ser9;
    IPermit2 public permit2;
    address public managedTokenImplementation;
    uint256 public tokenCreationFee;

    uint256 public rewardRatePerBlock;
    uint256 public rewardPerTokenStored;
    uint256 public lastUpdateBlock;

    uint256 public totalStaked;
    uint256 public totalRewardWeight;

    mapping(address => uint256) public stakedBalance;
    mapping(address => uint256) public lockedBalance;
    mapping(address => uint256) public rewardWeightBalance;

    mapping(address => uint256) public userRewardPerTokenPaid;
    mapping(address => uint256) public rewards;

    mapping(address => TokenConfig) public tokenConfigs;
    mapping(address => TokenMintPolicy) private _tokenMintPolicies;
    address[] public managedTokens;

    mapping(address => mapping(address => uint256)) public userTokenDebt;
    mapping(address => mapping(address => uint256)) public userTokenCollateralUsed;
    mapping(address => uint256) public usedLockedSer9;

    mapping(address => FeePool) public feePools;
    mapping(address => mapping(address => uint256)) public feeStakeBalance;
    mapping(address => mapping(address => uint256)) public feeRewardDebt;
    mapping(address => mapping(address => uint256)) public feePendingRewards;

    uint256 public monadRewardRatePerBlock;
    uint256 public monadRewardPerTokenStored;
    uint256 public monadLastUpdateBlock;

    uint256 public totalMonadStaked;
    uint256 public totalDelegatedMonad;
    uint256 public totalPendingUndelegateMonad;
    uint256 public pendingMonadUnstakePrincipal;
    uint256 public protocolMonadYieldAccrued;

    mapping(address => uint256) public monadStakedBalance;
    mapping(address => uint256) public userMonadRewardPerTokenPaid;
    mapping(address => uint256) public monadRewards;
    mapping(address => bool) public monadRebalanceKeepers;

    uint64[5] public targetValidatorIds;
    uint16[5] public targetValidatorWeightsBps;
    uint8 public targetValidatorCount;

    mapping(uint64 => ValidatorSample) public validatorSamples;
    mapping(uint64 => uint256) public cachedValidatorScore;
    mapping(uint64 => bool) public hasCachedValidatorScore;
    mapping(uint64 => uint256) public validatorDelegatedAmount;
    mapping(uint64 => uint256) public validatorPendingUndelegateAmount;
    mapping(uint64 => uint8) public nextWithdrawIdByValidator;
    mapping(uint64 => mapping(uint8 => bool)) private _withdrawIdInUse;
    uint64[] public trackedValidators;
    mapping(uint64 => bool) public isTrackedValidator;

    PendingUndelegateTicket[] public pendingUndelegateTickets;
    uint256 public monadHarvestValidatorCursor;
    uint256 public monadUndelegateValidatorCursor;
    uint256 public monadFallbackValidatorCursor;
    uint256 public monadRebalanceValidatorCursor;
    uint256 public monadPendingUndelegateCursor;
    uint256 public monadCoverageRequestCursor;
    uint256 public totalPendingMonadUnstakeUncovered;
    mapping(address => uint256) public monadUnstakeRequestCount;
    mapping(address => mapping(uint256 => MonadUnstakeRequest)) private _monadUnstakeRequests;
    MonadUnstakeRequestRef[] private _pendingMonadUnstakeRequests;
    mapping(address => uint256) public ser9UnstakeRequestCount;
    mapping(address => mapping(uint256 => Ser9UnstakeRequest)) private _ser9UnstakeRequests;

    error ZeroAmount();
    error InvalidTokenAddress();
    error MintRateZero();
    error InvalidFeeConfiguration();
    error InvalidManagedToken();
    error FeeDisabled();
    error UnauthorizedTokenCreator();
    error InsufficientStakedBalance();
    error InsufficientUnlockedBalance();
    error InsufficientLockedBalance();
    error InsufficientUnusedLockedBalance();
    error ExceedsMintLimit();
    error ManualLockDisabled();
    error InsufficientTokenDebt();
    error NoRewards();
    error NoFeeRewards();
    error CannotDisableStakingExemption();
    error InvalidImplementation(address implementation);
    error ImplementationNotUUPSCompatible(address implementation);
    error UnsupportedProxiableUUID(address implementation, bytes32 uuid);
    error UnauthorizedTokenOwner(address token, address ownerAddress);
    error InsufficientCreationFee();
    error InvalidPermit2Address();
    error Permit2NotConfigured();
    error InvalidPermit2Token(address expectedToken, address permitToken);
    error InvalidPermit2Spender(address expectedSpender, address permitSpender);
    error Permit2AmountTooLow(uint256 requiredAmount, uint256 permitAmount);
    error InvalidMaxMultiplierBps(uint256 maxMultiplierBps);
    error InvalidRampStartBps(uint16 rampStartBps);
    error ExceedsMaxSupply(uint256 requestedSupply, uint256 maxSupply);
    error UnauthorizedRebalanceOperator();
    error InsufficientMonadStakedBalance();
    error InvalidUnstakeRequest();
    error UnstakeRequestAlreadyClaimed();
    error UnstakeRequestNotClaimable(uint64 currentEpoch, uint64 minClaimEpoch);
    error InsufficientLiquidMonad(uint256 requiredAmount, uint256 availableAmount);
    error MonadPayoutFailed();
    error NotInitialized();
    error MonadEpochReadFailed();
    error InvalidUnstakeDelayEpochs();
    error InvalidFeeRecipientTarget();
    error InsufficientCreationFees(uint256 requested, uint256 available);
    error InvalidSweepRecipient();
    error InvalidUndelegateTicket();

    event Staked(address indexed user, uint256 amount);
    event Unstaked(address indexed user, uint256 amount);
    event RewardClaimed(address indexed user, uint256 rewardAmount);
    event RewardRateUpdated(uint256 newRewardRatePerBlock);
    event Locked(address indexed user, uint256 amount, uint256 totalLocked);

    event ManagedTokenCreated(
        address indexed token,
        address indexed creator,
        uint256 mintRate,
        bool feeEnabled,
        uint16 feeBps,
        string name,
        string symbol
    );
    event ManagedTokenMinted(
        address indexed user, address indexed token, uint256 amount, uint256 collateralCost, uint256 usedLockedAfter
    );
    event ManagedTokenBurnedAndUnlocked(
        address indexed user,
        address indexed token,
        uint256 burnAmount,
        uint256 unlockedAmount,
        uint256 usedLockedAfter,
        uint256 lockedAfter
    );
    event UnusedLockedUnlocked(address indexed user, uint256 amount, uint256 lockedAfter);
    event Ser9Upgraded(address indexed ser9Proxy, address indexed newImplementation);
    event ManagedTokenImplementationUpdated(address previousImpl, address newImpl);
    event ManagedTokenUpgraded(address indexed token, address indexed newImplementation);

    event TokenFeeBpsUpdated(address indexed token, uint16 feeBps);
    event TokenFeeExemptUpdated(address indexed token, address indexed account, bool isExempt);
    event TokenMintPolicyConfigured(
        address indexed token, uint256 maxSupply, uint256 maxMultiplierBps, uint16 rampStartBps
    );

    event TokenCreationFeeUpdated(uint256 previousFee, uint256 newFee);
    event Permit2Updated(address indexed previousPermit2, address indexed newPermit2);

    event FeeTokenStaked(address indexed user, address indexed token, uint256 amount, uint256 userStakeAfter);
    event FeeTokenUnstaked(address indexed user, address indexed token, uint256 amount, uint256 userStakeAfter);
    event FeeRewardsClaimed(address indexed user, address indexed token, uint256 rewardAmount);
    event MonadRewardRateUpdated(uint256 previousRate, uint256 newRate);
    event MonadRebalanceKeeperUpdated(address indexed keeper, bool allowed);
    event MonadUnstakeDelayEpochsUpdated(uint64 previousEpochs, uint64 newEpochs);
    event MonadStaked(address indexed user, uint256 amount);
    event Ser9UnstakeRequested(
        address indexed user, uint256 indexed requestId, uint256 amount, uint64 requestEpoch, uint64 minClaimEpoch
    );
    event Ser9UnstakeClaimed(address indexed user, uint256 indexed requestId, uint256 amount);
    event MonadUnstakeRequested(
        address indexed user, uint256 indexed requestId, uint256 amount, uint64 requestEpoch, uint64 minClaimEpoch
    );
    event MonadUnstakeClaimed(address indexed user, uint256 indexed requestId, uint256 amount);
    event MonadUndelegateQueued(uint64 indexed validatorId, uint8 indexed withdrawId, uint256 amount, uint64 claimableEpoch);
    event MonadWithdrawProcessed(uint64 indexed validatorId, uint8 indexed withdrawId, uint256 amount);
    event MonadYieldAccrued(uint64 indexed validatorId, uint256 amount);
    event MonadYieldTransferred(address indexed recipient, uint256 amount);
    event MonadTargetsUpdated(uint64[5] validatorIds, uint16[5] weightsBps, uint8 targetCount);
    event MonadRebalanced(uint256 totalMonadStaked, uint256 totalDelegatedMonad, uint256 totalPendingUndelegateMonad);
    event MonadDelegateFailed(uint64 indexed validatorId, uint256 amount, bytes reason);
    event MonadClaimRewardsFailed(uint64 indexed validatorId, bytes reason);
    event CreationFeesSwept(address indexed to, uint256 amount);
    event MonadUndelegateTicketForceReleased(uint64 indexed validatorId, uint8 indexed withdrawId, uint256 amount);
    /// @dev Emitted when a matured `withdraw` returns less MON than the booked undelegation
    /// principal — the on-chain signal that Monad has begun slashing delegated/unbonding stake.
    /// Currently never fires: Monad has no automated in-protocol slashing (confirmed 2026-05,
    /// docs.monad.xyz/developer-essentials/staking/staking-behavior). See `monadSlashingDeficit`.
    event MonadWithdrawShortfall(
        uint64 indexed validatorId, uint8 indexed withdrawId, uint256 expected, uint256 received, uint256 shortfall
    );

    modifier updateReward(address account) {
        _updateReward(account);
        _;
    }

    function _updateReward(address account) internal {
        rewardPerTokenStored = rewardPerToken();
        lastUpdateBlock = block.number;
        monadRewardPerTokenStored = monadRewardPerToken();
        monadLastUpdateBlock = block.number;

        if (account != address(0)) {
            rewards[account] = _earnedSer9(account);
            userRewardPerTokenPaid[account] = rewardPerTokenStored;
            monadRewards[account] = _earnedMonad(account);
            userMonadRewardPerTokenPaid[account] = monadRewardPerTokenStored;
        }

    }

    modifier onlyMonadRebalanceOperator() {
        _onlyMonadRebalanceOperator();
        _;
    }

    function _onlyMonadRebalanceOperator() internal view {
        if (msg.sender != owner() && !monadRebalanceKeepers[msg.sender]) {
            revert UnauthorizedRebalanceOperator();
        }
    }

    modifier whenInitialized() {
        _whenInitialized();
        _;
    }

    function _whenInitialized() internal view {
        if (address(ser9) == address(0) || lastUpdateBlock == 0) {
            revert NotInitialized();
        }
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    receive() external payable {}

    function initialize(
        address ser9Token,
        uint256 rewardPerBlock,
        address initialOwner,
        address managedTokenImplementation_,
        uint256 initialCreationFee
    ) external initializer {
        if (ser9Token == address(0) || ser9Token.code.length == 0) {
            revert InvalidTokenAddress();
        }

        _validateImplementation(managedTokenImplementation_);

        __Ownable_init(initialOwner);
        __Pausable_init();

        ser9 = SER9Token(ser9Token);
        rewardRatePerBlock = rewardPerBlock;
        monadRewardRatePerBlock = rewardPerBlock / 8;
        tokenCreationFee = initialCreationFee;
        lastUpdateBlock = block.number;
        monadLastUpdateBlock = block.number;
        managedTokenImplementation = managedTokenImplementation_;
        cachedMonadDelegatedShareBps = MONAD_DELEGATED_SHARE_FLOOR_BPS;
    }

    function initializeV2() external reinitializer(2) {
        if (monadLastUpdateBlock == 0) {
            monadLastUpdateBlock = block.number;
        }

        if (monadRewardRatePerBlock == 0) {
            monadRewardRatePerBlock = rewardRatePerBlock / 8;
        }
    }

    function initializeV3() external reinitializer(3) {
        // No-op retained to preserve the reinitializer version sequence on the live proxy.
    }

    function setRewardRatePerBlock(uint256 newRewardRatePerBlock) external onlyOwner updateReward(address(0)) {
        rewardRatePerBlock = newRewardRatePerBlock;
        emit RewardRateUpdated(newRewardRatePerBlock);
    }

    function setMonadRewardRatePerBlock(uint256 newRate) external onlyOwner updateReward(address(0)) {
        uint256 previousRate = monadRewardRatePerBlock;
        monadRewardRatePerBlock = newRate;
        emit MonadRewardRateUpdated(previousRate, newRate);
    }

    function setMonadRebalanceKeeper(address keeper, bool allowed) external onlyOwner {
        monadRebalanceKeepers[keeper] = allowed;
        emit MonadRebalanceKeeperUpdated(keeper, allowed);
    }

    /// @notice Owner escape hatch to release a Monad undelegate ticket whose `withdraw` is
    ///         permanently failing (e.g. already settled by the precompile via another path),
    ///         freeing its per-validator withdrawId slot so the ticket can be compacted out.
    /// @dev WARNING: only call when the underlying MON is confirmed unrecoverable or already
    ///      returned; releasing a ticket whose withdraw is still pending strands that MON at the
    ///      precompile. User claims remain balance-gated, so this can never cause overpayment.
    function forceReleaseUndelegateTicket(uint256 ticketIndex) external onlyOwner {
        if (ticketIndex >= pendingUndelegateTickets.length) {
            revert InvalidUndelegateTicket();
        }

        PendingUndelegateTicket storage ticket = pendingUndelegateTickets[ticketIndex];
        if (ticket.withdrawn) {
            revert InvalidUndelegateTicket();
        }

        ticket.withdrawn = true;
        validatorPendingUndelegateAmount[ticket.validatorId] -= ticket.amount;
        totalPendingUndelegateMonad -= ticket.amount;
        _withdrawIdInUse[ticket.validatorId][ticket.withdrawId] = false;

        emit MonadUndelegateTicketForceReleased(ticket.validatorId, ticket.withdrawId, ticket.amount);
    }

    /// @notice Configure the epoch delay applied to Monad unstake coverage and undelegation tickets.
    /// @dev Must track the Monad protocol's actual withdrawal/unbonding period. A value of 0 in storage
    ///      falls back to UNSTAKE_DELAY_EPOCHS; the setter rejects 0 so the fallback stays internal.
    function setMonadUnstakeDelayEpochs(uint64 newDelayEpochs) external onlyOwner {
        if (newDelayEpochs == 0 || newDelayEpochs > MONAD_MAX_UNSTAKE_DELAY_EPOCHS) {
            revert InvalidUnstakeDelayEpochs();
        }

        uint64 previousEpochs = _monadUnstakeDelayEpochs();
        monadUnstakeDelayEpochs = newDelayEpochs;
        emit MonadUnstakeDelayEpochsUpdated(previousEpochs, newDelayEpochs);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function setSer9StakingContract(address newStakingContract) external onlyOwner {
        ser9.setStakingContract(newStakingContract);
    }

    function setTokenCreationFee(uint256 newFee) external onlyOwner {
        uint256 previousFee = tokenCreationFee;
        tokenCreationFee = newFee;
        emit TokenCreationFeeUpdated(previousFee, newFee);
    }

    /// @notice Withdraw SER9 collected as token-creation fees.
    /// @dev Only fees tracked since the upgrade that introduced `accruedCreationFees` are
    ///      withdrawable. The counter only ever grows from collected creation fees, so staked
    ///      principal and pending-unstake balances can never be swept.
    function sweepCreationFees(address to, uint256 amount) external onlyOwner {
        if (to == address(0)) {
            revert InvalidSweepRecipient();
        }
        uint256 accrued = accruedCreationFees;
        if (amount == 0 || amount > accrued) {
            revert InsufficientCreationFees(amount, accrued);
        }
        accruedCreationFees = accrued - amount;
        IERC20(address(ser9)).safeTransfer(to, amount);
        emit CreationFeesSwept(to, amount);
    }

    function setPermit2(address newPermit2) external onlyOwner {
        if (newPermit2 == address(0) || newPermit2.code.length == 0) {
            revert InvalidPermit2Address();
        }

        address previousPermit2 = address(permit2);
        permit2 = IPermit2(newPermit2);
        emit Permit2Updated(previousPermit2, newPermit2);
    }

    function managedTokensLength() external view returns (uint256) {
        return managedTokens.length;
    }

    function setManagedTokenImplementation(address newImplementation) external onlyOwner {
        _validateImplementation(newImplementation);
        address previousImpl = managedTokenImplementation;
        managedTokenImplementation = newImplementation;
        emit ManagedTokenImplementationUpdated(previousImpl, newImplementation);
    }

    function upgradeSer9(address newSer9Impl, bytes calldata ser9Data) external onlyOwner {
        _validateImplementation(newSer9Impl);

        address ser9Proxy = address(ser9);
        if (ser9Proxy.code.length == 0) {
            revert InvalidTokenAddress();
        }

        address ser9Owner = ser9.owner();
        if (ser9Owner != address(this)) {
            revert UnauthorizedTokenOwner(ser9Proxy, ser9Owner);
        }

        ser9.upgradeToAndCall(newSer9Impl, ser9Data);
        emit Ser9Upgraded(ser9Proxy, newSer9Impl);
    }

    function upgradeManagedToken(address token, bytes calldata data) external onlyOwner {
        _upgradeManagedToken(token, managedTokenImplementation, data);
    }

    function requestManagedTokenUpgrade() external {
        _upgradeManagedToken(msg.sender, managedTokenImplementation, bytes(""));
    }

    function createManagedToken(
        string calldata name,
        string calldata symbol,
        uint256 mintRate,
        bool feeEnabled,
        uint16 feeBps
    ) external whenNotPaused returns (address token) {
        token = _createManagedToken(name, symbol, mintRate, feeEnabled, feeBps, 0, BPS_DENOMINATOR, 0);

        uint256 fee = tokenCreationFee;
        if (fee > 0) {
            accruedCreationFees += fee;
            IERC20(address(ser9)).safeTransferFrom(msg.sender, address(this), fee);
        }
    }

    function createManagedTokenWithPermit2(
        string calldata name,
        string calldata symbol,
        uint256 mintRate,
        bool feeEnabled,
        uint16 feeBps,
        IPermit2.PermitSingle calldata permitSingle,
        bytes calldata permitSignature
    ) external whenNotPaused returns (address token) {
        token = _createManagedToken(name, symbol, mintRate, feeEnabled, feeBps, 0, BPS_DENOMINATOR, 0);

        uint256 fee = tokenCreationFee;
        if (fee > 0) {
            accruedCreationFees += fee;
            _transferFromWithPermit2(address(ser9), fee, permitSingle, permitSignature);
        }
    }

    function createManagedTokenWithPolicy(
        string calldata name,
        string calldata symbol,
        uint256 mintRate,
        bool feeEnabled,
        uint16 feeBps,
        uint256 maxSupply,
        uint256 maxMultiplierBps,
        uint16 rampStartBps
    ) external whenNotPaused returns (address token) {
        token = _createManagedToken(
            name, symbol, mintRate, feeEnabled, feeBps, maxSupply, maxMultiplierBps, rampStartBps
        );

        uint256 fee = tokenCreationFee;
        if (fee > 0) {
            accruedCreationFees += fee;
            IERC20(address(ser9)).safeTransferFrom(msg.sender, address(this), fee);
        }
    }

    function createManagedTokenWithPermit2WithPolicy(
        string calldata name,
        string calldata symbol,
        uint256 mintRate,
        bool feeEnabled,
        uint16 feeBps,
        uint256 maxSupply,
        uint256 maxMultiplierBps,
        uint16 rampStartBps,
        IPermit2.PermitSingle calldata permitSingle,
        bytes calldata permitSignature
    ) external whenNotPaused returns (address token) {
        token = _createManagedToken(
            name, symbol, mintRate, feeEnabled, feeBps, maxSupply, maxMultiplierBps, rampStartBps
        );

        uint256 fee = tokenCreationFee;
        if (fee > 0) {
            accruedCreationFees += fee;
            _transferFromWithPermit2(address(ser9), fee, permitSingle, permitSignature);
        }
    }

    function _createManagedToken(
        string calldata name,
        string calldata symbol,
        uint256 mintRate,
        bool feeEnabled,
        uint16 feeBps,
        uint256 maxSupply,
        uint256 maxMultiplierBps,
        uint16 rampStartBps
    ) internal returns (address token) {
        if (mintRate == 0) {
            revert MintRateZero();
        }

        if (!feeEnabled && feeBps != 0) {
            revert InvalidFeeConfiguration();
        }
        _validateMintPolicy(maxSupply, maxMultiplierBps, rampStartBps);

        {
            bytes memory initData = abi.encodeCall(
                Series9ManagedToken.initialize, (name, symbol, address(this), feeEnabled, feeBps, address(this))
            );
            token = address(new ERC1967Proxy(managedTokenImplementation, initData));
        }

        address creator = msg.sender;
        tokenConfigs[token] =
            TokenConfig({exists: true, creator: creator, mintRate: mintRate, feeEnabled: feeEnabled});
        _tokenMintPolicies[token] = TokenMintPolicy({
            maxSupply: maxSupply,
            maxMultiplierBps: maxMultiplierBps,
            rampStartBps: maxSupply == 0 ? 0 : rampStartBps
        });
        managedTokens.push(token);

        emit ManagedTokenCreated(token, creator, mintRate, feeEnabled, feeBps, name, symbol);
        emit TokenMintPolicyConfigured(token, maxSupply, maxMultiplierBps, maxSupply == 0 ? 0 : rampStartBps);
    }

    function setTokenFeeBps(address token, uint16 newFeeBps) external {
        TokenConfig storage config = _requireManagedToken(token);
        if (!config.feeEnabled) {
            revert FeeDisabled();
        }
        if (msg.sender != config.creator) {
            revert UnauthorizedTokenCreator();
        }

        Series9ManagedToken(token).setFeeBps(newFeeBps);
        emit TokenFeeBpsUpdated(token, newFeeBps);
    }

    function setTokenFeeRecipient(address token, address newFeeRecipient) external onlyOwner {
        _requireManagedToken(token);
        // Fees must accrue to this contract so fee-token stakers receive them; redirecting the
        // recipient elsewhere would silently break fee-reward distribution.
        if (newFeeRecipient != address(this)) {
            revert InvalidFeeRecipientTarget();
        }
        Series9ManagedToken(token).setFeeRecipient(newFeeRecipient);
    }

    function setFeeExempt(address token, address account, bool isExempt) external onlyOwner {
        TokenConfig storage config = _requireManagedToken(token);
        if (!config.feeEnabled) {
            revert FeeDisabled();
        }
        if (account == address(this) && !isExempt) {
            revert CannotDisableStakingExemption();
        }

        Series9ManagedToken(token).setFeeExempt(account, isExempt);
        emit TokenFeeExemptUpdated(token, account, isExempt);
    }

    function stake(uint256 amount) external whenInitialized whenNotPaused nonReentrant updateReward(msg.sender) {
        if (amount == 0) {
            revert ZeroAmount();
        }

        totalStaked += amount;
        stakedBalance[msg.sender] += amount;
        _syncRewardWeight(msg.sender);

        IERC20(address(ser9)).safeTransferFrom(msg.sender, address(this), amount);

        emit Staked(msg.sender, amount);
    }

    function stakeWithPermit2(uint256 amount, IPermit2.PermitSingle calldata permitSingle, bytes calldata permitSignature)
        external
        whenInitialized
        whenNotPaused
        nonReentrant
        updateReward(msg.sender)
    {
        if (amount == 0) {
            revert ZeroAmount();
        }

        totalStaked += amount;
        stakedBalance[msg.sender] += amount;
        _syncRewardWeight(msg.sender);

        _transferFromWithPermit2(address(ser9), amount, permitSingle, permitSignature);

        emit Staked(msg.sender, amount);
    }

    function unstake(uint256 amount) external whenInitialized whenNotPaused nonReentrant updateReward(msg.sender) {
        if (amount == 0) {
            revert ZeroAmount();
        }

        _autoUnlockUnusedLocked(msg.sender);

        uint256 userStaked = stakedBalance[msg.sender];
        if (amount > userStaked) {
            revert InsufficientStakedBalance();
        }

        uint256 userLocked = lockedBalance[msg.sender];
        if (amount > userStaked - userLocked) {
            revert InsufficientUnlockedBalance();
        }

        stakedBalance[msg.sender] = userStaked - amount;
        totalStaked -= amount;
        _syncRewardWeight(msg.sender);

        (uint64 epoch,) = _getEpoch();
        uint64 minClaimEpoch = epoch + UNSTAKE_DELAY_EPOCHS;

        uint256 requestId = ser9UnstakeRequestCount[msg.sender];
        ser9UnstakeRequestCount[msg.sender] = requestId + 1;
        _ser9UnstakeRequests[msg.sender][requestId] =
            Ser9UnstakeRequest({amount: amount, requestEpoch: epoch, minClaimEpoch: minClaimEpoch, claimed: false});

        emit Ser9UnstakeRequested(msg.sender, requestId, amount, epoch, minClaimEpoch);
    }

    function claimUnstaked(uint256 requestId) external nonReentrant {
        if (requestId >= ser9UnstakeRequestCount[msg.sender]) {
            revert InvalidUnstakeRequest();
        }

        Ser9UnstakeRequest storage request = _ser9UnstakeRequests[msg.sender][requestId];
        if (request.claimed) {
            revert UnstakeRequestAlreadyClaimed();
        }

        (uint64 currentEpoch,) = _getEpoch();
        if (currentEpoch < request.minClaimEpoch) {
            revert UnstakeRequestNotClaimable(currentEpoch, request.minClaimEpoch);
        }

        request.claimed = true;

        IERC20(address(ser9)).safeTransfer(msg.sender, request.amount);

        emit Ser9UnstakeClaimed(msg.sender, requestId, request.amount);
        emit Unstaked(msg.sender, request.amount);
    }

    function stakeMonad() external payable whenInitialized whenNotPaused nonReentrant updateReward(msg.sender) {
        uint256 amount = msg.value;
        if (amount == 0) {
            revert ZeroAmount();
        }

        monadStakedBalance[msg.sender] += amount;
        totalMonadStaked += amount;
        _autoDelegateMonadStake();

        emit MonadStaked(msg.sender, amount);
    }

    function harvestMonadValidatorRewards()
        external
        whenNotPaused
        nonReentrant
        onlyMonadRebalanceOperator
        updateReward(address(0))
    {
        _harvestMonadValidatorRewards(trackedValidators.length);
    }

    /// @notice Owner-only escape hatch to claim MONAD rewards from a specific validator.
    /// @dev This allows the owner to directly claim rewards from a single validator without
    ///      going through the full rebalance/harvest cycle.
    function claimMonadValidatorReward(uint64 validatorId)
        external
        whenNotPaused
        nonReentrant
        onlyOwner
        updateReward(address(0))
    {
        uint256 beforeBalance = address(this).balance;
        try _monadStaking().claimRewards(validatorId) {} catch (bytes memory reason) {
            emit MonadClaimRewardsFailed(validatorId, reason);
            return;
        }

        uint256 afterBalance = address(this).balance;
        if (afterBalance > beforeBalance) {
            uint256 claimedAmount = afterBalance - beforeBalance;
            protocolMonadYieldAccrued += claimedAmount;
            emit MonadYieldAccrued(validatorId, claimedAmount);
        }
    }

    function delegateUnstakedMonad() external whenNotPaused nonReentrant onlyOwner {
        _autoDelegateMonadStake();
    }

    function transferExcessMonadYield(address payable recipient, uint256 amount)
        external
        whenNotPaused
        nonReentrant
        onlyOwner
    {
        if (amount == 0) {
            revert ZeroAmount();
        }

        uint256 availableAmount = _availableExcessMonadYield();
        if (amount > availableAmount) {
            revert InsufficientLiquidMonad(amount, availableAmount);
        }

        protocolMonadYieldAccrued -= amount;

        (bool ok,) = recipient.call{value: amount}("");
        if (!ok) {
            revert MonadPayoutFailed();
        }

        emit MonadYieldTransferred(recipient, amount);
    }

    function transferAllExcessMonadYield(address payable recipient)
        external
        whenNotPaused
        nonReentrant
        onlyOwner
    {
        uint256 availableAmount = _availableExcessMonadYield();
        if (availableAmount == 0) {
            revert ZeroAmount();
        }

        protocolMonadYieldAccrued -= availableAmount;

        (bool ok,) = recipient.call{value: availableAmount}("");
        if (!ok) {
            revert MonadPayoutFailed();
        }

        emit MonadYieldTransferred(recipient, availableAmount);
    }

    function requestUnstakeMonad(uint256 amount)
        external
        whenNotPaused
        nonReentrant
        updateReward(msg.sender)
        returns (uint256 requestId)
    {
        if (amount == 0) {
            revert ZeroAmount();
        }

        uint256 userStaked = monadStakedBalance[msg.sender];
        if (amount > userStaked) {
            revert InsufficientMonadStakedBalance();
        }

        monadStakedBalance[msg.sender] = userStaked - amount;
        totalMonadStaked -= amount;
        pendingMonadUnstakePrincipal += amount;
        totalPendingMonadUnstakeUncovered += amount;

        (uint64 epoch,) = _getEpoch();

        requestId = monadUnstakeRequestCount[msg.sender];
        monadUnstakeRequestCount[msg.sender] = requestId + 1;
        _monadUnstakeRequests[msg.sender][requestId] =
            MonadUnstakeRequest({
                amount: amount,
                requestEpoch: epoch,
                minClaimEpoch: type(uint64).max,
                claimed: false,
                uncoveredAmount: amount
            });
        _pendingMonadUnstakeRequests.push(MonadUnstakeRequestRef({user: msg.sender, requestId: requestId}));

        uint64 minClaimEpoch = _queuePendingMonadUnstakeCoverage(epoch, MONAD_VALIDATOR_BATCH_LIMIT);
        MonadUnstakeRequest storage request = _monadUnstakeRequests[msg.sender][requestId];
        if (request.uncoveredAmount != 0) {
            minClaimEpoch = type(uint64).max;
        } else {
            minClaimEpoch = request.minClaimEpoch;
        }

        emit MonadUnstakeRequested(msg.sender, requestId, amount, epoch, minClaimEpoch);
    }

    function claimUnstakedMonad(uint256 requestId) external nonReentrant {
        if (requestId >= monadUnstakeRequestCount[msg.sender]) {
            revert InvalidUnstakeRequest();
        }

        MonadUnstakeRequest storage request = _monadUnstakeRequests[msg.sender][requestId];
        if (request.claimed) {
            revert UnstakeRequestAlreadyClaimed();
        }

        (uint64 currentEpoch,) = _getEpoch();
        if (request.uncoveredAmount != 0 || currentEpoch < request.minClaimEpoch) {
            revert UnstakeRequestNotClaimable(currentEpoch, request.minClaimEpoch);
        }

        uint256 availableAmount = _availableMonadForUserClaims();
        if (request.amount > availableAmount) {
            revert InsufficientLiquidMonad(request.amount, availableAmount);
        }

        request.claimed = true;
        pendingMonadUnstakePrincipal -= request.amount;

        (bool ok,) = msg.sender.call{value: request.amount}("");
        if (!ok) {
            revert MonadPayoutFailed();
        }

        emit MonadUnstakeClaimed(msg.sender, requestId, request.amount);
    }

    function processPendingMonadUnstakeCoverage(uint256 maxValidators)
        external
        whenInitialized
        nonReentrant
        returns (uint64 maxClaimEpoch)
    {
        (uint64 currentEpoch,) = _getEpoch();
        maxClaimEpoch = _queuePendingMonadUnstakeCoverage(currentEpoch, _resolveBatchLimit(maxValidators, MONAD_VALIDATOR_BATCH_LIMIT));
    }

    function processMaturedMonadUndelegations(uint256 maxTickets)
        external
        whenInitialized
        nonReentrant
        returns (uint256 processed)
    {
        (uint64 currentEpoch,) = _getEpoch();
        processed = _processMaturedUndelegations(currentEpoch, _resolveBatchLimit(maxTickets, MONAD_TICKET_BATCH_LIMIT));
    }

    function rebalanceMonadDelegations() external whenNotPaused nonReentrant onlyMonadRebalanceOperator {
        rewardPerTokenStored = rewardPerToken();
        lastUpdateBlock = block.number;
        monadRewardPerTokenStored = monadRewardPerToken();
        monadLastUpdateBlock = block.number;

        _harvestMonadValidatorRewards(MONAD_VALIDATOR_BATCH_LIMIT);
        (uint64 currentEpoch,) = _getEpoch();
        _processMaturedUndelegations(currentEpoch, MONAD_TICKET_BATCH_LIMIT);
        _queuePendingMonadUnstakeCoverage(currentEpoch, MONAD_VALIDATOR_BATCH_LIMIT);
        _updateMonadTargets();
        _rebalanceToMonadTargets(currentEpoch, MONAD_VALIDATOR_BATCH_LIMIT);

        emit MonadRebalanced(totalMonadStaked, totalDelegatedMonad, totalPendingUndelegateMonad);
    }

    function monadUnstakeRequest(address user, uint256 requestId)
        external
        view
        returns (uint256 amount, uint64 requestEpoch, uint64 minClaimEpoch, bool claimed)
    {
        if (requestId >= monadUnstakeRequestCount[user]) {
            revert InvalidUnstakeRequest();
        }

        MonadUnstakeRequest storage request = _monadUnstakeRequests[user][requestId];
        return (request.amount, request.requestEpoch, request.minClaimEpoch, request.claimed);
    }

    function ser9UnstakeRequest(address user, uint256 requestId)
        external
        view
        returns (uint256 amount, uint64 requestEpoch, uint64 minClaimEpoch, bool claimed)
    {
        if (requestId >= ser9UnstakeRequestCount[user]) {
            revert InvalidUnstakeRequest();
        }

        Ser9UnstakeRequest storage request = _ser9UnstakeRequests[user][requestId];
        return (request.amount, request.requestEpoch, request.minClaimEpoch, request.claimed);
    }

    function claimRewards() external whenNotPaused nonReentrant updateReward(msg.sender) {
        uint256 reward = rewards[msg.sender] + monadRewards[msg.sender];
        if (reward == 0) {
            revert NoRewards();
        }

        rewards[msg.sender] = 0;
        monadRewards[msg.sender] = 0;
        ser9.mint(msg.sender, reward);

        emit RewardClaimed(msg.sender, reward);
    }

    function lock(uint256) external pure {
        revert ManualLockDisabled();
    }

    function mintManagedToken(address token, uint256 amount) external whenNotPaused nonReentrant updateReward(msg.sender) {
        if (amount == 0) {
            revert ZeroAmount();
        }

        _autoUnlockUnusedLocked(msg.sender);

        TokenConfig storage config = _requireManagedToken(token);
        TokenMintPolicy memory policy = _resolveTokenMintPolicy(token);
        uint256 currentSupply = Series9ManagedToken(token).totalSupply();
        uint256 collateralCost = _previewCollateralForMint(config.mintRate, policy, currentSupply, amount);

        uint256 userLocked = lockedBalance[msg.sender];
        uint256 userUsed = usedLockedSer9[msg.sender];
        uint256 unusedLocked = userLocked - userUsed;
        uint256 additionalLockRequired = collateralCost > unusedLocked ? collateralCost - unusedLocked : 0;

        if (additionalLockRequired > stakedBalance[msg.sender] - userLocked) {
            revert ExceedsMintLimit();
        }

        uint256 usedAfter = userUsed + collateralCost;
        uint256 lockedAfter = userLocked + additionalLockRequired;

        lockedBalance[msg.sender] = lockedAfter;
        usedLockedSer9[msg.sender] = usedAfter;
        userTokenDebt[msg.sender][token] += amount;
        userTokenCollateralUsed[msg.sender][token] += collateralCost;
        _syncRewardWeight(msg.sender);

        Series9ManagedToken(token).mint(msg.sender, amount);

        if (additionalLockRequired > 0) {
            emit Locked(msg.sender, additionalLockRequired, lockedAfter);
        }
        emit ManagedTokenMinted(msg.sender, token, amount, collateralCost, usedAfter);
    }

    function burnAndUnlock(address token, uint256 burnAmount) external whenNotPaused nonReentrant updateReward(msg.sender) {
        if (burnAmount == 0) {
            revert ZeroAmount();
        }

        _requireManagedToken(token);

        uint256 debtBefore = userTokenDebt[msg.sender][token];
        if (burnAmount > debtBefore) {
            revert InsufficientTokenDebt();
        }

        uint256 collateralUsedBefore = userTokenCollateralUsed[msg.sender][token];
        uint256 collateralRelease;
        if (burnAmount == debtBefore) {
            collateralRelease = collateralUsedBefore;
        } else {
            // Partial burns unlock collateral proportionally to outstanding debt.
            collateralRelease = Math.mulDiv(collateralUsedBefore, burnAmount, debtBefore);
        }

        uint256 userLocked = lockedBalance[msg.sender];
        if (collateralRelease > userLocked) {
            revert InsufficientLockedBalance();
        }

        usedLockedSer9[msg.sender] -= collateralRelease;
        userTokenDebt[msg.sender][token] = debtBefore - burnAmount;
        userTokenCollateralUsed[msg.sender][token] = collateralUsedBefore - collateralRelease;

        lockedBalance[msg.sender] = userLocked - collateralRelease;
        _autoUnlockUnusedLocked(msg.sender);
        _syncRewardWeight(msg.sender);

        Series9ManagedToken(token).burnFromAccount(msg.sender, burnAmount);

        emit ManagedTokenBurnedAndUnlocked(
            msg.sender, token, burnAmount, collateralRelease, usedLockedSer9[msg.sender], lockedBalance[msg.sender]
        );
    }

    function unlockUnused(uint256 amount) external whenNotPaused nonReentrant updateReward(msg.sender) {
        if (amount == 0) {
            revert ZeroAmount();
        }

        uint256 userLocked = lockedBalance[msg.sender];
        uint256 unusedLocked = userLocked - usedLockedSer9[msg.sender];
        if (amount > unusedLocked) {
            revert InsufficientUnusedLockedBalance();
        }

        lockedBalance[msg.sender] = userLocked - amount;
        _syncRewardWeight(msg.sender);

        emit UnusedLockedUnlocked(msg.sender, amount, lockedBalance[msg.sender]);
    }

    function maxMintable(address user, address token) external view returns (uint256) {
        TokenConfig storage config = tokenConfigs[token];
        if (!config.exists) {
            return 0;
        }

        uint256 availableCollateral = stakedBalance[user] - usedLockedSer9[user];
        if (availableCollateral == 0) {
            return 0;
        }

        TokenMintPolicy memory policy = _resolveTokenMintPolicy(token);
        if (policy.maxSupply == 0) {
            return Math.mulDiv(availableCollateral, PRECISION, config.mintRate);
        }

        uint256 currentSupply = Series9ManagedToken(token).totalSupply();
        if (currentSupply >= policy.maxSupply) {
            return 0;
        }

        uint256 low = 0;
        uint256 high = policy.maxSupply - currentSupply;

        while (low < high) {
            uint256 mid = (low + high + 1) / 2;
            uint256 collateral = _previewCollateralForMint(config.mintRate, policy, currentSupply, mid);
            if (collateral <= availableCollateral) {
                low = mid;
            } else {
                high = mid - 1;
            }
        }

        return low;
    }

    function availableMintCollateral(address user) external view returns (uint256) {
        return stakedBalance[user] - usedLockedSer9[user];
    }

    function availableUnusedLocked(address user) external view returns (uint256) {
        return lockedBalance[user] - usedLockedSer9[user];
    }

    function tokenMintPolicies(address token)
        external
        view
        returns (uint256 maxSupply, uint256 maxMultiplierBps, uint16 rampStartBps)
    {
        TokenMintPolicy memory policy = _resolveTokenMintPolicy(token);
        return (policy.maxSupply, policy.maxMultiplierBps, policy.rampStartBps);
    }

    function effectiveMintRate(address token) public view returns (uint256) {
        TokenConfig storage config = tokenConfigs[token];
        if (!config.exists) {
            return 0;
        }

        TokenMintPolicy memory policy = _resolveTokenMintPolicy(token);
        if (policy.maxSupply == 0) {
            return config.mintRate;
        }

        uint256 currentSupply = Series9ManagedToken(token).totalSupply();
        return _effectiveMintRateAtSupply(config.mintRate, policy, currentSupply);
    }

    function previewMintCollateral(address token, uint256 amount) external view returns (uint256) {
        if (amount == 0) {
            return 0;
        }

        TokenConfig storage config = _requireManagedToken(token);
        TokenMintPolicy memory policy = _resolveTokenMintPolicy(token);
        uint256 currentSupply = Series9ManagedToken(token).totalSupply();
        return _previewCollateralForMint(config.mintRate, policy, currentSupply, amount);
    }

    function stakeFeeToken(address token, uint256 amount) external whenInitialized whenNotPaused nonReentrant {
        if (amount == 0) {
            revert ZeroAmount();
        }

        TokenConfig storage config = _requireManagedToken(token);
        _requireFeeEnabled(config);

        _accrueFeeRewards(token, msg.sender);

        feePools[token].totalStaked += amount;
        feeStakeBalance[token][msg.sender] += amount;
        feeRewardDebt[token][msg.sender] =
            Math.mulDiv(feeStakeBalance[token][msg.sender], feePools[token].accFeePerShare, PRECISION);

        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        emit FeeTokenStaked(msg.sender, token, amount, feeStakeBalance[token][msg.sender]);
    }

    function stakeFeeTokenWithPermit2(
        address token,
        uint256 amount,
        IPermit2.PermitSingle calldata permitSingle,
        bytes calldata permitSignature
    ) external whenInitialized whenNotPaused nonReentrant {
        if (amount == 0) {
            revert ZeroAmount();
        }

        TokenConfig storage config = _requireManagedToken(token);
        _requireFeeEnabled(config);

        _accrueFeeRewards(token, msg.sender);

        feePools[token].totalStaked += amount;
        feeStakeBalance[token][msg.sender] += amount;
        feeRewardDebt[token][msg.sender] =
            Math.mulDiv(feeStakeBalance[token][msg.sender], feePools[token].accFeePerShare, PRECISION);

        _transferFromWithPermit2(token, amount, permitSingle, permitSignature);

        emit FeeTokenStaked(msg.sender, token, amount, feeStakeBalance[token][msg.sender]);
    }

    function unstakeFeeToken(address token, uint256 amount) external whenNotPaused nonReentrant {
        if (amount == 0) {
            revert ZeroAmount();
        }

        TokenConfig storage config = _requireManagedToken(token);
        _requireFeeEnabled(config);

        uint256 userStake = feeStakeBalance[token][msg.sender];
        if (amount > userStake) {
            revert InsufficientStakedBalance();
        }

        _accrueFeeRewards(token, msg.sender);

        feeStakeBalance[token][msg.sender] = userStake - amount;
        feePools[token].totalStaked -= amount;
        feeRewardDebt[token][msg.sender] =
            Math.mulDiv(feeStakeBalance[token][msg.sender], feePools[token].accFeePerShare, PRECISION);

        IERC20(token).safeTransfer(msg.sender, amount);

        emit FeeTokenUnstaked(msg.sender, token, amount, feeStakeBalance[token][msg.sender]);
    }

    function claimFeeRewards(address token) external whenNotPaused nonReentrant {
        TokenConfig storage config = _requireManagedToken(token);
        _requireFeeEnabled(config);

        _accrueFeeRewards(token, msg.sender);

        uint256 pending = feePendingRewards[token][msg.sender];
        if (pending == 0) {
            revert NoFeeRewards();
        }

        feePendingRewards[token][msg.sender] = 0;
        feePools[token].rewardBalance -= pending;

        IERC20(token).safeTransfer(msg.sender, pending);

        emit FeeRewardsClaimed(msg.sender, token, pending);
    }

    function pendingFeeRewards(address token, address user) external view returns (uint256) {
        TokenConfig storage config = tokenConfigs[token];
        if (!config.exists || !config.feeEnabled) {
            return 0;
        }

        uint256 acc = _previewAccFeePerShare(token);
        uint256 amount = feeStakeBalance[token][user];
        uint256 accumulated = Math.mulDiv(amount, acc, PRECISION);
        uint256 debt = feeRewardDebt[token][user];

        if (accumulated > debt) {
            return feePendingRewards[token][user] + (accumulated - debt);
        }

        return feePendingRewards[token][user];
    }

    function unlockedStake(address user) public view returns (uint256) {
        return stakedBalance[user] - lockedBalance[user];
    }

    function rewardPerToken() public view returns (uint256) {
        if (totalRewardWeight == 0) {
            return rewardPerTokenStored;
        }

        uint256 blockDelta = block.number - lastUpdateBlock;
        uint256 rewardDelta = Math.mulDiv(blockDelta * rewardRatePerBlock, PRECISION, totalRewardWeight);
        return rewardPerTokenStored + rewardDelta;
    }

    function monadRewardPerToken() public view returns (uint256) {
        if (totalMonadStaked == 0 || monadLastUpdateBlock == 0) {
            return monadRewardPerTokenStored;
        }

        uint256 blockDelta = block.number - monadLastUpdateBlock;
        uint256 rewardDelta = Math.mulDiv(blockDelta * monadRewardRatePerBlock, PRECISION, totalMonadStaked);
        return monadRewardPerTokenStored + rewardDelta;
    }

    function earned(address account) public view returns (uint256) {
        return _earnedSer9(account) + _earnedMonad(account);
    }

    function monadEarned(address account) external view returns (uint256) {
        return _earnedMonad(account);
    }

    function _earnedSer9(address account) internal view returns (uint256) {
        uint256 rewardDelta = rewardPerToken() - userRewardPerTokenPaid[account];
        uint256 accrued = Math.mulDiv(rewardWeightBalance[account], rewardDelta, PRECISION);
        return rewards[account] + accrued;
    }

    function _earnedMonad(address account) internal view returns (uint256) {
        uint256 rewardDelta = monadRewardPerToken() - userMonadRewardPerTokenPaid[account];
        uint256 accrued = Math.mulDiv(monadStakedBalance[account], rewardDelta, PRECISION);
        return monadRewards[account] + accrued;
    }

    function _requireManagedToken(address token) internal view returns (TokenConfig storage config) {
        config = tokenConfigs[token];
        if (!config.exists) {
            revert InvalidManagedToken();
        }
    }

    function _validateMintPolicy(uint256, uint256 maxMultiplierBps, uint16 rampStartBps) internal pure {
        if (maxMultiplierBps < BPS_DENOMINATOR) {
            revert InvalidMaxMultiplierBps(maxMultiplierBps);
        }
        if (rampStartBps > BPS_DENOMINATOR - 1) {
            revert InvalidRampStartBps(rampStartBps);
        }
    }

    function _resolveTokenMintPolicy(address token) internal view returns (TokenMintPolicy memory policy) {
        policy = _tokenMintPolicies[token];
        if (policy.maxSupply == 0) {
            return TokenMintPolicy({maxSupply: 0, maxMultiplierBps: BPS_DENOMINATOR, rampStartBps: 0});
        }
    }

    function _effectiveMintRateAtSupply(uint256 baseRate, TokenMintPolicy memory policy, uint256 supply)
        internal
        pure
        returns (uint256)
    {
        if (policy.maxSupply == 0) {
            return baseRate;
        }

        uint256 multiplierBps = _multiplierBpsAtSupply(policy, supply);
        return Math.mulDiv(baseRate, multiplierBps, BPS_DENOMINATOR);
    }

    function _previewCollateralForMint(
        uint256 baseRate,
        TokenMintPolicy memory policy,
        uint256 currentSupply,
        uint256 amount
    ) internal pure returns (uint256) {
        if (amount == 0) {
            return 0;
        }

        if (policy.maxSupply == 0) {
            return _collateralForAmount(amount, baseRate);
        }

        uint256 requestedSupply = currentSupply + amount;
        if (requestedSupply > policy.maxSupply) {
            revert ExceedsMaxSupply(requestedSupply, policy.maxSupply);
        }

        if (policy.maxMultiplierBps == BPS_DENOMINATOR) {
            return _collateralForAmount(amount, baseRate);
        }

        uint256 startSupply = _rampStartSupply(policy);
        uint256 collateral;

        if (currentSupply < startSupply) {
            uint256 preRampEnd = requestedSupply < startSupply ? requestedSupply : startSupply;
            uint256 preRampAmount = preRampEnd - currentSupply;
            if (preRampAmount > 0) {
                collateral += _collateralForAmount(preRampAmount, baseRate);
            }
        }

        uint256 rampStartSupply = currentSupply > startSupply ? currentSupply : startSupply;
        if (requestedSupply > rampStartSupply) {
            uint256 rampAmount = requestedSupply - rampStartSupply;
            uint256 startBps = _multiplierBpsAtSupply(policy, rampStartSupply);
            uint256 endBps = _multiplierBpsAtSupply(policy, requestedSupply);
            uint256 bpsSum = startBps + endBps;
            uint256 baseRampCollateral = _collateralForAmount(rampAmount, baseRate);
            collateral += Math.mulDiv(baseRampCollateral, bpsSum, 2 * BPS_DENOMINATOR, Math.Rounding.Ceil);
        }

        return collateral;
    }

    function _rampStartSupply(TokenMintPolicy memory policy) internal pure returns (uint256) {
        return Math.mulDiv(policy.maxSupply, policy.rampStartBps, BPS_DENOMINATOR);
    }

    function _multiplierBpsAtSupply(TokenMintPolicy memory policy, uint256 supply) internal pure returns (uint256) {
        if (policy.maxSupply == 0) {
            return BPS_DENOMINATOR;
        }

        if (supply >= policy.maxSupply) {
            return policy.maxMultiplierBps;
        }

        uint256 startSupply = _rampStartSupply(policy);
        if (supply <= startSupply) {
            return BPS_DENOMINATOR;
        }

        uint256 rampRange = policy.maxSupply - startSupply;
        uint256 rampProgress = supply - startSupply;
        uint256 extraBps = Math.mulDiv(policy.maxMultiplierBps - BPS_DENOMINATOR, rampProgress, rampRange);
        return BPS_DENOMINATOR + extraBps;
    }

    function _transferFromWithPermit2(
        address token,
        uint256 amount,
        IPermit2.PermitSingle calldata permitSingle,
        bytes calldata permitSignature
    ) internal {
        IPermit2 permit2Contract = permit2;
        if (address(permit2Contract) == address(0)) {
            revert Permit2NotConfigured();
        }

        if (permitSingle.details.token != token) {
            revert InvalidPermit2Token(token, permitSingle.details.token);
        }
        if (permitSingle.spender != address(this)) {
            revert InvalidPermit2Spender(address(this), permitSingle.spender);
        }
        if (uint256(permitSingle.details.amount) < amount) {
            revert Permit2AmountTooLow(amount, uint256(permitSingle.details.amount));
        }

        permit2Contract.permit(msg.sender, permitSingle, permitSignature);
        permit2Contract.transferFrom(msg.sender, address(this), SafeCast.toUint160(amount), token);
    }

    function _requireFeeEnabled(TokenConfig storage config) internal view {
        if (!config.feeEnabled) {
            revert FeeDisabled();
        }
    }

    function _autoUnlockUnusedLocked(address account) internal {
        uint256 userLocked = lockedBalance[account];
        uint256 userUsed = usedLockedSer9[account];
        if (userLocked <= userUsed) {
            return;
        }

        lockedBalance[account] = userUsed;
        emit UnusedLockedUnlocked(account, userLocked - userUsed, userUsed);
    }

    function _syncRewardWeight(address account) internal {
        uint256 oldWeight = rewardWeightBalance[account];
        uint256 newWeight = _rewardWeightFrom(stakedBalance[account], lockedBalance[account]);

        rewardWeightBalance[account] = newWeight;

        if (newWeight > oldWeight) {
            totalRewardWeight += newWeight - oldWeight;
        } else if (oldWeight > newWeight) {
            totalRewardWeight -= oldWeight - newWeight;
        }
    }

    function _rewardWeightFrom(uint256 staked, uint256 locked) internal pure returns (uint256) {
        uint256 unlocked = staked - locked;
        return (unlocked * 2) + locked;
    }

    function _collateralForAmount(uint256 amount, uint256 mintRate) internal pure returns (uint256) {
        return Math.mulDiv(amount, mintRate, PRECISION, Math.Rounding.Ceil);
    }

    function _previewAccFeePerShare(address token) internal view returns (uint256) {
        FeePool storage pool = feePools[token];
        if (pool.totalStaked == 0) {
            return pool.accFeePerShare;
        }

        uint256 tokenBalance = IERC20(token).balanceOf(address(this));
        if (tokenBalance < pool.totalStaked) {
            return pool.accFeePerShare;
        }

        uint256 rewardBalance = tokenBalance - pool.totalStaked;
        if (rewardBalance < pool.rewardBalance) {
            return pool.accFeePerShare;
        }

        uint256 newlyReceived = rewardBalance - pool.rewardBalance;
        uint256 distributable = pool.undistributedRewards + newlyReceived;
        if (distributable == 0) {
            return pool.accFeePerShare;
        }

        return pool.accFeePerShare + Math.mulDiv(distributable, PRECISION, pool.totalStaked);
    }

    function _updateFeePool(address token) internal {
        FeePool storage pool = feePools[token];

        uint256 tokenBalance = IERC20(token).balanceOf(address(this));
        if (tokenBalance < pool.totalStaked) {
            pool.rewardBalance = 0;
            pool.undistributedRewards = 0;
            return;
        }

        uint256 rewardBalance = tokenBalance - pool.totalStaked;
        if (pool.totalStaked == 0) {
            if (rewardBalance > pool.rewardBalance) {
                pool.undistributedRewards += rewardBalance - pool.rewardBalance;
            }
            pool.rewardBalance = rewardBalance;
            return;
        }

        if (rewardBalance < pool.rewardBalance) {
            pool.rewardBalance = rewardBalance;
            return;
        }

        uint256 newlyReceived = rewardBalance - pool.rewardBalance;
        uint256 distributable = pool.undistributedRewards + newlyReceived;
        if (distributable > 0) {
            uint256 accDelta = Math.mulDiv(distributable, PRECISION, pool.totalStaked);
            if (accDelta > 0) {
                pool.accFeePerShare += accDelta;
                // Carry the sub-share remainder so dust is not lost when totalStaked is large.
                uint256 consumed = Math.mulDiv(accDelta, pool.totalStaked, PRECISION);
                pool.undistributedRewards = distributable - consumed;
            } else {
                pool.undistributedRewards = distributable;
            }
        }

        pool.rewardBalance = rewardBalance;
    }

    function _accrueFeeRewards(address token, address user) internal {
        _updateFeePool(token);

        uint256 amount = feeStakeBalance[token][user];
        uint256 accumulated = Math.mulDiv(amount, feePools[token].accFeePerShare, PRECISION);
        uint256 debt = feeRewardDebt[token][user];

        if (accumulated > debt) {
            feePendingRewards[token][user] += accumulated - debt;
        }

        feeRewardDebt[token][user] = accumulated;
    }

    function _monadStaking() internal pure returns (IMonadStaking) {
        return IMonadStaking(address(uint160(MONAD_PRECOMPILE_ADDRESS)));
    }

    function _getEpoch() internal returns (uint64 epoch, bool inEpochDelayPeriod) {
        try _monadStaking().getEpoch() returns (uint64 currentEpoch, bool isDelayPeriod) {
            return (currentEpoch, isDelayPeriod);
        } catch {
            revert MonadEpochReadFailed();
        }
    }

    function _monadUnstakeDelayEpochs() internal view returns (uint64) {
        uint64 configured = monadUnstakeDelayEpochs;
        return configured == 0 ? UNSTAKE_DELAY_EPOCHS : configured;
    }

    /// @dev Credit any unexpected balance increase from a Monad precompile call to protocol yield.
    ///      Some Monad staking precompile operations (delegate/undelegate/withdraw) may auto-pay
    ///      accrued validator rewards alongside the requested action. Without this, that MON would be
    ///      misclassified as principal and become unsweepable. `expectedOutflow`/`expectedInflow` are
    ///      the principal movements the caller already accounts for; only the surplus is treated as yield.
    function _accruePrecompileYield(
        uint64 validatorId,
        uint256 balanceBefore,
        uint256 expectedOutflow,
        uint256 expectedInflow
    ) internal {
        uint256 expectedBalance = balanceBefore + expectedInflow - expectedOutflow;
        uint256 balanceAfter = address(this).balance;
        if (balanceAfter > expectedBalance) {
            uint256 yieldAmount = balanceAfter - expectedBalance;
            protocolMonadYieldAccrued += yieldAmount;
            emit MonadYieldAccrued(validatorId, yieldAmount);
        }
    }

    function _availableLiquidForActiveDelegation() internal view returns (uint256) {
        uint256 balance = address(this).balance;
        uint256 reserved = pendingMonadUnstakePrincipal + protocolMonadYieldAccrued;
        if (balance <= reserved) {
            return 0;
        }

        return balance - reserved;
    }

    function _availableMonadForUserClaims() internal view returns (uint256) {
        uint256 balance = address(this).balance;
        if (balance <= protocolMonadYieldAccrued) {
            return 0;
        }
        return balance - protocolMonadYieldAccrued;
    }

    function _availableExcessMonadYield() internal view returns (uint256) {
        uint256 balance = address(this).balance;
        uint256 reservedForClaims = pendingMonadUnstakePrincipal;
        if (balance <= reservedForClaims) {
            return 0;
        }

        uint256 availableAmount = balance - reservedForClaims;
        if (availableAmount > protocolMonadYieldAccrued) {
            return protocolMonadYieldAccrued;
        }

        return availableAmount;
    }

    function _targetDelegatedPrincipal() internal view returns (uint256) {
        return totalMonadStaked;
    }

    function _autoDelegateMonadStake() internal {
        uint256 targetDelegatedPrincipal = _targetDelegatedPrincipal();
        if (totalDelegatedMonad >= targetDelegatedPrincipal) {
            return;
        }

        uint256 liquidAmount = _availableLiquidForActiveDelegation();
        uint256 headroom = targetDelegatedPrincipal - totalDelegatedMonad;
        if (liquidAmount > headroom) {
            liquidAmount = headroom;
        }
        if (liquidAmount == 0) {
            return;
        }

        uint256 selectedCount = targetValidatorCount;
        if (selectedCount == 0) {
            uint64 fallbackValidatorId = _fallbackTrackedValidator();
            if (fallbackValidatorId == 0) {
                return;
            }

            _delegateMonadAmountToValidator(fallbackValidatorId, liquidAmount);
            return;
        }

        uint64[] memory selectedValidators = new uint64[](selectedCount);
        uint256[] memory targetAmounts = new uint256[](selectedCount);
        uint256 remaining = targetDelegatedPrincipal;

        for (uint256 i = 0; i < selectedCount; ++i) {
            selectedValidators[i] = targetValidatorIds[i];
            if (i == selectedCount - 1) {
                targetAmounts[i] = remaining;
            } else {
                targetAmounts[i] = Math.mulDiv(targetDelegatedPrincipal, targetValidatorWeightsBps[i], BPS_DENOMINATOR);
                remaining -= targetAmounts[i];
            }
        }

        for (uint256 i = 0; i < selectedCount && liquidAmount > 0; ++i) {
            uint64 validatorId = selectedValidators[i];
            uint256 delegatedAmount = validatorDelegatedAmount[validatorId];
            uint256 targetAmount = targetAmounts[i];
            if (delegatedAmount >= targetAmount) {
                continue;
            }

            uint256 delegateAmount = targetAmount - delegatedAmount;
            if (delegateAmount > liquidAmount) {
                delegateAmount = liquidAmount;
            }

            if (_delegateMonadAmountToValidator(validatorId, delegateAmount)) {
                liquidAmount -= delegateAmount;
            }
        }
    }

    function _fallbackTrackedValidator() internal returns (uint64 validatorId) {
        uint256 trackedLength = trackedValidators.length;
        if (trackedLength == 0) {
            return 0;
        }

        uint256 cursor = monadFallbackValidatorCursor;
        if (cursor >= trackedLength) {
            cursor = 0;
        }

        uint256 scanned;
        while (scanned < trackedLength && scanned < MONAD_VALIDATOR_BATCH_LIMIT) {
            uint64 candidateValidatorId = trackedValidators[cursor];
            if (validatorDelegatedAmount[candidateValidatorId] > 0) {
                monadFallbackValidatorCursor = (cursor + 1) % trackedLength;
                return candidateValidatorId;
            }

            unchecked {
                ++scanned;
                ++cursor;
            }

            if (cursor == trackedLength) {
                cursor = 0;
            }
        }

        monadFallbackValidatorCursor = cursor;
    }

    function _delegateMonadAmountToValidator(uint64 validatorId, uint256 amount) internal returns (bool delegated) {
        if (validatorId == 0 || amount == 0) {
            return false;
        }

        _trackValidator(validatorId);
        uint256 balanceBefore = address(this).balance;
        try _monadStaking().delegate{value: amount}(validatorId) returns (bool success) {
            if (!success) {
                emit MonadDelegateFailed(validatorId, amount, "");
                return false;
            }
        } catch (bytes memory reason) {
            emit MonadDelegateFailed(validatorId, amount, reason);
            return false;
        }
        _accruePrecompileYield(validatorId, balanceBefore, amount, 0);

        validatorDelegatedAmount[validatorId] += amount;
        totalDelegatedMonad += amount;
        return true;
    }

    function _queueUnstakeFromDelegations(uint256 amount, uint64 epoch, uint256 maxValidators)
        internal
        returns (uint256 queuedAmount, uint64 maxClaimableEpoch)
    {
        uint256 remaining = amount;
        uint256 trackedLength = trackedValidators.length;
        if (remaining == 0 || trackedLength == 0 || maxValidators == 0) {
            return (0, 0);
        }

        uint256 cursor = monadUndelegateValidatorCursor;
        if (cursor >= trackedLength) {
            cursor = 0;
        }
        uint256 scanned;
        uint256 windowSize = trackedLength < maxValidators ? trackedLength : maxValidators;
        UnstakeCandidate[] memory candidates = new UnstakeCandidate[](windowSize);
        uint256 candidateCount;

        while (scanned < trackedLength && scanned < maxValidators) {
            uint64 validatorId = trackedValidators[cursor];
            if (validatorDelegatedAmount[validatorId] != 0) {
                candidates[candidateCount] = UnstakeCandidate({
                    validatorId: validatorId,
                    score: cachedValidatorScore[validatorId],
                    commission: validatorSamples[validatorId].commission,
                    hasKnownScore: hasCachedValidatorScore[validatorId]
                });
                candidateCount++;
            }

            unchecked {
                ++scanned;
                ++cursor;
            }
            if (cursor == trackedLength) {
                cursor = 0;
            }
        }

        _sortUnstakeCandidates(candidates, candidateCount);

        for (uint256 i = 0; i < candidateCount && remaining > 0; ++i) {
            (uint256 undelegatedAmount, uint64 claimableEpoch) =
                _undelegateFromValidator(candidates[i].validatorId, remaining, epoch);
            if (undelegatedAmount == 0) {
                continue;
            }

            remaining -= undelegatedAmount;
            queuedAmount += undelegatedAmount;
            if (claimableEpoch > maxClaimableEpoch) {
                maxClaimableEpoch = claimableEpoch;
            }
        }

        monadUndelegateValidatorCursor = cursor;
    }

    function _queuePendingMonadUnstakeCoverage(uint64 epoch, uint256 maxValidators) internal returns (uint64 maxClaimEpoch) {
        uint256 availableForClaims = _availableMonadForUserClaims();
        uint256 coveredByLiquidOrPending = availableForClaims + totalPendingUndelegateMonad;
        uint256 undelegateAmount = pendingMonadUnstakePrincipal > coveredByLiquidOrPending
            ? pendingMonadUnstakePrincipal - coveredByLiquidOrPending
            : 0;

        (, uint64 queuedClaimEpoch) = _queueUnstakeFromDelegations(undelegateAmount, epoch, maxValidators);

        uint64 coverageClaimEpoch = epoch + _monadUnstakeDelayEpochs();
        if (queuedClaimEpoch > coverageClaimEpoch) {
            coverageClaimEpoch = queuedClaimEpoch;
        }

        _allocateMonadRequestCoverage(_unassignedMonadCoverageAmount(), coverageClaimEpoch);
        return coverageClaimEpoch;
    }

    function _unassignedMonadCoverageAmount() internal view returns (uint256) {
        uint256 coveredByLiquidOrPending = _availableMonadForUserClaims() + totalPendingUndelegateMonad;
        uint256 coveredPrincipal = pendingMonadUnstakePrincipal > coveredByLiquidOrPending
            ? coveredByLiquidOrPending
            : pendingMonadUnstakePrincipal;
        uint256 assignedCovered = pendingMonadUnstakePrincipal - totalPendingMonadUnstakeUncovered;

        if (coveredPrincipal <= assignedCovered) {
            return 0;
        }

        return coveredPrincipal - assignedCovered;
    }

    function _allocateMonadRequestCoverage(uint256 amount, uint64 claimEpoch) internal {
        if (amount == 0) {
            return;
        }

        uint256 requestCount = _pendingMonadUnstakeRequests.length;
        uint256 cursor = monadCoverageRequestCursor;

        while (cursor < requestCount && amount > 0) {
            MonadUnstakeRequestRef memory requestRef = _pendingMonadUnstakeRequests[cursor];
            MonadUnstakeRequest storage request = _monadUnstakeRequests[requestRef.user][requestRef.requestId];

            if (request.claimed || request.uncoveredAmount == 0) {
                unchecked {
                    ++cursor;
                }
                continue;
            }

            uint256 coveredAmount = request.uncoveredAmount > amount ? amount : request.uncoveredAmount;
            request.uncoveredAmount -= coveredAmount;
            totalPendingMonadUnstakeUncovered -= coveredAmount;
            amount -= coveredAmount;

            if (request.uncoveredAmount == 0) {
                request.minClaimEpoch = claimEpoch;
                unchecked {
                    ++cursor;
                }
            }
        }

        monadCoverageRequestCursor = cursor;

        if (cursor == requestCount) {
            delete _pendingMonadUnstakeRequests;
            monadCoverageRequestCursor = 0;
        }
    }

    function _undelegateFromValidator(uint64 validatorId, uint256 requestedAmount, uint64 epoch)
        internal
        returns (uint256 undelegatedAmount, uint64 claimableEpoch)
    {
        uint256 delegatedAmount = validatorDelegatedAmount[validatorId];
        if (delegatedAmount == 0 || requestedAmount == 0) {
            return (0, 0);
        }

        uint256 activeStake = delegatedAmount;
        try _monadStaking().getDelegator(validatorId, address(this)) returns (
            uint256 validatorStake,
            uint256,
            uint256,
            uint256,
            uint256,
            uint64,
            uint64
        ) {
            activeStake = validatorStake;
        } catch {}

        if (activeStake == 0) {
            return (0, 0);
        }

        undelegatedAmount = requestedAmount;
        if (undelegatedAmount > delegatedAmount) {
            undelegatedAmount = delegatedAmount;
        }
        if (undelegatedAmount > activeStake) {
            undelegatedAmount = activeStake;
        }
        if (undelegatedAmount == 0) {
            return (0, 0);
        }

        _trackValidator(validatorId);
        (bool hasWithdrawId, uint8 withdrawId) = _tryReserveWithdrawId(validatorId);
        if (!hasWithdrawId) {
            return (0, 0);
        }

        uint256 balanceBefore = address(this).balance;
        try _monadStaking().undelegate(validatorId, undelegatedAmount, withdrawId) returns (bool success) {
            if (!success) {
                _withdrawIdInUse[validatorId][withdrawId] = false;
                return (0, 0);
            }
        } catch {
            _withdrawIdInUse[validatorId][withdrawId] = false;
            return (0, 0);
        }
        _accruePrecompileYield(validatorId, balanceBefore, 0, 0);

        claimableEpoch = epoch + _monadUnstakeDelayEpochs();

        validatorDelegatedAmount[validatorId] = delegatedAmount - undelegatedAmount;
        validatorPendingUndelegateAmount[validatorId] += undelegatedAmount;
        totalDelegatedMonad -= undelegatedAmount;
        totalPendingUndelegateMonad += undelegatedAmount;

        pendingUndelegateTickets.push(
            PendingUndelegateTicket({
                validatorId: validatorId,
                withdrawId: withdrawId,
                amount: undelegatedAmount,
                claimableEpoch: claimableEpoch,
                withdrawn: false
            })
        );

        emit MonadUndelegateQueued(validatorId, withdrawId, undelegatedAmount, claimableEpoch);
    }

    function _tryReserveWithdrawId(uint64 validatorId) internal returns (bool found, uint8 withdrawId) {
        uint256 start = uint256(nextWithdrawIdByValidator[validatorId]);
        for (uint256 i = 0; i < 256; ++i) {
            uint8 candidateId = uint8((start + i) % 256);
            if (_withdrawIdInUse[validatorId][candidateId]) {
                continue;
            }

            _withdrawIdInUse[validatorId][candidateId] = true;
            nextWithdrawIdByValidator[validatorId] = uint8((uint256(candidateId) + 1) % 256);
            return (true, candidateId);
        }

        return (false, 0);
    }

    function _trackValidator(uint64 validatorId) internal {
        if (isTrackedValidator[validatorId]) {
            return;
        }

        isTrackedValidator[validatorId] = true;
        trackedValidators.push(validatorId);
    }

    function _harvestMonadValidatorRewards(uint256 maxValidators) internal {
        uint256 trackedLength = trackedValidators.length;
        if (trackedLength == 0 || maxValidators == 0) {
            return;
        }

        uint256 cursor = monadHarvestValidatorCursor;
        if (cursor >= trackedLength) {
            cursor = 0;
        }
        uint256 scanned;

        while (scanned < trackedLength && scanned < maxValidators) {
            uint64 validatorId = trackedValidators[cursor];

            // Claim from every validator the contract has staked to (all tracked validators),
            // including ones whose active delegation is currently zero — they may still hold
            // unclaimed rewards that would otherwise be stranded when the validator is compacted out.
            uint256 beforeBalance = address(this).balance;
            try _monadStaking().claimRewards(validatorId) {} catch (bytes memory reason) {
                emit MonadClaimRewardsFailed(validatorId, reason);
                unchecked {
                    ++scanned;
                    ++cursor;
                }
                if (cursor == trackedLength) {
                    cursor = 0;
                }
                continue;
            }

            uint256 afterBalance = address(this).balance;
            if (afterBalance > beforeBalance) {
                uint256 claimedAmount = afterBalance - beforeBalance;
                protocolMonadYieldAccrued += claimedAmount;
                emit MonadYieldAccrued(validatorId, claimedAmount);
            }

            unchecked {
                ++scanned;
                ++cursor;
            }
            if (cursor == trackedLength) {
                cursor = 0;
            }
        }

        monadHarvestValidatorCursor = cursor;
        if (trackedLength != 0) {
            _compactTrackedValidators(MONAD_COMPACTION_BATCH_LIMIT);
        }
    }

    function _processMaturedUndelegations(uint64 currentEpoch, uint256 maxTickets) internal returns (uint256 processed) {
        uint256 ticketsLength = pendingUndelegateTickets.length;
        if (ticketsLength == 0 || maxTickets == 0) {
            return 0;
        }

        uint256 cursor = monadPendingUndelegateCursor;
        if (cursor >= ticketsLength) {
            cursor = 0;
        }
        uint256 scanned;

        while (scanned < ticketsLength && scanned < maxTickets) {
            PendingUndelegateTicket storage ticket = pendingUndelegateTickets[cursor];
            if (ticket.withdrawn || ticket.claimableEpoch > currentEpoch) {
                unchecked {
                    ++scanned;
                    ++cursor;
                }
                if (cursor == ticketsLength) {
                    cursor = 0;
                }
                continue;
            }

            uint256 balanceBefore = address(this).balance;
            try _monadStaking().withdraw(ticket.validatorId, ticket.withdrawId) returns (bool success) {
                if (!success) {
                    unchecked {
                        ++scanned;
                        ++cursor;
                    }
                    if (cursor == ticketsLength) {
                        cursor = 0;
                    }
                    continue;
                }
            } catch {
                unchecked {
                    ++scanned;
                    ++cursor;
                }
                if (cursor == ticketsLength) {
                    cursor = 0;
                }
                continue;
            }

            // Measure what the precompile actually returned for this withdrawal. Under normal
            // operation `received >= ticket.amount` (full principal, possibly plus auto-paid
            // rewards). A `received < ticket.amount` result means delegated/unbonding stake was
            // slashed: book the surplus as yield, or record the shortfall as a solvency deficit so
            // off-chain monitoring is alerted and the owner can backfill / pause before claims drain.
            uint256 balanceAfter = address(this).balance;
            uint256 received = balanceAfter > balanceBefore ? balanceAfter - balanceBefore : 0;
            if (received >= ticket.amount) {
                uint256 surplus = received - ticket.amount;
                if (surplus > 0) {
                    protocolMonadYieldAccrued += surplus;
                    emit MonadYieldAccrued(ticket.validatorId, surplus);
                }
            } else {
                uint256 shortfall = ticket.amount - received;
                monadSlashingDeficit += shortfall;
                emit MonadWithdrawShortfall(
                    ticket.validatorId, ticket.withdrawId, ticket.amount, received, shortfall
                );
            }

            ticket.withdrawn = true;
            validatorPendingUndelegateAmount[ticket.validatorId] -= ticket.amount;
            totalPendingUndelegateMonad -= ticket.amount;
            _withdrawIdInUse[ticket.validatorId][ticket.withdrawId] = false;
            processed++;

            emit MonadWithdrawProcessed(ticket.validatorId, ticket.withdrawId, ticket.amount);

            unchecked {
                ++scanned;
                ++cursor;
            }
            if (cursor == ticketsLength) {
                cursor = 0;
            }
        }

        monadPendingUndelegateCursor = cursor;
        if (ticketsLength != 0) {
            _compactPendingUndelegateTickets(MONAD_COMPACTION_BATCH_LIMIT);
        }
    }

    function _updateMonadTargets() internal {
        CandidateScore[5] memory topCandidates;
        uint256 filled;
        uint32 nextIndex;
        bool isDone;
        uint64[] memory valIds;

        while (!isDone) {
            (isDone, nextIndex, valIds) = _monadStaking().getExecutionValidatorSet(nextIndex);

            for (uint256 i = 0; i < valIds.length; ++i) {
                uint64 validatorId = valIds[i];
                uint256 accRewardPerToken;
                uint256 commission;

                // NOTE: the 2nd return value (`uint64 flags`) encodes validator state. We do NOT
                // filter on it (e.g. to skip jailed validators) because Monad does not publish the
                // flag bit layout, and Monad has no automated slashing today
                // (docs.monad.xyz/developer-essentials/staking/staking-behavior, confirmed 2026-05),
                // so a jailed/slashed bit is not yet actionable. Guessing a bitmask risks wrongly
                // excluding healthy validators. Revisit once Monad documents flag bits / enables
                // slashing; until then `MonadWithdrawShortfall` is the slashing tripwire.
                try _monadStaking().getValidator(validatorId) returns (
                    address,
                    uint64,
                    uint256,
                    uint256 currentAccRewardPerToken,
                    uint256 currentCommission,
                    uint256,
                    uint256,
                    uint256,
                    uint256,
                    uint256,
                    bytes memory,
                    bytes memory
                ) {
                    accRewardPerToken = currentAccRewardPerToken;
                    commission = currentCommission;
                } catch {
                    continue;
                }

                uint256 score;
                ValidatorSample memory previousSample = validatorSamples[validatorId];
                if (previousSample.sampledBlock != 0 && block.number > previousSample.sampledBlock) {
                    uint256 deltaBlocks = block.number - previousSample.sampledBlock;
                    if (accRewardPerToken > previousSample.accRewardPerToken && deltaBlocks > 0) {
                        uint256 deltaAcc = accRewardPerToken - previousSample.accRewardPerToken;
                        uint256 rawScore = Math.mulDiv(deltaAcc, MONAD_SCORE_PRECISION, deltaBlocks);
                        uint256 rewardRetained =
                            commission >= MONAD_SCORE_PRECISION ? 0 : MONAD_SCORE_PRECISION - commission;
                        score = Math.mulDiv(rawScore, rewardRetained, MONAD_SCORE_PRECISION);
                    }

                    cachedValidatorScore[validatorId] = score;
                    hasCachedValidatorScore[validatorId] = true;
                }

                validatorSamples[validatorId] = ValidatorSample({
                    accRewardPerToken: accRewardPerToken,
                    sampledBlock: block.number,
                    commission: commission
                });

                CandidateScore memory candidate = CandidateScore({validatorId: validatorId, score: score, commission: commission});
                if (filled < MONAD_TARGET_COUNT) {
                    topCandidates[filled] = candidate;
                    filled++;
                    _sortTopCandidates(topCandidates, filled);
                    continue;
                }

                if (_isCandidateBetter(candidate, topCandidates[filled - 1])) {
                    topCandidates[filled - 1] = candidate;
                    _sortTopCandidates(topCandidates, filled);
                }
            }
        }

        cachedMonadObservedApy = 0;

        for (uint256 i = 0; i < MONAD_TARGET_COUNT; ++i) {
            targetValidatorIds[i] = 0;
            targetValidatorWeightsBps[i] = 0;
        }

        if (filled == 0) {
            targetValidatorCount = 0;
            emit MonadTargetsUpdated(targetValidatorIds, targetValidatorWeightsBps, targetValidatorCount);
            return;
        }

        uint256 selectedCount = filled < MONAD_TARGET_COUNT ? filled : MONAD_TARGET_COUNT;
        uint256 totalScore;
        for (uint256 i = 0; i < selectedCount; ++i) {
            totalScore += topCandidates[i].score;
            targetValidatorIds[i] = topCandidates[i].validatorId;
            _trackValidator(topCandidates[i].validatorId);
        }

        uint256 assigned;
        uint256 weightedPortfolioScore;
        if (totalScore == 0) {
            uint256 equalWeight = BPS_DENOMINATOR / selectedCount;
            uint256 remainder = BPS_DENOMINATOR - (equalWeight * selectedCount);
            for (uint256 i = 0; i < selectedCount; ++i) {
                uint256 weight = equalWeight + (i < remainder ? 1 : 0);
                targetValidatorWeightsBps[i] = SafeCast.toUint16(weight);
            }
        } else {
            for (uint256 i = 0; i < selectedCount; ++i) {
                uint256 weight = Math.mulDiv(topCandidates[i].score, BPS_DENOMINATOR, totalScore);
                targetValidatorWeightsBps[i] = SafeCast.toUint16(weight);
                assigned += weight;
                weightedPortfolioScore += Math.mulDiv(topCandidates[i].score, weight, BPS_DENOMINATOR);
            }

            if (assigned < BPS_DENOMINATOR) {
                uint256 remainder = BPS_DENOMINATOR - assigned;
                targetValidatorWeightsBps[0] += SafeCast.toUint16(remainder);
                weightedPortfolioScore += Math.mulDiv(topCandidates[0].score, remainder, BPS_DENOMINATOR);
            }

            cachedMonadObservedApy =
                Math.mulDiv(weightedPortfolioScore, MONAD_BLOCKS_PER_YEAR, MONAD_SCORE_PRECISION);
        }

        targetValidatorCount = SafeCast.toUint8(selectedCount);
        emit MonadTargetsUpdated(targetValidatorIds, targetValidatorWeightsBps, targetValidatorCount);
    }

    function _compactTrackedValidators(uint256 maxRemovals) internal {
        uint256 length = trackedValidators.length;
        if (length == 0 || maxRemovals == 0) {
            return;
        }

        uint256 index;
        uint256 removals;
        while (index < length && removals < maxRemovals) {
            uint64 validatorId = trackedValidators[index];
            if (validatorDelegatedAmount[validatorId] != 0 || validatorPendingUndelegateAmount[validatorId] != 0) {
                unchecked {
                    ++index;
                }
                continue;
            }

            uint256 lastIndex = length - 1;
            uint64 lastValidatorId = trackedValidators[lastIndex];
            trackedValidators[index] = lastValidatorId;
            trackedValidators.pop();
            isTrackedValidator[validatorId] = false;
            length = lastIndex;
            removals++;

        if (monadHarvestValidatorCursor >= length) {
            monadHarvestValidatorCursor = 0;
        }
        if (monadUndelegateValidatorCursor >= length) {
            monadUndelegateValidatorCursor = 0;
        }
        if (monadFallbackValidatorCursor >= length) {
            monadFallbackValidatorCursor = 0;
        }
        if (monadRebalanceValidatorCursor >= length) {
            monadRebalanceValidatorCursor = 0;
        }
        }
    }

    function _compactPendingUndelegateTickets(uint256 maxRemovals) internal {
        uint256 length = pendingUndelegateTickets.length;
        if (length == 0 || maxRemovals == 0) {
            return;
        }

        uint256 index;
        uint256 removals;
        while (index < length && removals < maxRemovals) {
            if (!pendingUndelegateTickets[index].withdrawn) {
                unchecked {
                    ++index;
                }
                continue;
            }

            uint256 lastIndex = length - 1;
            if (index != lastIndex) {
                pendingUndelegateTickets[index] = pendingUndelegateTickets[lastIndex];
            }
            pendingUndelegateTickets.pop();
            length = lastIndex;
            removals++;
        }

        if (monadPendingUndelegateCursor > length) {
            monadPendingUndelegateCursor = length;
        }
    }

    function _sortTopCandidates(CandidateScore[5] memory candidates, uint256 count) internal pure {
        if (count < 2) {
            return;
        }

        for (uint256 i = 1; i < count; ++i) {
            CandidateScore memory current = candidates[i];
            uint256 j = i;
            while (j > 0 && _isCandidateBetter(current, candidates[j - 1])) {
                candidates[j] = candidates[j - 1];
                j--;
            }
            candidates[j] = current;
        }
    }

    function _isCandidateBetter(CandidateScore memory left, CandidateScore memory right) internal pure returns (bool) {
        if (left.score != right.score) {
            return left.score > right.score;
        }
        if (left.commission != right.commission) {
            return left.commission < right.commission;
        }
        return left.validatorId < right.validatorId;
    }

    function _sortUnstakeCandidates(UnstakeCandidate[] memory candidates, uint256 count) internal pure {
        if (count < 2) {
            return;
        }

        for (uint256 i = 1; i < count; ++i) {
            UnstakeCandidate memory current = candidates[i];
            uint256 j = i;
            while (j > 0 && _isUnstakeCandidateWorse(current, candidates[j - 1])) {
                candidates[j] = candidates[j - 1];
                j--;
            }
            candidates[j] = current;
        }
    }

    function _isUnstakeCandidateWorse(UnstakeCandidate memory left, UnstakeCandidate memory right)
        internal
        pure
        returns (bool)
    {
        if (left.hasKnownScore != right.hasKnownScore) {
            return left.hasKnownScore;
        }
        if (!left.hasKnownScore) {
            return false;
        }
        if (left.score != right.score) {
            return left.score < right.score;
        }
        if (left.commission != right.commission) {
            return left.commission > right.commission;
        }
        return false;
    }

    function _rebalanceToMonadTargets(uint64 currentEpoch, uint256 maxValidators) internal {
        uint256 selectedCount = targetValidatorCount;
        if (selectedCount == 0) {
            return;
        }

        uint256 targetDelegatedPrincipal = _targetDelegatedPrincipal();
        uint64[] memory selectedValidators = new uint64[](selectedCount);
        uint256[] memory targetAmounts = new uint256[](selectedCount);
        uint256 remaining = targetDelegatedPrincipal;

        for (uint256 i = 0; i < selectedCount; ++i) {
            selectedValidators[i] = targetValidatorIds[i];
            if (i == selectedCount - 1) {
                targetAmounts[i] = remaining;
            } else {
                targetAmounts[i] = Math.mulDiv(targetDelegatedPrincipal, targetValidatorWeightsBps[i], BPS_DENOMINATOR);
                remaining -= targetAmounts[i];
            }
        }

        uint256 trackedLength = trackedValidators.length;
        if (trackedLength != 0 && maxValidators != 0) {
            uint256 cursor = monadRebalanceValidatorCursor;
            if (cursor >= trackedLength) {
                cursor = 0;
            }
            uint256 scanned;

            while (scanned < trackedLength && scanned < maxValidators) {
                uint64 validatorId = trackedValidators[cursor];
                uint256 delegatedAmount = validatorDelegatedAmount[validatorId];
                if (delegatedAmount != 0) {
                    uint256 targetAmount;
                    for (uint256 j = 0; j < selectedCount; ++j) {
                        if (selectedValidators[j] == validatorId) {
                            targetAmount = targetAmounts[j];
                            break;
                        }
                    }

                    if (delegatedAmount > targetAmount) {
                        _undelegateFromValidator(validatorId, delegatedAmount - targetAmount, currentEpoch);
                    }
                }

                unchecked {
                    ++scanned;
                    ++cursor;
                }
                if (cursor == trackedLength) {
                    cursor = 0;
                }
            }

            monadRebalanceValidatorCursor = cursor;
        }

        uint256 liquidAmount = _availableLiquidForActiveDelegation();
        uint256 headroom = targetDelegatedPrincipal > totalDelegatedMonad
            ? targetDelegatedPrincipal - totalDelegatedMonad
            : 0;
        if (liquidAmount > headroom) {
            liquidAmount = headroom;
        }
        if (liquidAmount == 0) {
            return;
        }

        for (uint256 i = 0; i < selectedCount && liquidAmount > 0; ++i) {
            uint64 validatorId = selectedValidators[i];
            uint256 delegatedAmount = validatorDelegatedAmount[validatorId];
            uint256 targetAmount = targetAmounts[i];
            if (delegatedAmount >= targetAmount) {
                continue;
            }

            uint256 deficit = targetAmount - delegatedAmount;
            uint256 delegateAmount = deficit > liquidAmount ? liquidAmount : deficit;
            if (delegateAmount == 0) {
                continue;
            }

            if (_delegateMonadAmountToValidator(validatorId, delegateAmount)) {
                liquidAmount -= delegateAmount;
            }
        }
    }

    function _validateImplementation(address implementation) internal view {
        if (implementation == address(0) || implementation.code.length == 0) {
            revert InvalidImplementation(implementation);
        }

        try IERC1822Proxiable(implementation).proxiableUUID() returns (bytes32 uuid) {
            if (uuid != IMPLEMENTATION_SLOT) {
                revert UnsupportedProxiableUUID(implementation, uuid);
            }
        } catch {
            revert ImplementationNotUUPSCompatible(implementation);
        }
    }

    function _upgradeManagedToken(address token, address newImplementation, bytes memory data) internal {
        _requireManagedToken(token);
        _validateImplementation(newImplementation);

        if (token.code.length == 0) {
            revert InvalidManagedToken();
        }

        address tokenOwner = Series9ManagedToken(token).owner();
        if (tokenOwner != address(this)) {
            revert UnauthorizedTokenOwner(token, tokenOwner);
        }

        Series9ManagedToken(token).upgradeToAndCall(newImplementation, data);
        emit ManagedTokenUpgraded(token, newImplementation);
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    function _resolveBatchLimit(uint256 requestedLimit, uint256 defaultLimit) internal pure returns (uint256) {
        return requestedLimit == 0 ? defaultLimit : requestedLimit;
    }

    uint256 public cachedMonadObservedApy;
    /// @dev Deprecated: retained for storage-layout and ABI stability. Set once at initialization
    /// to BPS_DENOMINATOR; no longer drives any delegation logic.
    uint256 public cachedMonadDelegatedShareBps;
    uint64 public monadUnstakeDelayEpochs;

    uint256 public accruedCreationFees;

    /// @notice Cumulative MON shortfall observed when matured Monad `withdraw` calls returned less
    /// than the booked undelegation principal (i.e. delegated stake was slashed).
    /// @dev Pure observability counter — it does NOT alter user claim amounts. Stays 0 while Monad
    /// has no slashing. If it ever rises, the contract is under-collateralized for Monad unstake
    /// claims and the owner must backfill MON (via `receive()`) or pause; reassess the claim path
    /// for proportional loss-socialization before relying on this contract under active slashing.
    uint256 public monadSlashingDeficit;

    uint256[10] private _gap;
}
