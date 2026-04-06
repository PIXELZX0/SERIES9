// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Initializable} from "openzeppelin-contracts/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "openzeppelin-contracts/contracts/proxy/utils/UUPSUpgradeable.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC1822Proxiable} from "openzeppelin-contracts/contracts/interfaces/draft-IERC1822.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {OwnableUpgradeable} from "openzeppelin-contracts-upgradeable/contracts/access/OwnableUpgradeable.sol";
import {PausableUpgradeable} from "openzeppelin-contracts-upgradeable/contracts/utils/PausableUpgradeable.sol";

import {SER9Token} from "./SER9Token.sol";
import {Series9ManagedToken} from "./Series9ManagedToken.sol";

contract Series9Staking is Initializable, OwnableUpgradeable, PausableUpgradeable, ReentrancyGuard, UUPSUpgradeable {
    using SafeERC20 for IERC20;

    uint256 private constant PRECISION = 1e18;
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

    SER9Token public ser9;
    address public managedTokenImplementation;

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
        address managedTokenImplementation_
    ) external initializer {
        if (ser9Token == address(0) || ser9Token.code.length == 0) {
            revert InvalidTokenAddress();
        }

        _validateImplementation(managedTokenImplementation_);

        __Ownable_init(initialOwner);
        __Pausable_init();

        ser9 = SER9Token(ser9Token);
        rewardRatePerBlock = rewardPerBlock;
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
        address creator,
        string calldata name,
        string calldata symbol,
        uint256 mintRate,
        bool feeEnabled,
        uint16 feeBps
    ) external onlyOwner whenNotPaused returns (address token) {
        if (mintRate == 0) {
            revert MintRateZero();
        }

        if (!feeEnabled && feeBps != 0) {
            revert InvalidFeeConfiguration();
        }

        bytes memory initData = abi.encodeCall(
            Series9ManagedToken.initialize, (name, symbol, address(this), feeEnabled, feeBps, address(this))
        );
        ERC1967Proxy managedTokenProxy = new ERC1967Proxy(managedTokenImplementation, initData);

        token = address(managedTokenProxy);
        tokenConfigs[token] =
            TokenConfig({exists: true, creator: creator, mintRate: mintRate, feeEnabled: feeEnabled});
        managedTokens.push(token);

        emit ManagedTokenCreated(token, creator, mintRate, feeEnabled, feeBps, name, symbol);
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

        uint256 collateralCost = _collateralForAmount(amount, config.mintRate);

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
        return Math.mulDiv(availableLocked, PRECISION, config.mintRate);
    }

    function availableUnusedLocked(address user) external view returns (uint256) {
        return lockedBalance[user] - usedLockedSer9[user];
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

    uint256[50] private __gap;
}
