// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Initializable} from "openzeppelin-contracts/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "openzeppelin-contracts/contracts/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "openzeppelin-contracts-upgradeable/contracts/access/OwnableUpgradeable.sol";
import {ERC721Upgradeable} from "openzeppelin-contracts-upgradeable/contracts/token/ERC721/ERC721Upgradeable.sol";
import {PausableUpgradeable} from "openzeppelin-contracts-upgradeable/contracts/utils/PausableUpgradeable.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {SignatureChecker} from "openzeppelin-contracts/contracts/utils/cryptography/SignatureChecker.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Create2} from "openzeppelin-contracts/contracts/utils/Create2.sol";
import {Series9IdentityRenderer} from "./Series9IdentityRenderer.sol";
import {Series9IdentityWallet} from "./Series9IdentityWallet.sol";

/// @notice Interface for Series9Staking — stake() + reward claiming
interface ISeries9Staking {
    function stake(uint256 amount) external;
    function claimRewards() external;
    function rewards(address account) external view returns (uint256);
    function stakedBalance(address account) external view returns (uint256);
    function rewardPerTokenStored() external view returns (uint256);
    function userRewardPerTokenPaid(address account) external view returns (uint256);
    function rewardRatePerBlock() external view returns (uint256);
    function totalRewardWeight() external view returns (uint256);
    function lastUpdateBlock() external view returns (uint256);
    function rewardWeightBalance(address account) external view returns (uint256);
}

/// @title Series9Identity
/// @notice On-chain identity NFT with SVG generation and AI/human distinction
/// @dev UUPS upgradeable, ERC721 with on-chain metadata
contract Series9Identity is
    Initializable,
    ERC721Upgradeable,
    OwnableUpgradeable,
    PausableUpgradeable,
    ReentrancyGuard,
    UUPSUpgradeable,
    Series9IdentityRenderer
{
    using SafeERC20 for IERC20;
    // ─────────────────── Types ───────────────────

    enum EntityType {
        Human,
        AI
    }

    enum PaymentRequestStatus {
        None,
        Pending,
        Paid,
        Cancelled,
        Expired
    }

    struct IdentityProfile {
        string name; // Display name
        string bio; // Short bio (max 128 chars)
        EntityType entityType; // Human or AI
        uint8 hue; // HSL hue (0-255 mapped) for avatar color
        uint8 saturation; // Saturation variant
        bool verified; // Protocol-level verification
        uint64 registeredAt; // Block timestamp
    }

    struct LegacyHandleReservation {
        uint256 tokenId;
        uint64 expiresAt;
    }

    struct PaymentRequest {
        uint256 payerTokenId;
        uint256 payeeTokenId;
        address token;
        uint256 amount;
        uint64 dueAt;
        PaymentRequestStatus status;
        string memo;
    }

    // ─────────────────── State ───────────────────

    uint256 private _nextTokenId;

    mapping(uint256 => IdentityProfile) public profiles;
    mapping(address => uint256) public ownerTokenId; // 1 identity per address
    mapping(uint256 => string) public customAvatarSeed; // Deprecated: unused after avatar v2; slot kept for storage layout compatibility
    mapping(uint256 => AvatarConfig) public avatarConfig; // 8-slot character avatar customization

    uint256 private constant PRECISION = 1e18;
    address public constant NATIVE_MON = address(0);
    uint256 public constant MAX_AVATAR_SEED_BYTES = 64;
    uint8 public constant MAX_AVATAR_SLOT_OPTION = 7; // each AvatarConfig slot accepts values 0..7
    uint256 public constant MIN_HANDLE_BYTES = 3;
    uint256 public constant MAX_HANDLE_BYTES = 32;
    uint256 public constant MAX_PAYMENT_MEMO_BYTES = 128;
    uint256 public constant LEGACY_HANDLE_PRIORITY_DURATION = 30 days;
    uint256 public constant DEFAULT_HUMAN_REPUTATION_SCORE = 9;
    uint256 public constant DEFAULT_AI_REPUTATION_SCORE = 1;
    uint256 public constant MAX_REPUTATION_SCORE = 1_000_000;

    IERC20 public ser9; // SER9 token
    address public stakingContract; // Series9Staking address for auto-staking
    uint256 public aiMintFee; // 10 SER9 for AI
    uint256 public humanMintFee; // 50 SER9 for Human

    // ─────────────────── NFT Reward Distribution ───────────────────
    // Reward pool funded by claiming staking rewards on behalf of NFT holders.
    // Rewards are split by reputation score. Defaults: Human = 9, AI = 1.

    uint256 public nftRewardPerToken; // Accumulated reward per reputation score unit (PRECISION-scaled)
    mapping(address => uint256) public nftUserRewardPerTokenPaid;
    mapping(address => uint256) public nftRewards;
    mapping(uint256 => uint256) public reputationScores;
    uint256 public totalReputationScore;

    // ─────────────────── Payment Handles ───────────────────

    mapping(uint256 => string) public handles;
    mapping(bytes32 => uint256) private _tokenIdByHandleHash;
    mapping(bytes32 => LegacyHandleReservation) private _legacyHandleReservations;
    uint256 public legacyHandleReservationCursor;
    uint64 public legacyHandlePriorityDeadline;
    bool public legacyHandleReservationsFinalized;

    // ─────────────────── Payments ───────────────────

    uint256 private _nextPaymentId;
    uint256 private _nextPaymentRequestId;
    mapping(uint256 => PaymentRequest) private _paymentRequests;
    mapping(uint256 => uint256[]) private _payerPaymentRequestIds;
    mapping(uint256 => uint256[]) private _payeePaymentRequestIds;

    // ─────────────────── EIP-712 signed payment ───────────────────

    mapping(address => uint256) public paymentNonces;

    bytes32 private constant _EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant _EIP712_NAME_HASH = keccak256("Series9Identity");
    bytes32 private constant _EIP712_VERSION_HASH = keccak256("1");
    bytes32 private constant _PAY_REQUEST_AUTH_TYPEHASH =
        keccak256("PayPaymentRequestAuthorization(uint256 requestId,uint256 nonce,uint256 deadline)");

    /// @notice Emitted when AI mint fee is changed
    event AIMintFeeUpdated(uint256 previousFee, uint256 newFee);
    /// @notice Emitted when Human mint fee is changed
    event HumanMintFeeUpdated(uint256 previousFee, uint256 newFee);
    /// @notice Emitted when staking contract is changed
    event StakingContractUpdated(address indexed previousStaking, address indexed newStaking);
    /// @notice Emitted when a profile is verified
    event ProfileVerified(uint256 indexed tokenId, bool indexed verified);
    /// @notice Emitted when a profile is updated
    event ProfileUpdated(uint256 indexed tokenId, string name, string bio, EntityType entityType);
    /// @notice Emitted when SER9 is staked on behalf of identity minter
    event IdentityStaked(address indexed user, uint256 amount);
    /// @notice Emitted when staking rewards are collected from the staking contract
    event StakingRewardsCollected(uint256 amount);
    /// @notice Emitted when an NFT holder claims their reward share
    event NFTRewardClaimed(address indexed user, uint256 amount);
    /// @notice Emitted when a token's reputation score is changed
    event ReputationScoreUpdated(uint256 indexed tokenId, uint256 previousScore, uint256 newScore);
    /// @notice Emitted when a payment handle is changed
    event IdentityHandleUpdated(uint256 indexed tokenId, string previousHandle, string newHandle);
    /// @notice Emitted when a token's avatar configuration is changed
    event AvatarUpdated(uint256 indexed tokenId, AvatarConfig config);
    /// @notice Emitted when a legacy display name reserves a payment handle
    event LegacyHandleReserved(bytes32 indexed handleHash, string handle, uint256 indexed tokenId, uint64 expiresAt);
    /// @notice Emitted when all legacy handle reservations have been scanned
    event LegacyHandleReservationsFinalized(uint256 scannedUntilTokenId);
    /// @notice Emitted when an identity payment is sent
    event IdentityPaymentSent(
        uint256 indexed paymentId,
        uint256 indexed payerTokenId,
        uint256 indexed payeeTokenId,
        address token,
        address from,
        address to,
        uint256 amount,
        string memo
    );
    /// @notice Emitted when a payment request is created
    event PaymentRequestCreated(
        uint256 indexed requestId,
        uint256 indexed payerTokenId,
        uint256 indexed payeeTokenId,
        address token,
        uint256 amount,
        uint64 dueAt,
        string memo
    );
    /// @notice Emitted when a payment request is paid
    event PaymentRequestPaid(uint256 indexed requestId, uint256 indexed paymentId);
    /// @notice Emitted when a payment request is paid via a signed authorization from the payer.
    event PaymentRequestPaidWithSig(
        uint256 indexed requestId,
        uint256 indexed paymentId,
        address indexed signer,
        address relayer,
        uint256 nonce
    );
    /// @notice Emitted when a payment request is cancelled
    event PaymentRequestCancelled(uint256 indexed requestId, address indexed caller);
    /// @notice Emitted when an identity's smart-account wallet is created
    event WalletCreated(uint256 indexed tokenId, address indexed wallet, address indexed owner);
    /// @notice Emitted when a wallet implementation is allowlisted as an upgrade target with its version
    event WalletImplApprovalSet(address indexed impl, uint256 version);
    /// @notice Emitted when a wallet implementation is revoked as a future upgrade target
    event WalletImplRevoked(address indexed impl);
    /// @notice Emitted when an identity transfer is initiated
    event IdentityTransferInitiated(uint256 indexed tokenId, address indexed from, address indexed to);
    /// @notice Emitted when the recipient accepts a transfer (the 6-hour delay starts)
    event IdentityTransferAccepted(uint256 indexed tokenId, address indexed to, uint64 readyAt);
    /// @notice Emitted when a transfer is cancelled by either party
    event IdentityTransferCancelled(uint256 indexed tokenId, address indexed caller);
    /// @notice Emitted when a transfer completes and the identity moves
    event IdentityTransferCompleted(uint256 indexed tokenId, address indexed from, address indexed to);

    // ─────────────────── Errors ───────────────────

    error AlreadyHasIdentity(address account);
    error InsufficientMintAllowance();
    error NameTooLong();
    error BioTooLong();
    error NotTokenOwner();
    error InvalidHue();
    error ZeroSer9Address();
    error InvalidStakingContract();
    error StakingFailed();
    error NotNFTHolder();
    error NoNFTRewards();
    error InvalidReputationScore();
    error NonexistentToken();
    error AvatarSeedTooLong();
    error InvalidAvatarSlot();
    error PaymentNotInitialized();
    error LegacyHandleReservationsNotFinalized();
    error InvalidHandle();
    error HandleAlreadyTaken();
    error HandleReserved(uint256 reservedTokenId, uint64 expiresAt);
    error UnknownHandle();
    error InvalidPaymentAmount();
    error PaymentMemoTooLong();
    error SelfPayment();
    error InvalidNativeValue();
    error NativePaymentFailed();
    error InvalidPaymentRequest();
    error PaymentRequestNotPending();
    error UnauthorizedPaymentActor();
    error InvalidPaymentDueAt();
    error PaymentSignatureExpired();
    error InvalidPaymentSignature();
    error NoIdentity();
    error WalletAlreadyCreated();
    error WalletNotConfigured();
    error WalletImplNotApproved();
    error WalletImplAlreadyApproved();
    error WalletDowngradeNotAllowed();
    error WalletFrozenDuringTransfer();
    error ApprovalsDisabled();
    error InvalidTransferRecipient();
    error TransferAlreadyActive();
    error TransferNotPending();
    error TransferNotAccepted();
    error NoActiveTransfer();
    error UnauthorizedTransferActor();
    error TransferDelayNotElapsed(uint64 readyAt);
    error TransferRestricted();

    // ─────────────────── Init ───────────────────

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address initialOwner,
        address ser9Token,
        address stakingContract_,
        uint256 initialAIMintFee,
        uint256 initialHumanMintFee
    ) external initializer {
        if (ser9Token == address(0)) revert ZeroSer9Address();
        if (stakingContract_ == address(0) || stakingContract_.code.length == 0) revert InvalidStakingContract();

        __ERC721_init("Series9 Identity", "S9ID");
        __Ownable_init(initialOwner);
        __Pausable_init();

        ser9 = IERC20(ser9Token);
        stakingContract = stakingContract_;
        aiMintFee = initialAIMintFee;
        humanMintFee = initialHumanMintFee;
        _nextTokenId = 1;
        _nextPaymentId = 1;
        _nextPaymentRequestId = 1;
        legacyHandleReservationCursor = 1;
        legacyHandleReservationsFinalized = true;
    }

    /// @notice Initialize payment storage after upgrading an existing identity proxy.
    function initializePayment() external reinitializer(2) onlyOwner {
        if (_nextPaymentId == 0) {
            _nextPaymentId = 1;
        }
        if (_nextPaymentRequestId == 0) {
            _nextPaymentRequestId = 1;
        }
        legacyHandleReservationCursor = 1;
        // Unix timestamps plus a 30 day reservation window fit comfortably in uint64.
        // forge-lint: disable-next-line(unsafe-typecast)
        legacyHandlePriorityDeadline = uint64(block.timestamp + LEGACY_HANDLE_PRIORITY_DURATION);
        legacyHandleReservationsFinalized = false;
    }

    // ─────────────────── NFT Reward Distribution ───────────────────

    /// @notice Claim accumulated SER9 staking rewards from Series9Staking
    ///         and distribute them pro-rata to NFT holders.
    ///         Anyone can call this — it's a public good function.
    function collectStakingRewards() external whenNotPaused nonReentrant {
        uint256 balanceBefore = IERC20(ser9).balanceOf(address(this));
        ISeries9Staking(stakingContract).claimRewards();
        uint256 received = IERC20(ser9).balanceOf(address(this)) - balanceBefore;

        if (received > 0) {
            uint256 totalScore = _ensureTotalReputationScore();
            if (totalScore > 0) {
                nftRewardPerToken += (received * PRECISION) / totalScore;
            }
            emit StakingRewardsCollected(received);
        }
    }

    /// @notice Claim your share of staking rewards as an NFT holder
    function claimNFTRewards() external whenNotPaused nonReentrant {
        uint256 rewardPerToken = nftRewardPerToken;
        uint256 reward = nftRewards[msg.sender];
        uint256 tid = ownerTokenId[msg.sender];
        if (tid != 0) {
            uint256 accumulated = rewardPerToken - nftUserRewardPerTokenPaid[msg.sender];
            reward += (accumulated * _reputationScore(tid)) / PRECISION;
            nftUserRewardPerTokenPaid[msg.sender] = rewardPerToken;
        } else if (reward == 0) {
            revert NotNFTHolder();
        }

        if (reward == 0) revert NoNFTRewards();

        nftRewards[msg.sender] = 0;

        IERC20(ser9).safeTransfer(msg.sender, reward);

        emit NFTRewardClaimed(msg.sender, reward);
    }

    /// @notice View pending NFT reward for an account
    function pendingNFTRewards(address account) external view returns (uint256) {
        uint256 tid = ownerTokenId[account];
        if (tid == 0) return nftRewards[account];

        uint256 accumulated = nftRewardPerToken - nftUserRewardPerTokenPaid[account];
        return nftRewards[account] + ((accumulated * _reputationScore(tid)) / PRECISION);
    }

    /// @notice View unclaimed staking rewards sitting in the staking contract
    function pendingStakingRewards() external view returns (uint256) {
        return ISeries9Staking(stakingContract).rewards(address(this));
    }

    // ─────────────────── Mint ───────────────────

    /// @notice Mint a new identity NFT — one per address, SER9 fee auto-staked
    function mintIdentity(string calldata name, string calldata bio, EntityType entityType, uint8 hue, uint8 saturation)
        external
        whenNotPaused
        nonReentrant
        returns (uint256)
    {
        return _mintIdentity(name, bio, entityType, hue, saturation);
    }

    /// @notice Mint a new identity NFT and register a payment handle in one transaction.
    function mintIdentityWithHandle(
        string calldata name,
        string calldata bio,
        EntityType entityType,
        uint8 hue,
        uint8 saturation,
        string calldata handle
    ) external whenNotPaused nonReentrant returns (uint256 tokenId) {
        _requireHandleRegistrationReady();
        _validateAndHashHandle(handle);

        tokenId = _mintIdentity(name, bio, entityType, hue, saturation);
        _setHandle(tokenId, handle);
    }

    function _mintIdentity(
        string calldata name,
        string calldata bio,
        EntityType entityType,
        uint8 hue,
        uint8 saturation
    ) internal returns (uint256) {
        if (ownerTokenId[msg.sender] != 0) revert AlreadyHasIdentity(msg.sender);
        if (bytes(name).length > 32) revert NameTooLong();
        if (bytes(bio).length > 128) revert BioTooLong();

        // Determine fee based on entity type
        uint256 fee = entityType == EntityType.AI ? aiMintFee : humanMintFee;

        if (fee > 0) {
            uint256 balanceBefore = ser9.balanceOf(address(this));

            // Transfer SER9 from user to this contract
            ser9.safeTransferFrom(msg.sender, address(this), fee);

            // Approve staking contract to pull SER9
            ser9.forceApprove(stakingContract, fee);

            // Stake SER9 on behalf of the user via staking contract
            // The staking contract will pull SER9 from this contract via transferFrom
            ISeries9Staking(stakingContract).stake(fee);
            ser9.forceApprove(stakingContract, 0);

            if (ser9.balanceOf(address(this)) > balanceBefore) revert StakingFailed();
        }

        uint256 tokenId = _nextTokenId++;

        profiles[tokenId] = IdentityProfile({
            name: name,
            bio: bio,
            entityType: entityType,
            hue: hue,
            saturation: saturation,
            verified: false,
            registeredAt: uint64(block.timestamp)
        });
        reputationScores[tokenId] = _defaultReputationScore(entityType);

        _safeMint(msg.sender, tokenId);

        _createWalletIfConfigured(tokenId);

        emit IdentityStaked(msg.sender, fee);

        return tokenId;
    }

    // ─────────────────── Profile Updates ───────────────────

    /// @notice Update profile fields (only token owner)
    function updateProfile(uint256 tokenId, string calldata name, string calldata bio, uint8 hue, uint8 saturation)
        external
        whenNotPaused
    {
        if (ownerOf(tokenId) != msg.sender) revert NotTokenOwner();
        if (bytes(name).length > 32) revert NameTooLong();
        if (bytes(bio).length > 128) revert BioTooLong();

        IdentityProfile storage p = profiles[tokenId];
        p.name = name;
        p.bio = bio;
        p.hue = hue;
        p.saturation = saturation;

        emit ProfileUpdated(tokenId, name, bio, p.entityType);
    }

    /// @notice Set a custom avatar seed for advanced generative art
    /// @dev Deprecated: retained for backward compatibility; the active renderer ignores this value.
    function setCustomAvatarSeed(uint256 tokenId, string calldata seed) external whenNotPaused {
        if (ownerOf(tokenId) != msg.sender) revert NotTokenOwner();
        if (bytes(seed).length > MAX_AVATAR_SEED_BYTES) revert AvatarSeedTooLong();
        customAvatarSeed[tokenId] = seed;
    }

    /// @notice Update the 8-slot character avatar for a token. Each slot accepts values 0..MAX_AVATAR_SLOT_OPTION.
    function setAvatar(uint256 tokenId, AvatarConfig calldata config) external whenNotPaused {
        if (ownerOf(tokenId) != msg.sender) revert NotTokenOwner();
        _validateAvatarConfig(config);
        avatarConfig[tokenId] = config;
        emit AvatarUpdated(tokenId, config);
    }

    function _validateAvatarConfig(AvatarConfig calldata c) internal pure {
        if (
            c.skinTone > MAX_AVATAR_SLOT_OPTION || c.hairStyle > MAX_AVATAR_SLOT_OPTION
                || c.hairColor > MAX_AVATAR_SLOT_OPTION || c.eyes > MAX_AVATAR_SLOT_OPTION
                || c.mouth > MAX_AVATAR_SLOT_OPTION || c.outfit > MAX_AVATAR_SLOT_OPTION
                || c.accessory > MAX_AVATAR_SLOT_OPTION || c.background > MAX_AVATAR_SLOT_OPTION
        ) revert InvalidAvatarSlot();
    }

    // ─────────────────── Payment Handles ───────────────────

    /// @notice Register or update the payment handle for an identity.
    function setHandle(uint256 tokenId, string calldata handle) external whenNotPaused {
        if (ownerOf(tokenId) != msg.sender) revert NotTokenOwner();
        _requireHandleRegistrationReady();
        _setHandle(tokenId, handle);
    }

    /// @notice Deterministically seed legacy display-name handle reservations in bounded batches.
    function seedLegacyHandleReservations(uint256 maxTokens) external whenNotPaused {
        _requirePaymentInitialized();
        if (legacyHandleReservationsFinalized) {
            return;
        }

        uint256 cursor = legacyHandleReservationCursor;
        if (cursor == 0) {
            cursor = 1;
        }

        uint256 processed;
        while (cursor < _nextTokenId && processed < maxTokens) {
            if (_ownerOf(cursor) != address(0)) {
                string memory handle = _legacyHandleSlug(profiles[cursor].name);
                if (bytes(handle).length != 0) {
                    bytes32 handleHash = _handleHash(handle);
                    if (_legacyHandleReservations[handleHash].tokenId == 0 && _tokenIdByHandleHash[handleHash] == 0) {
                        _legacyHandleReservations[handleHash] =
                            LegacyHandleReservation({tokenId: cursor, expiresAt: legacyHandlePriorityDeadline});
                        emit LegacyHandleReserved(handleHash, handle, cursor, legacyHandlePriorityDeadline);
                    }
                }
            }

            unchecked {
                cursor++;
                processed++;
            }
        }

        legacyHandleReservationCursor = cursor;
        if (cursor >= _nextTokenId) {
            legacyHandleReservationsFinalized = true;
            emit LegacyHandleReservationsFinalized(cursor);
        }
    }

    // ─────────────────── Payments ───────────────────

    /// @notice Pay the current owner of a SERIES9 handle with ERC20 tokens or native MON.
    function payToHandle(address token, string calldata recipientHandle, uint256 amount, string calldata memo)
        external
        payable
        whenNotPaused
        nonReentrant
        returns (uint256 paymentId)
    {
        _requirePaymentInitialized();
        _validatePaymentInputs(amount, memo);

        uint256 payerTokenId = ownerTokenId[msg.sender];
        if (payerTokenId == 0) revert NotNFTHolder();

        uint256 payeeTokenId = _requireTokenIdForHandle(recipientHandle);
        if (payerTokenId == payeeTokenId) revert SelfPayment();

        address recipient = ownerOf(payeeTokenId);
        paymentId = _nextPaymentId++;

        _transferPaymentAsset(token, msg.sender, payable(recipient), amount);

        emit IdentityPaymentSent(paymentId, payerTokenId, payeeTokenId, token, msg.sender, recipient, amount, memo);
    }

    /// @notice Create a payment request from the caller's identity to another identity handle.
    function createPaymentRequest(
        string calldata payerHandle,
        address token,
        uint256 amount,
        uint64 dueAt,
        string calldata memo
    ) external whenNotPaused nonReentrant returns (uint256 requestId) {
        _requirePaymentInitialized();
        _validatePaymentInputs(amount, memo);
        if (dueAt != 0 && dueAt <= block.timestamp) revert InvalidPaymentDueAt();

        uint256 payeeTokenId = ownerTokenId[msg.sender];
        if (payeeTokenId == 0) revert NotNFTHolder();

        uint256 payerTokenId = _requireTokenIdForHandle(payerHandle);
        if (payerTokenId == payeeTokenId) revert SelfPayment();

        requestId = _nextPaymentRequestId++;
        _paymentRequests[requestId] = PaymentRequest({
            payerTokenId: payerTokenId,
            payeeTokenId: payeeTokenId,
            token: token,
            amount: amount,
            dueAt: dueAt,
            status: PaymentRequestStatus.Pending,
            memo: memo
        });

        _payerPaymentRequestIds[payerTokenId].push(requestId);
        _payeePaymentRequestIds[payeeTokenId].push(requestId);

        emit PaymentRequestCreated(requestId, payerTokenId, payeeTokenId, token, amount, dueAt, memo);
    }

    /// @notice Pay an outstanding payment request. ERC20 requests require prior approval; MON requests require msg.value.
    function payPaymentRequest(uint256 requestId)
        external
        payable
        whenNotPaused
        nonReentrant
        returns (uint256 paymentId)
    {
        _requirePaymentInitialized();
        PaymentRequest storage request = _paymentRequests[requestId];
        if (request.status == PaymentRequestStatus.None) revert InvalidPaymentRequest();
        if (_effectivePaymentRequestStatus(request) != PaymentRequestStatus.Pending) revert PaymentRequestNotPending();

        if (ownerTokenId[msg.sender] != request.payerTokenId) revert UnauthorizedPaymentActor();

        address recipient = ownerOf(request.payeeTokenId);
        paymentId = _nextPaymentId++;
        request.status = PaymentRequestStatus.Paid;

        _transferPaymentAsset(request.token, msg.sender, payable(recipient), request.amount);

        emit IdentityPaymentSent(
            paymentId,
            request.payerTokenId,
            request.payeeTokenId,
            request.token,
            msg.sender,
            recipient,
            request.amount,
            request.memo
        );
        emit PaymentRequestPaid(requestId, paymentId);
    }

    /// @notice Pay an outstanding payment request using an EIP-712 signature from the request's
    ///         authorized payer. The signature delegates execution to msg.sender, who supplies the funds
    ///         (ERC20 allowance or native MON value). Useful for paying on behalf of the request's payer.
    /// @param requestId Outstanding payment request id.
    /// @param nonce Off-chain nonce; must equal `paymentNonces[signer]` at execution time.
    /// @param deadline Unix timestamp after which the signature is no longer valid.
    /// @param signature 65-byte ECDSA signature over the EIP-712 digest.
    function payPaymentRequestWithSig(uint256 requestId, uint256 nonce, uint256 deadline, bytes calldata signature)
        external
        payable
        whenNotPaused
        nonReentrant
        returns (uint256 paymentId)
    {
        _requirePaymentInitialized();
        if (block.timestamp > deadline) revert PaymentSignatureExpired();

        PaymentRequest storage request = _paymentRequests[requestId];
        if (request.status == PaymentRequestStatus.None) revert InvalidPaymentRequest();
        if (_effectivePaymentRequestStatus(request) != PaymentRequestStatus.Pending) revert PaymentRequestNotPending();

        address signer = _consumePayPaymentRequestSig(requestId, nonce, deadline, signature, request.payerTokenId);

        address recipient = ownerOf(request.payeeTokenId);
        paymentId = _nextPaymentId++;
        request.status = PaymentRequestStatus.Paid;

        _transferPaymentAsset(request.token, msg.sender, payable(recipient), request.amount);

        emit IdentityPaymentSent(
            paymentId,
            request.payerTokenId,
            request.payeeTokenId,
            request.token,
            msg.sender,
            recipient,
            request.amount,
            request.memo
        );
        emit PaymentRequestPaid(requestId, paymentId);
        emit PaymentRequestPaidWithSig(requestId, paymentId, signer, msg.sender, nonce);
    }

    /// @notice Cancel an outstanding payment request. Either current payer or current payee identity owner may cancel.
    function cancelPaymentRequest(uint256 requestId) external whenNotPaused nonReentrant {
        _requirePaymentInitialized();
        PaymentRequest storage request = _paymentRequests[requestId];
        if (request.status == PaymentRequestStatus.None) revert InvalidPaymentRequest();
        if (_effectivePaymentRequestStatus(request) != PaymentRequestStatus.Pending) revert PaymentRequestNotPending();

        uint256 callerTokenId = ownerTokenId[msg.sender];
        if (callerTokenId != request.payerTokenId && callerTokenId != request.payeeTokenId) {
            revert UnauthorizedPaymentActor();
        }

        request.status = PaymentRequestStatus.Cancelled;
        emit PaymentRequestCancelled(requestId, msg.sender);
    }

    // ─────────────────── Admin ───────────────────

    function verify(uint256 tokenId, bool status) external onlyOwner {
        if (_ownerOf(tokenId) == address(0)) revert NonexistentToken();
        profiles[tokenId].verified = status;
        emit ProfileVerified(tokenId, status);
    }

    function setReputationScore(uint256 tokenId, uint256 newScore) external onlyOwner {
        if (_ownerOf(tokenId) == address(0)) revert NonexistentToken();
        if (newScore == 0 || newScore > MAX_REPUTATION_SCORE) revert InvalidReputationScore();

        uint256 previousScore = _reputationScore(tokenId);
        if (previousScore == newScore) {
            return;
        }

        uint256 totalScore = _ensureTotalReputationScore();
        address tokenOwner = ownerOf(tokenId);
        _accrueNFTReward(tokenOwner);

        reputationScores[tokenId] = newScore;
        totalReputationScore = totalScore + newScore - previousScore;

        emit ReputationScoreUpdated(tokenId, previousScore, newScore);
    }

    function setAIMintFee(uint256 newFee) external onlyOwner {
        uint256 prev = aiMintFee;
        aiMintFee = newFee;
        emit AIMintFeeUpdated(prev, newFee);
    }

    function setHumanMintFee(uint256 newFee) external onlyOwner {
        uint256 prev = humanMintFee;
        humanMintFee = newFee;
        emit HumanMintFeeUpdated(prev, newFee);
    }

    function setStakingContract(address newStaking) external onlyOwner {
        if (newStaking == address(0) || newStaking.code.length == 0) revert InvalidStakingContract();
        address prev = stakingContract;
        stakingContract = newStaking;
        emit StakingContractUpdated(prev, newStaking);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    // ─────────────────── View Helpers ───────────────────

    /// @notice Check if an address has a registered identity
    function hasIdentity(address account) external view returns (bool) {
        return ownerTokenId[account] != 0;
    }

    /// @notice Get the entity type for a token
    function getEntityType(uint256 tokenId) external view returns (EntityType) {
        if (_ownerOf(tokenId) == address(0)) revert NonexistentToken();
        return profiles[tokenId].entityType;
    }

    function effectiveReputationScore(uint256 tokenId) external view returns (uint256) {
        if (_ownerOf(tokenId) == address(0)) revert NonexistentToken();
        return _reputationScore(tokenId);
    }

    function reputationScoreOf(address account) external view returns (uint256) {
        uint256 tid = ownerTokenId[account];
        if (tid == 0) return 0;
        return _reputationScore(tid);
    }

    /// @notice Check if an address is an AI entity
    function isAI(address account) external view returns (bool) {
        uint256 tid = ownerTokenId[account];
        if (tid == 0) return false;
        return profiles[tid].entityType == EntityType.AI;
    }

    /// @notice Check if an address is a human entity
    function isHuman(address account) external view returns (bool) {
        uint256 tid = ownerTokenId[account];
        if (tid == 0) return false;
        return profiles[tid].entityType == EntityType.Human;
    }

    /// @notice Check if a token is verified
    function isVerified(uint256 tokenId) external view returns (bool) {
        if (_ownerOf(tokenId) == address(0)) revert NonexistentToken();
        return profiles[tokenId].verified;
    }

    /// @notice Resolve address → display name
    function nameOf(address account) external view returns (string memory) {
        uint256 tid = ownerTokenId[account];
        if (tid == 0) return "";
        return profiles[tid].name;
    }

    /// @notice Get the registered payment handle for an identity token.
    function handleOf(uint256 tokenId) external view returns (string memory) {
        if (_ownerOf(tokenId) == address(0)) revert NonexistentToken();
        return handles[tokenId];
    }

    /// @notice Resolve a payment handle to an identity token id.
    function tokenIdOfHandle(string calldata handle) external view returns (uint256) {
        return _tokenIdByHandleHash[_handleHash(handle)];
    }

    /// @notice Resolve a payment handle to the current identity owner.
    function ownerOfHandle(string calldata handle) external view returns (address) {
        uint256 tokenId = _tokenIdByHandleHash[_handleHash(handle)];
        if (tokenId == 0) {
            return address(0);
        }
        return ownerOf(tokenId);
    }

    /// @notice View a legacy handle reservation.
    function legacyHandleReservationOf(string calldata handle)
        external
        view
        returns (uint256 tokenId, uint64 expiresAt, bool active)
    {
        LegacyHandleReservation storage reservation = _legacyHandleReservations[_handleHash(handle)];
        tokenId = reservation.tokenId;
        expiresAt = reservation.expiresAt;
        active = tokenId != 0 && block.timestamp <= expiresAt;
    }

    /// @notice View payment request details.
    function paymentRequest(uint256 requestId)
        external
        view
        returns (
            uint256 payerTokenId,
            uint256 payeeTokenId,
            address token,
            uint256 amount,
            uint64 dueAt,
            PaymentRequestStatus status,
            string memory memo
        )
    {
        PaymentRequest storage request = _paymentRequests[requestId];
        if (request.status == PaymentRequestStatus.None) revert InvalidPaymentRequest();
        return (
            request.payerTokenId,
            request.payeeTokenId,
            request.token,
            request.amount,
            request.dueAt,
            request.status,
            request.memo
        );
    }

    /// @notice View payment request status with expiry applied.
    function effectivePaymentRequestStatus(uint256 requestId) external view returns (PaymentRequestStatus) {
        PaymentRequest storage request = _paymentRequests[requestId];
        if (request.status == PaymentRequestStatus.None) revert InvalidPaymentRequest();
        return _effectivePaymentRequestStatus(request);
    }

    function payerPaymentRequestCount(uint256 tokenId) external view returns (uint256) {
        return _payerPaymentRequestIds[tokenId].length;
    }

    function payerPaymentRequestIdAt(uint256 tokenId, uint256 index) external view returns (uint256) {
        return _payerPaymentRequestIds[tokenId][index];
    }

    function payeePaymentRequestCount(uint256 tokenId) external view returns (uint256) {
        return _payeePaymentRequestIds[tokenId].length;
    }

    function payeePaymentRequestIdAt(uint256 tokenId, uint256 index) external view returns (uint256) {
        return _payeePaymentRequestIds[tokenId][index];
    }

    // ─────────────────── Identity wallet factory + registry ───────────────────

    /// @notice One-time setup of the wallet factory after upgrading the identity proxy.
    /// @param bootstrapImpl The Series9IdentityWallet implementation used as every wallet proxy's birth logic.
    /// @dev `walletImplementation` has no setter — it is frozen here so every wallet's CREATE2 address
    ///      (derived from the proxy init-code) stays permanently deterministic. Newer wallet logic is
    ///      introduced only as an allowlisted upgrade target via {setWalletImplApproved}.
    function initializeWalletFactory(address bootstrapImpl) external reinitializer(3) onlyOwner {
        // reinitializer(3) only guarantees _initialized < 3; it does NOT guarantee the payment reinitializer(2)
        // ran. Require it explicitly so a proxy can never jump 1 -> 3 and permanently brick the payment module.
        _requirePaymentInitialized();
        if (bootstrapImpl == address(0) || bootstrapImpl.code.length == 0) revert WalletNotConfigured();
        walletImplementation = bootstrapImpl;
        walletImplVersion[bootstrapImpl] = 1;
        emit WalletImplApprovalSet(bootstrapImpl, 1);
    }

    /// @notice Allowlist a wallet implementation as an upgrade target with a monotonic version.
    /// @param impl The Series9IdentityWallet implementation.
    /// @param version Strictly-positive version; higher = newer. Holders may upgrade only to a strictly higher
    ///        version than their wallet currently runs (no downgrade).
    /// @dev A version is immutable once set — re-approving the same impl reverts — so the no-downgrade baseline
    ///      (read live from `walletImplVersion[currentImpl]` during an upgrade) can never be lowered by
    ///      re-numbering. Use {revokeWalletImpl} to retire a target without touching its baseline version.
    function setWalletImplApproved(address impl, uint256 version) external onlyOwner {
        if (impl == address(0) || impl.code.length == 0) revert WalletNotConfigured();
        if (version == 0) revert WalletImplNotApproved();
        if (walletImplVersion[impl] != 0) revert WalletImplAlreadyApproved();
        walletImplVersion[impl] = version;
        emit WalletImplApprovalSet(impl, version);
    }

    /// @notice Revoke a wallet implementation as a future upgrade target.
    /// @dev Only blocks new upgrades TO `impl`; it leaves `walletImplVersion[impl]` intact so a wallet already
    ///      running it keeps an honest no-downgrade baseline and stays fully operable.
    function revokeWalletImpl(address impl) external onlyOwner {
        walletImplRevoked[impl] = true;
        emit WalletImplRevoked(impl);
    }

    /// @notice Deploy the smart-account wallet for an identity at its deterministic address.
    /// @dev Permissionless: the address is fixed by `tokenId`, so anyone may trigger creation. New mints
    ///      auto-create; this also covers identities minted before the factory existed.
    function createWallet(uint256 tokenId) public returns (address wallet) {
        address tokenOwner = _ownerOf(tokenId);
        if (tokenOwner == address(0)) revert NonexistentToken();
        if (walletOf[tokenId] != address(0)) revert WalletAlreadyCreated();
        if (walletImplementation == address(0)) revert WalletNotConfigured();

        wallet = Create2.deploy(0, bytes32(tokenId), _walletProxyInitCode(tokenId));
        walletOf[tokenId] = wallet;
        emit WalletCreated(tokenId, wallet, tokenOwner);
    }

    /// @notice The wallet address an identity has (or would have, once created).
    /// @dev Reverts before the factory is configured so callers never receive an address derived from a
    ///      zero implementation (which would not match the wallet that {createWallet} eventually deploys).
    function predictWalletAddress(uint256 tokenId) external view returns (address) {
        if (walletImplementation == address(0)) revert WalletNotConfigured();
        return Create2.computeAddress(bytes32(tokenId), keccak256(_walletProxyInitCode(tokenId)));
    }

    /// @dev Proxy init-code is deterministic per tokenId (fixed bootstrap impl + initialize calldata), so the
    ///      CREATE2 wallet address is stable and predictable. The proxy initializes in its own constructor.
    function _walletProxyInitCode(uint256 tokenId) internal view returns (bytes memory) {
        bytes memory initData = abi.encodeCall(Series9IdentityWallet.initialize, (address(this), tokenId));
        return abi.encodePacked(type(ERC1967Proxy).creationCode, abi.encode(walletImplementation, initData));
    }

    function _createWalletIfConfigured(uint256 tokenId) internal {
        if (walletImplementation != address(0) && walletOf[tokenId] == address(0)) {
            createWallet(tokenId);
        }
    }

    // ─────────────────── Wallet authorization (called by wallets) ───────────────────

    /// @notice Authorize an operation on the wallet bound to `tokenId`; reverts otherwise.
    /// @dev Authority is the NFT: only the current `ownerOf(tokenId)` passes, and never while a transfer
    ///      is freezing the wallet.
    function authorizeWalletCall(uint256 tokenId, address operator) external view {
        if (_ownerOf(tokenId) != operator) revert NotTokenOwner();
        _requireWalletNotFrozen(tokenId);
    }

    /// @notice Authorize a wallet logic upgrade; reverts otherwise.
    /// @dev Owner-triggered (NFT holder), allowlisted target, strictly-higher version (no downgrade),
    ///      and blocked during a transfer freeze.
    function authorizeWalletUpgrade(uint256 tokenId, address operator, address currentImpl, address newImpl)
        external
        view
    {
        if (_ownerOf(tokenId) != operator) revert NotTokenOwner();
        uint256 newVersion = walletImplVersion[newImpl];
        if (newVersion == 0 || walletImplRevoked[newImpl]) revert WalletImplNotApproved();
        if (newVersion <= walletImplVersion[currentImpl]) revert WalletDowngradeNotAllowed();
        _requireWalletNotFrozen(tokenId);
    }

    function _requireWalletNotFrozen(uint256 tokenId) internal view {
        TransferStatus status = _identityTransfers[tokenId].status;
        if (status == TransferStatus.Pending || status == TransferStatus.Accepted) {
            revert WalletFrozenDuringTransfer();
        }
    }

    // ─────────────────── Escrowed identity transfer ───────────────────

    /// @notice Begin transferring your identity (and its wallet) to `to`. The recipient must accept, after
    ///         which a 6-hour delay must elapse before finalize. The wallet freezes immediately.
    function initiateIdentityTransfer(address to) external whenNotPaused {
        uint256 tokenId = ownerTokenId[msg.sender];
        if (tokenId == 0) revert NoIdentity();
        if (to == address(0) || to == msg.sender) revert InvalidTransferRecipient();
        if (ownerTokenId[to] != 0) revert AlreadyHasIdentity(to);

        TransferStatus status = _identityTransfers[tokenId].status;
        if (status == TransferStatus.Pending || status == TransferStatus.Accepted) revert TransferAlreadyActive();

        _identityTransfers[tokenId] =
            IdentityTransfer({from: msg.sender, to: to, acceptedAt: 0, status: TransferStatus.Pending});
        emit IdentityTransferInitiated(tokenId, msg.sender, to);
    }

    /// @notice Recipient accepts a pending transfer, starting the 6-hour delay.
    function acceptIdentityTransfer(uint256 tokenId) external whenNotPaused {
        IdentityTransfer storage t = _identityTransfers[tokenId];
        if (t.status != TransferStatus.Pending) revert TransferNotPending();
        if (msg.sender != t.to) revert UnauthorizedTransferActor();
        if (ownerTokenId[t.to] != 0) revert AlreadyHasIdentity(t.to);

        // Unix timestamps fit comfortably in uint64.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint64 acceptedAt = uint64(block.timestamp);
        t.acceptedAt = acceptedAt;
        t.status = TransferStatus.Accepted;
        emit IdentityTransferAccepted(tokenId, t.to, acceptedAt + IDENTITY_TRANSFER_DELAY);
    }

    /// @notice Cancel a transfer. Either the sender or the recipient may cancel any time before completion.
    /// @dev Callable while paused so parties can always unwind.
    function cancelIdentityTransfer(uint256 tokenId) external {
        IdentityTransfer storage t = _identityTransfers[tokenId];
        if (t.status != TransferStatus.Pending && t.status != TransferStatus.Accepted) revert NoActiveTransfer();
        if (msg.sender != t.from && msg.sender != t.to) revert UnauthorizedTransferActor();

        t.status = TransferStatus.Cancelled;
        emit IdentityTransferCancelled(tokenId, msg.sender);
    }

    /// @notice Complete an accepted transfer once the 6-hour delay has elapsed. Permissionless.
    function finalizeIdentityTransfer(uint256 tokenId) external whenNotPaused nonReentrant {
        IdentityTransfer storage t = _identityTransfers[tokenId];
        if (t.status != TransferStatus.Accepted) revert TransferNotAccepted();

        uint64 readyAt = t.acceptedAt + IDENTITY_TRANSFER_DELAY;
        if (block.timestamp < readyAt) revert TransferDelayNotElapsed(readyAt);
        if (ownerTokenId[t.to] != 0) revert AlreadyHasIdentity(t.to);

        address from = t.from;
        address to = t.to;
        t.status = TransferStatus.Completed;

        // Authorize exactly this token through the _update transfer-restriction (per-token, never a global
        // bypass), and use the callback-free _transfer — not _safeTransfer — so no recipient onERC721Received
        // hook can re-enter while the restriction is lifted. _transfer also reverts if `from` is no longer the
        // owner, so the frozen escrow record can never move a stale `from`.
        _escrowTransferTokenId = tokenId;
        _transfer(from, to, tokenId);
        _escrowTransferTokenId = 0;

        emit IdentityTransferCompleted(tokenId, from, to);
    }

    /// @notice The current transfer escrow record for an identity.
    function identityTransferOf(uint256 tokenId)
        external
        view
        returns (address from, address to, uint64 acceptedAt, TransferStatus status)
    {
        IdentityTransfer storage t = _identityTransfers[tokenId];
        return (t.from, t.to, t.acceptedAt, t.status);
    }

    // ─────────────────── Overrides ───────────────────

    function _update(address to, uint256 tokenId, address auth)
        internal
        override(ERC721Upgradeable)
        returns (address from)
    {
        // Identity (and thus its wallet) may move only through the escrow flow; block raw transfers.
        // Mint (currentOwner == 0) and burn (to == 0) are unaffected. Only the exact tokenId currently being
        // finalized is allowed through — a global flag would let a reentrant move of a different token slip by.
        address currentOwner = _ownerOf(tokenId);
        if (currentOwner != address(0) && to != address(0) && _escrowTransferTokenId != tokenId) {
            revert TransferRestricted();
        }

        from = super._update(to, tokenId, auth);
        uint256 score = _reputationScore(tokenId);
        bool rebuiltScore = false;

        if (from != address(0) && ownerTokenId[from] == tokenId) {
            _accrueNFTReward(from);
            delete ownerTokenId[from];
        }

        if (totalReputationScore == 0 && _nextTokenId > 1) {
            totalReputationScore = _computeTotalReputationScore();
            rebuiltScore = true;
        }

        if (!rebuiltScore && from == address(0)) {
            totalReputationScore += score;
        } else if (!rebuiltScore && to == address(0)) {
            totalReputationScore -= score;
        }

        if (to != address(0)) {
            uint256 existingTokenId = ownerTokenId[to];
            if (existingTokenId != 0 && existingTokenId != tokenId) {
                revert AlreadyHasIdentity(to);
            }

            ownerTokenId[to] = tokenId;
            nftUserRewardPerTokenPaid[to] = nftRewardPerToken;
        }
    }

    /// @dev Identities are escrow-only (soulbound); an approval can never lead to a transfer. Disable
    ///      approvals outright so no misleading allowance exists and no operator path can be relied upon.
    function approve(address, uint256) public pure override(ERC721Upgradeable) {
        revert ApprovalsDisabled();
    }

    function setApprovalForAll(address, bool) public pure override(ERC721Upgradeable) {
        revert ApprovalsDisabled();
    }

    function _accrueNFTReward(address account) internal {
        uint256 rewardPerToken = nftRewardPerToken;
        uint256 paid = nftUserRewardPerTokenPaid[account];
        if (rewardPerToken <= paid) {
            return;
        }

        uint256 tid = ownerTokenId[account];
        nftRewards[account] += ((rewardPerToken - paid) * _reputationScore(tid)) / PRECISION;
        nftUserRewardPerTokenPaid[account] = rewardPerToken;
    }

    function _setHandle(uint256 tokenId, string memory handle) internal {
        bytes32 handleHash = _validateAndHashHandle(handle);

        uint256 existingTokenId = _tokenIdByHandleHash[handleHash];
        if (existingTokenId != 0 && existingTokenId != tokenId) {
            revert HandleAlreadyTaken();
        }

        LegacyHandleReservation storage reservation = _legacyHandleReservations[handleHash];
        if (reservation.tokenId != 0 && reservation.tokenId != tokenId && block.timestamp <= reservation.expiresAt) {
            revert HandleReserved(reservation.tokenId, reservation.expiresAt);
        }

        string memory previousHandle = handles[tokenId];
        if (bytes(previousHandle).length != 0) {
            bytes32 previousHandleHash = _handleHash(previousHandle);
            if (previousHandleHash == handleHash) {
                return;
            }
            delete _tokenIdByHandleHash[previousHandleHash];
        }

        handles[tokenId] = handle;
        _tokenIdByHandleHash[handleHash] = tokenId;

        emit IdentityHandleUpdated(tokenId, previousHandle, handle);
    }

    function _requirePaymentInitialized() internal view {
        if (_nextPaymentId == 0 || _nextPaymentRequestId == 0) {
            revert PaymentNotInitialized();
        }
    }

    function _requireHandleRegistrationReady() internal view {
        _requirePaymentInitialized();
        if (!legacyHandleReservationsFinalized && block.timestamp <= legacyHandlePriorityDeadline) {
            revert LegacyHandleReservationsNotFinalized();
        }
    }

    function _validateAndHashHandle(string memory handle) internal pure returns (bytes32) {
        bytes memory rawHandle = bytes(handle);
        uint256 length = rawHandle.length;
        if (length < MIN_HANDLE_BYTES || length > MAX_HANDLE_BYTES) revert InvalidHandle();

        if (rawHandle[0] == bytes1(uint8(0x2d)) || rawHandle[length - 1] == bytes1(uint8(0x2d))) {
            revert InvalidHandle();
        }

        for (uint256 i = 0; i < length; i++) {
            uint8 c = uint8(rawHandle[i]);
            bool valid = (c >= 0x61 && c <= 0x7a) || (c >= 0x30 && c <= 0x39) || c == 0x2d;
            if (!valid) revert InvalidHandle();
        }

        return keccak256(rawHandle);
    }

    function _legacyHandleSlug(string memory name) internal pure returns (string memory) {
        bytes memory source = bytes(name);
        uint256 start;
        uint256 end = source.length;

        while (start < end && source[start] == bytes1(uint8(0x20))) {
            start++;
        }
        while (end > start && source[end - 1] == bytes1(uint8(0x20))) {
            end--;
        }
        if (end <= start) {
            return "";
        }

        bytes memory output = new bytes(end - start);
        uint256 outputIndex;
        for (uint256 i = start; i < end; i++) {
            uint8 c = uint8(source[i]);
            if (c >= 0x41 && c <= 0x5a) {
                c += 32;
            } else if (c == 0x20 || c == 0x5f) {
                c = 0x2d;
            } else {
                bool valid = (c >= 0x61 && c <= 0x7a) || (c >= 0x30 && c <= 0x39) || c == 0x2d;
                if (!valid) {
                    return "";
                }
            }
            output[outputIndex++] = bytes1(c);
        }

        if (
            outputIndex < MIN_HANDLE_BYTES || outputIndex > MAX_HANDLE_BYTES || output[0] == bytes1(uint8(0x2d))
                || output[outputIndex - 1] == bytes1(uint8(0x2d))
        ) {
            return "";
        }

        return string(output);
    }

    function _handleHash(string memory handle) internal pure returns (bytes32) {
        return keccak256(bytes(handle));
    }

    function _requireTokenIdForHandle(string calldata handle) internal view returns (uint256 tokenId) {
        tokenId = _tokenIdByHandleHash[_handleHash(handle)];
        if (tokenId == 0 || _ownerOf(tokenId) == address(0)) revert UnknownHandle();
    }

    function _validatePaymentInputs(uint256 amount, string calldata memo) internal pure {
        if (amount == 0) revert InvalidPaymentAmount();
        if (bytes(memo).length > MAX_PAYMENT_MEMO_BYTES) revert PaymentMemoTooLong();
    }

    function _transferPaymentAsset(address token, address payer, address payable recipient, uint256 amount) internal {
        if (token == NATIVE_MON) {
            if (msg.value != amount) revert InvalidNativeValue();

            (bool ok,) = recipient.call{value: amount}("");
            if (!ok) revert NativePaymentFailed();
            return;
        }

        if (msg.value != 0) revert InvalidNativeValue();
        IERC20(token).safeTransferFrom(payer, recipient, amount);
    }

    /// @notice EIP-712 domain separator for off-chain signing of payment authorizations.
    function paymentDomainSeparator() public view returns (bytes32) {
        return keccak256(
            abi.encode(_EIP712_DOMAIN_TYPEHASH, _EIP712_NAME_HASH, _EIP712_VERSION_HASH, block.chainid, address(this))
        );
    }

    /// @notice Struct hash for the off-chain authorization message (without the EIP-712 prefix).
    function payPaymentRequestStructHash(uint256 requestId, uint256 nonce, uint256 deadline)
        public
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(_PAY_REQUEST_AUTH_TYPEHASH, requestId, nonce, deadline));
    }

    /// @notice Full EIP-712 digest the payer must sign to authorize delegated payment.
    function payPaymentRequestDigest(uint256 requestId, uint256 nonce, uint256 deadline)
        external
        view
        returns (bytes32)
    {
        return _payPaymentRequestDigest(requestId, nonce, deadline);
    }

    function _payPaymentRequestDigest(uint256 requestId, uint256 nonce, uint256 deadline)
        internal
        view
        returns (bytes32)
    {
        return keccak256(
            abi.encodePacked("\x19\x01", paymentDomainSeparator(), payPaymentRequestStructHash(requestId, nonce, deadline))
        );
    }

    function _consumePayPaymentRequestSig(
        uint256 requestId,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature,
        uint256 expectedPayerTokenId
    ) internal returns (address signer) {
        // Signer is the current owner of the payer identity. SignatureChecker validates both EOA (ECDSA) and
        // smart-account (EIP-1271) signatures, so an identity held by a contract wallet can still authorize.
        signer = _ownerOf(expectedPayerTokenId);
        if (signer == address(0)) revert InvalidPaymentSignature();
        bytes32 digest = _payPaymentRequestDigest(requestId, nonce, deadline);
        if (!SignatureChecker.isValidSignatureNow(signer, digest, signature)) revert InvalidPaymentSignature();
        if (paymentNonces[signer] != nonce) revert InvalidPaymentSignature();

        paymentNonces[signer] = nonce + 1;
    }

    function _effectivePaymentRequestStatus(PaymentRequest storage request)
        internal
        view
        returns (PaymentRequestStatus)
    {
        if (request.status == PaymentRequestStatus.Pending && request.dueAt != 0 && block.timestamp > request.dueAt) {
            return PaymentRequestStatus.Expired;
        }
        return request.status;
    }

    function _reputationScore(uint256 tokenId) internal view returns (uint256) {
        uint256 score = reputationScores[tokenId];
        if (score != 0) {
            return score;
        }
        return _defaultReputationScore(profiles[tokenId].entityType);
    }

    function _defaultReputationScore(EntityType entityType) internal pure returns (uint256) {
        return entityType == EntityType.Human ? DEFAULT_HUMAN_REPUTATION_SCORE : DEFAULT_AI_REPUTATION_SCORE;
    }

    function _ensureTotalReputationScore() internal returns (uint256 totalScore) {
        totalScore = totalReputationScore;
        if (totalScore == 0 && _nextTokenId > 1) {
            totalScore = _computeTotalReputationScore();
            totalReputationScore = totalScore;
        }
    }

    function _computeTotalReputationScore() internal view returns (uint256 totalScore) {
        for (uint256 tokenId = 1; tokenId < _nextTokenId; tokenId++) {
            if (_ownerOf(tokenId) != address(0)) {
                totalScore += _reputationScore(tokenId);
            }
        }
    }

    function tokenURI(uint256 tokenId) public view override(ERC721Upgradeable) returns (string memory) {
        if (_ownerOf(tokenId) == address(0)) revert NonexistentToken();
        IdentityProfile storage p = profiles[tokenId];
        return _renderTokenURI(
            tokenId,
            p.name,
            p.bio,
            uint8(p.entityType),
            p.hue,
            p.saturation,
            p.verified,
            p.registeredAt,
            _reputationScore(tokenId),
            handles[tokenId],
            avatarConfig[tokenId]
        );
    }

    function supportsInterface(bytes4 interfaceId) public view virtual override(ERC721Upgradeable) returns (bool) {
        return super.supportsInterface(interfaceId);
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    // ─────────────────── Identity wallet + escrowed transfer (storage) ───────────────────

    /// @notice The 6-hour delay between accepting a transfer and being able to finalize it.
    uint64 public constant IDENTITY_TRANSFER_DELAY = 6 hours;

    enum TransferStatus {
        None,
        Pending,
        Accepted,
        Completed,
        Cancelled
    }

    struct IdentityTransfer {
        address from;
        address to;
        uint64 acceptedAt;
        TransferStatus status;
    }

    /// @notice Fixed bootstrap wallet implementation (every wallet proxy's birth logic). Set once; never changed.
    address public walletImplementation;
    /// @notice Deployed smart-account wallet per identity (0 until created).
    mapping(uint256 => address) public walletOf;
    /// @notice Allowlisted wallet implementations and their versions (0 = not approved). Immutable once set.
    mapping(address => uint256) public walletImplVersion;
    /// @notice Active transfer escrow per identity.
    mapping(uint256 => IdentityTransfer) private _identityTransfers;
    /// @dev The single tokenId currently authorized to move through _update (0 = none). Set only inside
    ///      finalizeIdentityTransfer so exactly that escrow NFT move — and no other — is allowed through.
    uint256 private _escrowTransferTokenId;
    /// @notice Wallet implementations revoked as future upgrade targets (baseline version is left intact).
    mapping(address => bool) public walletImplRevoked;

    uint256[29] private __gap;
}
