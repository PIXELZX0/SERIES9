// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IERC721} from "openzeppelin-contracts/contracts/token/ERC721/IERC721.sol";
import {IERC1271} from "openzeppelin-contracts/contracts/interfaces/IERC1271.sol";
import {SignatureChecker} from "openzeppelin-contracts/contracts/utils/cryptography/SignatureChecker.sol";
import {Series9IdentityWallet, ISeries9IdentityForWallet} from "./Series9IdentityWallet.sol";

/// @title Series9IdentityWalletV2
/// @notice Wallet logic v2: adds ERC-1271 so the wallet can prove off-chain that the current identity
///         holder authorized a hash. This makes the wallet a usable signer for Permit2, marketplace
///         listings, SIWE logins and any other signature-based protocol — without moving authority
///         away from the NFT.
/// @dev Adds no storage: the layout stays exactly as v1 (slot 0 `identity`, slot 1 `tokenId`, then
///      `__gap`). Holders upgrade with `upgradeToAndCall(v2, "")` — there is nothing to initialize.
contract Series9IdentityWalletV2 is Series9IdentityWallet, IERC1271 {
    /// @dev Returned instead of the magic value; ERC-1271 callers treat any non-magic value as invalid.
    bytes4 private constant _INVALID = 0xffffffff;

    /// @notice Validate `signature` over `hash` on behalf of the identity that owns this wallet.
    /// @dev The signer is the *current* `ownerOf(tokenId)`, so signing authority follows the NFT exactly
    ///      like `execute` does: the old holder's signatures stop validating the moment the identity moves.
    ///      The signature is checked against the raw `hash` as handed over by the caller (no domain
    ///      wrapping) to stay compatible with standard dapp signing flows.
    /// @return magicValue `0x1626ba7e` if valid, `0xffffffff` otherwise. Never reverts.
    function isValidSignature(bytes32 hash, bytes memory signature) public view returns (bytes4) {
        address holder;
        try IERC721(identity).ownerOf(tokenId) returns (address holder_) {
            holder = holder_;
        } catch {
            return _INVALID; // identity burned or never minted
        }

        // Same authorization as every outbound call: current holder, and not frozen mid-escrow-transfer.
        // The hook is a view that reverts on failure, so a clean return means authorized.
        try ISeries9IdentityForWallet(identity).authorizeWalletCall(tokenId, holder) {}
        catch {
            return _INVALID;
        }

        // SignatureChecker covers both an EOA holder (ECDSA, malleability-safe) and a contract holder
        // (nested ERC-1271), so an identity held by another smart account can still sign.
        return SignatureChecker.isValidSignatureNow(holder, hash, signature)
            ? IERC1271.isValidSignature.selector
            : _INVALID;
    }
}
