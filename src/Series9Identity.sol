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
import {Series9IdentityRenderer} from "./Series9IdentityRenderer.sol";

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

    struct IdentityProfile {
        string name; // Display name
        string bio; // Short bio (max 128 chars)
        EntityType entityType; // Human or AI
        uint8 hue; // HSL hue (0-255 mapped) for avatar color
        uint8 saturation; // Saturation variant
        bool verified; // Protocol-level verification
        uint64 registeredAt; // Block timestamp
    }

    // ─────────────────── State ───────────────────

    uint256 private _nextTokenId;

    mapping(uint256 => IdentityProfile) public profiles;
    mapping(address => uint256) public ownerTokenId; // 1 identity per address
    mapping(uint256 => string) public customAvatarSeed; // Optional seed for generative art

    uint256 private constant PRECISION = 1e18;
    uint256 public constant MAX_AVATAR_SEED_BYTES = 64;
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
    function setCustomAvatarSeed(uint256 tokenId, string calldata seed) external whenNotPaused {
        if (ownerOf(tokenId) != msg.sender) revert NotTokenOwner();
        if (bytes(seed).length > MAX_AVATAR_SEED_BYTES) revert AvatarSeedTooLong();
        customAvatarSeed[tokenId] = seed;
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

    // ─────────────────── Overrides ───────────────────

    function _update(address to, uint256 tokenId, address auth)
        internal
        override(ERC721Upgradeable)
        returns (address from)
    {
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

    function tokenURI(uint256 tokenId)
        public
        view
        override(ERC721Upgradeable)
        returns (string memory)
    {
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
            customAvatarSeed[tokenId]
        );
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        virtual
        override(ERC721Upgradeable)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    uint256[47] private __gap;
}
