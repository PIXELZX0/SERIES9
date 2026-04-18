// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Initializable} from "openzeppelin-contracts/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "openzeppelin-contracts/contracts/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "openzeppelin-contracts-upgradeable/contracts/access/OwnableUpgradeable.sol";
import {ERC721Upgradeable} from "openzeppelin-contracts-upgradeable/contracts/token/ERC721/ERC721Upgradeable.sol";
import {ERC721URIStorageUpgradeable} from "openzeppelin-contracts-upgradeable/contracts/token/ERC721/extensions/ERC721URIStorageUpgradeable.sol";
import {IERC165} from "openzeppelin-contracts/contracts/utils/introspection/IERC165.sol";
import {PausableUpgradeable} from "openzeppelin-contracts-upgradeable/contracts/utils/PausableUpgradeable.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Minimal interface for Series9Staking.stake()
interface ISeries9Staking {
    function stake(uint256 amount) external;
}

/// @title Series9Identity
/// @notice On-chain identity NFT with SVG generation and AI/human distinction
/// @dev UUPS upgradeable, ERC721 with on-chain metadata
contract Series9Identity is
    Initializable,
    ERC721Upgradeable,
    ERC721URIStorageUpgradeable,
    OwnableUpgradeable,
    PausableUpgradeable,
    ReentrancyGuard,
    UUPSUpgradeable
{
    using SafeERC20 for IERC20;
    // ─────────────────── Types ───────────────────

    enum EntityType {
        Human,
        AI
    }

    struct IdentityProfile {
        string name;          // Display name
        string bio;           // Short bio (max 128 chars)
        EntityType entityType; // Human or AI
        uint8 hue;            // HSL hue (0-255 mapped) for avatar color
        uint8 saturation;     // Saturation variant
        bool verified;        // Protocol-level verification
        uint64 registeredAt;  // Block timestamp
    }

    // ─────────────────── State ───────────────────

    uint256 private _nextTokenId;

    mapping(uint256 => IdentityProfile) public profiles;
    mapping(address => uint256) public ownerTokenId;   // 1 identity per address
    mapping(uint256 => string) public customAvatarSeed; // Optional seed for generative art

    IERC20 public ser9;              // SER9 token
    address public stakingContract;   // Series9Staking address for auto-staking
    uint256 public aiMintFee;         // 10 SER9 for AI
    uint256 public humanMintFee;      // 50 SER9 for Human

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
        if (stakingContract_ == address(0)) revert InvalidStakingContract();

        __ERC721_init("Series9 Identity", "S9ID");
        __ERC721URIStorage_init();
        __Ownable_init(initialOwner);
        __Pausable_init();

        ser9 = IERC20(ser9Token);
        stakingContract = stakingContract_;
        aiMintFee = initialAIMintFee;
        humanMintFee = initialHumanMintFee;
        _nextTokenId = 1;
    }

    // ─────────────────── Mint ───────────────────

    /// @notice Mint a new identity NFT — one per address, SER9 fee auto-staked
    function mintIdentity(
        string calldata name,
        string calldata bio,
        EntityType entityType,
        uint8 hue,
        uint8 saturation
    ) external whenNotPaused nonReentrant returns (uint256) {
        if (ownerTokenId[msg.sender] != 0) revert AlreadyHasIdentity(msg.sender);
        if (bytes(name).length > 32) revert NameTooLong();
        if (bytes(bio).length > 128) revert BioTooLong();

        // Determine fee based on entity type
        uint256 fee = entityType == EntityType.AI ? aiMintFee : humanMintFee;

        // Transfer SER9 from user to this contract
        IERC20(ser9).safeTransferFrom(msg.sender, address(this), fee);

        // Approve staking contract to pull SER9
        IERC20(ser9).approve(stakingContract, fee);

        // Stake SER9 on behalf of the user via staking contract
        // The staking contract will pull SER9 from this contract via transferFrom
        ISeries9Staking(stakingContract).stake(fee);

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

        ownerTokenId[msg.sender] = tokenId;
        _safeMint(msg.sender, tokenId);

        // Set on-chain tokenURI with generated SVG
        _setTokenURI(tokenId, _generateTokenURI(tokenId));

        emit IdentityStaked(msg.sender, fee);

        return tokenId;
    }

    // ─────────────────── Profile Updates ───────────────────

    /// @notice Update profile fields (only token owner)
    function updateProfile(
        uint256 tokenId,
        string calldata name,
        string calldata bio,
        uint8 hue,
        uint8 saturation
    ) external whenNotPaused {
        if (ownerOf(tokenId) != msg.sender) revert NotTokenOwner();
        if (bytes(name).length > 32) revert NameTooLong();
        if (bytes(bio).length > 128) revert BioTooLong();

        IdentityProfile storage p = profiles[tokenId];
        p.name = name;
        p.bio = bio;
        p.hue = hue;
        p.saturation = saturation;

        _setTokenURI(tokenId, _generateTokenURI(tokenId));

        emit ProfileUpdated(tokenId, name, bio, p.entityType);
    }

    /// @notice Set a custom avatar seed for advanced generative art
    function setCustomAvatarSeed(uint256 tokenId, string calldata seed) external {
        if (ownerOf(tokenId) != msg.sender) revert NotTokenOwner();
        customAvatarSeed[tokenId] = seed;
        _setTokenURI(tokenId, _generateTokenURI(tokenId));
    }

    // ─────────────────── Admin ───────────────────

    function verify(uint256 tokenId, bool status) external onlyOwner {
        profiles[tokenId].verified = status;
        _setTokenURI(tokenId, _generateTokenURI(tokenId));
        emit ProfileVerified(tokenId, status);
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
        if (newStaking == address(0)) revert InvalidStakingContract();
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
        return profiles[tokenId].entityType;
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
        return profiles[tokenId].verified;
    }

    /// @notice Resolve address → display name
    function nameOf(address account) external view returns (string memory) {
        uint256 tid = ownerTokenId[account];
        if (tid == 0) return "";
        return profiles[tid].name;
    }

    // ─────────────────── On-chain SVG Generation ───────────────────

    /// @notice Generate the full data-URI tokenURI with on-chain SVG
    function _generateTokenURI(uint256 tokenId) internal view returns (string memory) {
        IdentityProfile memory p = profiles[tokenId];

        string memory svg = _generateSVG(tokenId, p);

        // Build JSON metadata
        string memory json = string(abi.encodePacked(
            '{"name":"', p.name,
            '","description":"Series9 Identity NFT","image":"data:image/svg+xml;base64,',
            _base64Encode(bytes(svg)),
            '","attributes":[{"trait_type":"Entity Type","value":"',
            p.entityType == EntityType.AI ? "AI" : "Human",
            '"},{"trait_type":"Verified","value":"',
            p.verified ? "true" : "false",
            '"},{"trait_type":"Hue","value":"',
            _uint2str(p.hue),
            '"},{"trait_type":"Saturation","value":"',
            _uint2str(p.saturation),
            '"}]}'
        ));

        return string(abi.encodePacked(
            "data:application/json;base64,",
            _base64Encode(bytes(json))
        ));
    }

    /// @notice Generate the SVG image for a given profile
    function _generateSVG(uint256 tokenId, IdentityProfile memory p) internal view returns (string memory) {
        // Colors derived from profile hue/saturation
        string memory primaryColor = _colorFromHue(p.hue, 0);
        string memory secondaryColor = _colorFromHue(p.hue, 1);
        string memory accentColor = _colorFromHue(uint8((uint256(p.hue) + 2) % 16), 0);
        string memory bgColor = _colorFromHue(p.hue % 16, 2);

        // Type badge
        string memory typeBadge = p.entityType == EntityType.AI
            ? '<rect x="150" y="12" width="40" height="20" rx="4" fill="#6366f1"/><text x="170" y="26" font-size="10" fill="white" text-anchor="middle" font-family="monospace">AI</text>'
            : '<rect x="150" y="12" width="52" height="20" rx="4" fill="#22c55e"/><text x="176" y="26" font-size="10" fill="white" text-anchor="middle" font-family="monospace">HUMAN</text>';

        // Verified badge
        string memory verifiedBadge = p.verified
            ? '<circle cx="196" cy="22" r="8" fill="#3b82f6"/><text x="196" y="26" font-size="10" fill="white" text-anchor="middle" font-family="sans-serif">V</text>'
            : '';

        // Avatar: generative geometric pattern from tokenId + seed
        string memory avatarPattern = _generateAvatarPattern(tokenId, p);

        // Construct final SVG
        return string(abi.encodePacked(
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 340 200" width="340" height="200">',
            // Background
            '<rect width="340" height="200" rx="12" fill="', bgColor, '"/>',
            // Card gradient top
            '<defs><linearGradient id="g" x1="0" y1="0" x2="1" y2="1">',
            '<stop offset="0%" stop-color="', primaryColor, '"/>',
            '<stop offset="100%" stop-color="', secondaryColor, '"/></linearGradient></defs>',
            '<rect width="340" height="60" rx="12" fill="url(#g)"/>',
            '<rect y="48" width="340" height="12" fill="url(#g)"/>',
            // Badges
            typeBadge,
            verifiedBadge,
            // Avatar area
            avatarPattern,
            // Name
            '<text x="130" y="95" font-size="18" font-weight="bold" fill="', primaryColor, '" font-family="sans-serif">',
            _escapeXml(p.name),
            '</text>',
            // Bio
            '<text x="130" y="115" font-size="11" fill="#555" font-family="sans-serif">',
            _escapeXml(p.bio),
            '</text>',
            // ID line
            '<text x="20" y="170" font-size="9" fill="#888" font-family="monospace">ID #',
            _uint2str(tokenId),
            '</text>',
            // Timestamp
            '<text x="20" y="185" font-size="8" fill="#aaa" font-family="monospace">Registered: ',
            _uint2str(p.registeredAt),
            '</text>',
            // Series9 branding
            '<text x="270" y="190" font-size="10" fill="', accentColor, '" font-family="monospace" font-weight="bold">S9</text>',
            '</svg>'
        ));
    }

    /// @notice Generative avatar pattern based on tokenId and profile
    function _generateAvatarPattern(uint256 tokenId, IdentityProfile memory p) internal pure returns (string memory) {
        // Use tokenId and profile params as pseudo-random seed
        uint256 seed = uint256(keccak256(abi.encodePacked(tokenId, p.hue, p.saturation, p.registeredAt)));

        string memory avatarColor = _colorFromHue(p.hue, 0);
        string memory avatarColorLight = _colorFromHue(p.hue, 2);

        // Generate 3 concentric shapes offset by seed
        string memory shapes = "";
        for (uint8 i = 0; i < 3; i++) {
            seed = _nextSeed(seed);
            uint8 sz = 15 + uint8(seed % 10);        // 15-24 radius
            uint8 cx = 30 + uint8((seed >> 8) % 20);  // 30-49
            uint8 cy = 30 + uint8((seed >> 16) % 20); // 30-49

            if (i % 2 == 0) {
                shapes = string(abi.encodePacked(
                    shapes,
                    '<circle cx="', _uint2str(cx), '" cy="', _uint2str(cy), '" r="', _uint2str(sz),
                    '" fill="', i == 0 ? avatarColor : avatarColorLight,
                    '" opacity="', i == 0 ? "0.9" : "0.5", '"/>'
                ));
            } else {
                shapes = string(abi.encodePacked(
                    shapes,
                    '<rect x="', _uint2str(cx - sz/2), '" y="', _uint2str(cy - sz/2),
                    '" width="', _uint2str(sz), '" height="', _uint2str(sz),
                    '" rx="4" fill="', avatarColorLight, '" opacity="0.4" transform="rotate(45 ',
                    _uint2str(cx), ' ', _uint2str(cy), ')"/>'
                ));
            }
        }

        // Clip to circle
        return string(abi.encodePacked(
            '<defs><clipPath id="av"><circle cx="40" cy="38" r="28"/></clipPath></defs>',
            '<g clip-path="url(#av)">',
            '<circle cx="40" cy="38" r="28" fill="', avatarColor, '"/>',
            shapes,
            '</g>',
            '<circle cx="40" cy="38" r="28" fill="none" stroke="white" stroke-width="2"/>'
        ));
    }

    // ─────────────────── Utility: Color Palette ───────────────────

    /// @notice Map hue (0-255) + lightness variant to a hex color via palette table
    /// @dev 16 base hues × 3 lightness levels = 48 deterministic colors
    function _colorFromHue(uint8 h, uint8 variant) internal pure returns (string memory) {
        // 16 base colors covering the spectrum
        // variant: 0=primary, 1=dark, 2=light
        // prettier-ignore
        string[16][3] memory PALETTE = [
            // variant 0: primary (medium)
            ["#e74c3c","#e67e22","#f1c40f","#2ecc71","#1abc9c","#3498db","#6c5ce7","#9b59b6","#e84393","#fd79a8","#00cec9","#0984e3","#fdcb6e","#55efc4","#a29bfe","#dfe6e9"],
            // variant 1: dark
            ["#c0392b","#d35400","#f39c12","#27ae60","#16a085","#2980b9","#5b4cde","#8e44ad","#d63384","#e6688c","#0097a7","#0772c7","#e5b825","#45d4a8","#8c7be6","#b2bec3"],
            // variant 2: light
            ["#ff6b6b","#feca57","#ffeaa7","#55efc4","#81ecec","#74b9ff","#a29bfe","#dfe6e9","#fd79a8","#fab1a0","#7efff5","#a6c5ff","#fff3b0","#b8f5d0","#c8b6ff","#f5f6fa"]
        ];

        uint8 idx = h % 16;  // pick base hue
        uint8 v = variant % 3; // pick lightness
        return PALETTE[v][idx];
    }

    // ─────────────────── Utility: Base64 ───────────────────

    bytes internal constant BASE64_CHARS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

    function _base64Encode(bytes memory data) internal pure returns (string memory) {
        if (data.length == 0) return "";

        uint256 encodedLen = 4 * ((data.length + 2) / 3);
        bytes memory result = new bytes(encodedLen);

        uint256 i = 0;
        uint256 j = 0;

        for (; i + 3 <= data.length; i += 3) {
            uint24 chunk = uint24(uint8(data[i])) << 16 |
                           uint24(uint8(data[i + 1])) << 8 |
                           uint24(uint8(data[i + 2]));

            result[j++] = BASE64_CHARS[chunk >> 18];
            result[j++] = BASE64_CHARS[(chunk >> 12) & 0x3F];
            result[j++] = BASE64_CHARS[(chunk >> 6) & 0x3F];
            result[j++] = BASE64_CHARS[chunk & 0x3F];
        }

        uint256 rem = data.length - i;
        if (rem == 1) {
            uint24 chunk = uint24(uint8(data[i])) << 16;
            result[j++] = BASE64_CHARS[chunk >> 18];
            result[j++] = BASE64_CHARS[(chunk >> 12) & 0x3F];
            result[j++] = bytes1("=");
            result[j++] = bytes1("=");
        } else if (rem == 2) {
            uint24 chunk = uint24(uint8(data[i])) << 16 |
                           uint24(uint8(data[i + 1])) << 8;
            result[j++] = BASE64_CHARS[chunk >> 18];
            result[j++] = BASE64_CHARS[(chunk >> 12) & 0x3F];
            result[j++] = BASE64_CHARS[(chunk >> 6) & 0x3F];
            result[j++] = bytes1("=");
        }

        return string(result);
    }

    // ─────────────────── Utility: Misc ───────────────────

    function _uint2str(uint256 value) internal pure returns (string memory) {
        if (value == 0) return "0";
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }
        return string(buffer);
    }

    function _escapeXml(string memory s) internal pure returns (string memory) {
        // Minimal XML escape for SVG safety
        bytes memory src = bytes(s);
        bytes memory dst = new bytes(src.length * 5); // worst case
        uint256 j = 0;
        for (uint256 i = 0; i < src.length; i++) {
            if (src[i] == "<") { dst[j++] = "&"; dst[j++] = "l"; dst[j++] = "t"; dst[j++] = ";"; }
            else if (src[i] == ">") { dst[j++] = "&"; dst[j++] = "g"; dst[j++] = "t"; dst[j++] = ";"; }
            else if (src[i] == "&") { dst[j++] = "&"; dst[j++] = "a"; dst[j++] = "m"; dst[j++] = "p"; dst[j++] = ";"; }
            else if (src[i] == '"') { dst[j++] = "&"; dst[j++] = "q"; dst[j++] = "u"; dst[j++] = "o"; dst[j++] = "t"; dst[j++] = ";"; }
            else if (src[i] == "'") { dst[j++] = "&"; dst[j++] = "a"; dst[j++] = "p"; dst[j++] = "o"; dst[j++] = "s"; dst[j++] = ";"; }
            else { dst[j++] = src[i]; }
        }
        // Trim to actual length
        bytes memory trimmed = new bytes(j);
        for (uint256 i = 0; i < j; i++) trimmed[i] = dst[i];
        return string(trimmed);
    }

    function _nextSeed(uint256 s) internal pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked(s)));
    }

    // ─────────────────── Overrides ───────────────────

    function tokenURI(uint256 tokenId)
        public
        view
        override(ERC721Upgradeable, ERC721URIStorageUpgradeable)
        returns (string memory)
    {
        return super.tokenURI(tokenId);
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        virtual
        override(ERC721Upgradeable, ERC721URIStorageUpgradeable)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }

    /// @notice Returns the total number of minted identity NFTs
    function totalMinted() external view returns (uint256) {
        return _nextTokenId - 1;
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    uint256[50] private __gap;
}
