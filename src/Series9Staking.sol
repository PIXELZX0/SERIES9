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

contract Series9Staking is Initializable, OwnableUpgradeable, PausableUpgradeable, ReentrancyGuard, UUPSUpgradeable {
    using SafeERC20 for IERC20;

    uint256 private constant PRECISION = 1e18;
    uint256 private constant BPS_DENOMINATOR = 10_000;
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
    event ManagedTokenImplementationUpdated(address previousImpl, address newImpl);
    event TokensUpgraded(address ser9Proxy, address ser9Impl, address managedImpl, uint256 managedCount);

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

    modifier updateReward(address account) {
        rewardPerTokenStored = rewardPerToken();
        lastUpdateBlock = block.number;

        if (account != address(0)) {
            rewards[account] = earned(account);
            userRewardPerTokenPaid[account] = rewardPerTokenStored;
        }

        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

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
        tokenCreationFee = initialCreationFee;
        lastUpdateBlock = block.number;
        managedTokenImplementation = managedTokenImplementation_;
    }

    function setRewardRatePerBlock(uint256 newRewardRatePerBlock) external onlyOwner updateReward(address(0)) {
        rewardRatePerBlock = newRewardRatePerBlock;
        emit RewardRateUpdated(newRewardRatePerBlock);
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

    function upgradeTokens(address newSer9Impl, address newManagedImpl, bytes calldata ser9Data, bytes calldata managedData)
        external
        onlyOwner
    {
        _validateImplementation(newSer9Impl);
        _validateImplementation(newManagedImpl);

        address ser9Proxy = address(ser9);
        if (ser9Proxy.code.length == 0) {
            revert InvalidTokenAddress();
        }

        address ser9Owner = ser9.owner();
        if (ser9Owner != address(this)) {
            revert UnauthorizedTokenOwner(ser9Proxy, ser9Owner);
        }

        uint256 managedCount = managedTokens.length;
        for (uint256 i = 0; i < managedCount; ++i) {
            address token = managedTokens[i];
            if (token.code.length == 0) {
                revert InvalidManagedToken();
            }

            address tokenOwner = Series9ManagedToken(token).owner();
            if (tokenOwner != address(this)) {
                revert UnauthorizedTokenOwner(token, tokenOwner);
            }
        }

        ser9.upgradeToAndCall(newSer9Impl, ser9Data);

        for (uint256 i = 0; i < managedCount; ++i) {
            Series9ManagedToken(managedTokens[i]).upgradeToAndCall(newManagedImpl, managedData);
        }

        address previousManagedImplementation = managedTokenImplementation;
        managedTokenImplementation = newManagedImpl;
        emit ManagedTokenImplementationUpdated(previousManagedImplementation, newManagedImpl);
        emit TokensUpgraded(ser9Proxy, newSer9Impl, newManagedImpl, managedCount);
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

    function stake(uint256 amount) external whenNotPaused nonReentrant updateReward(msg.sender) {
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

    function unstake(uint256 amount) external whenNotPaused nonReentrant updateReward(msg.sender) {
        if (amount == 0) {
            revert ZeroAmount();
        }

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

        IERC20(address(ser9)).safeTransfer(msg.sender, amount);

        emit Unstaked(msg.sender, amount);
    }

    function claimRewards() external whenNotPaused nonReentrant updateReward(msg.sender) {
        uint256 reward = rewards[msg.sender];
        if (reward == 0) {
            revert NoRewards();
        }

        rewards[msg.sender] = 0;
        ser9.mint(msg.sender, reward);

        emit RewardClaimed(msg.sender, reward);
    }

    function lock(uint256 amount) external whenNotPaused nonReentrant updateReward(msg.sender) {
        if (amount == 0) {
            revert ZeroAmount();
        }

        uint256 userStaked = stakedBalance[msg.sender];
        uint256 userLocked = lockedBalance[msg.sender];

        if (amount > userStaked - userLocked) {
            revert InsufficientUnlockedBalance();
        }

        uint256 lockedAfter = userLocked + amount;
        lockedBalance[msg.sender] = lockedAfter;
        _syncRewardWeight(msg.sender);

        emit Locked(msg.sender, amount, lockedAfter);
    }

    function mintManagedToken(address token, uint256 amount) external whenNotPaused nonReentrant updateReward(msg.sender) {
        if (amount == 0) {
            revert ZeroAmount();
        }

        TokenConfig storage config = _requireManagedToken(token);
        TokenMintPolicy memory policy = _resolveTokenMintPolicy(token);
        uint256 currentSupply = Series9ManagedToken(token).totalSupply();
        uint256 collateralCost = _previewCollateralForMint(config.mintRate, policy, currentSupply, amount);

        uint256 usedAfter = usedLockedSer9[msg.sender] + collateralCost;
        if (usedAfter > lockedBalance[msg.sender]) {
            revert ExceedsMintLimit();
        }

        usedLockedSer9[msg.sender] = usedAfter;
        userTokenDebt[msg.sender][token] += amount;
        userTokenCollateralUsed[msg.sender][token] += collateralCost;

        Series9ManagedToken(token).mint(msg.sender, amount);

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

        uint256 availableLocked = lockedBalance[user] - usedLockedSer9[user];
        if (availableLocked == 0) {
            return 0;
        }

        TokenMintPolicy memory policy = _resolveTokenMintPolicy(token);
        if (policy.maxSupply == 0) {
            return Math.mulDiv(availableLocked, PRECISION, config.mintRate);
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
            if (collateral <= availableLocked) {
                low = mid;
            } else {
                high = mid - 1;
            }
        }

        return low;
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

    function stakeFeeToken(address token, uint256 amount) external whenNotPaused nonReentrant {
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
    ) external whenNotPaused nonReentrant {
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

    function earned(address account) public view returns (uint256) {
        uint256 rewardDelta = rewardPerToken() - userRewardPerTokenPaid[account];
        uint256 accrued = Math.mulDiv(rewardWeightBalance[account], rewardDelta, PRECISION);
        return rewards[account] + accrued;
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
            pool.accFeePerShare += Math.mulDiv(distributable, PRECISION, pool.totalStaked);
            pool.undistributedRewards = 0;
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

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    uint256[26] private __gap;
}
