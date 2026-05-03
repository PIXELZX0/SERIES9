// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

/// @title Series9IdentityRenderer
/// @notice Stateless on-chain metadata renderer for Series9Identity.
contract Series9IdentityRenderer {
    uint8 private constant ENTITY_HUMAN = 0;
    uint8 private constant ENTITY_AI = 1;

    struct RenderProfile {
        string name;
        string bio;
        uint8 entityType;
        uint8 hue;
        uint8 saturation;
        bool verified;
        uint64 registeredAt;
        uint256 reputationScore;
        string avatarSeed;
    }

    function _renderTokenURI(
        uint256 tokenId,
        string memory name,
        string memory bio,
        uint8 entityType,
        uint8 hue,
        uint8 saturation,
        bool verified,
        uint64 registeredAt,
        uint256 reputationScore,
        string memory avatarSeed
    ) internal pure returns (string memory) {
        RenderProfile memory p = RenderProfile({
            name: name,
            bio: bio,
            entityType: entityType,
            hue: hue,
            saturation: saturation,
            verified: verified,
            registeredAt: registeredAt,
            reputationScore: reputationScore,
            avatarSeed: avatarSeed
        });

        string memory svg = _generateSVG(tokenId, p);

        string memory json = string(
            abi.encodePacked(
                '{"name":"',
                _escapeJson(p.name),
                '","description":"Series9 Identity NFT","image":"data:image/svg+xml;base64,',
                _base64Encode(bytes(svg)),
                '","attributes":[{"trait_type":"Entity Type","value":"',
                p.entityType == ENTITY_AI ? "AI" : "Human",
                '"},{"trait_type":"Verified","value":"',
                p.verified ? "true" : "false",
                '"},{"trait_type":"Hue","value":"',
                _uint2str(p.hue),
                '"},{"trait_type":"Saturation","value":"',
                _uint2str(p.saturation),
                '"},{"trait_type":"Reputation Score","value":"',
                _uint2str(p.reputationScore),
                '"}]}'
            )
        );

        return string(abi.encodePacked("data:application/json;base64,", _base64Encode(bytes(json))));
    }

    function _generateSVG(uint256 tokenId, RenderProfile memory p) internal pure returns (string memory) {
        string memory primary = _colorFromHue(p.hue, 0);
        string memory dark = _colorFromHue(p.hue, 1);
        string memory light = _colorFromHue(p.hue, 2);
        string memory accent = _colorFromHue(uint8((uint256(p.hue) + 9) % 16), 0);
        string memory bloomOpacity = _opacityPercent(40 + (uint256(p.saturation) * 35) / 255);

        return string(
            abi.encodePacked(
                _svgHead(tokenId, primary, dark, light, accent, bloomOpacity),
                _entityBadge(p.entityType),
                _verifiedBadge(p.verified),
                _generateAvatarPattern(tokenId, p),
                _svgBody(tokenId, p, light)
            )
        );
    }

    function _svgHead(
        uint256 tokenId,
        string memory primary,
        string memory dark,
        string memory light,
        string memory accent,
        string memory bloomOpacity
    ) internal pure returns (string memory) {
        return string(
            abi.encodePacked(
                '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 340 200" width="340" height="200" shape-rendering="geometricPrecision">',
                "<title>Series9 Identity #",
                _uint2str(tokenId),
                "</title>",
                "<defs>",
                '<radialGradient id="bloom" cx="22%" cy="28%" r="78%">',
                '<stop offset="0%" stop-color="',
                primary,
                '" stop-opacity=".55"/>',
                '<stop offset="55%" stop-color="',
                dark,
                '" stop-opacity=".18"/>',
                '<stop offset="100%" stop-color="#020617" stop-opacity="0"/>',
                "</radialGradient>",
                '<linearGradient id="hueBar" x1="0" x2="1" y1="0" y2="0">',
                '<stop offset="0%" stop-color="',
                dark,
                '"/>',
                '<stop offset="50%" stop-color="',
                primary,
                '"/>',
                '<stop offset="100%" stop-color="',
                light,
                '"/>',
                "</linearGradient>",
                '<radialGradient id="avBg" cx="50%" cy="50%" r="80%">',
                '<stop offset="0%" stop-color="',
                light,
                '" stop-opacity=".55"/>',
                '<stop offset="100%" stop-color="',
                dark,
                '" stop-opacity="1"/>',
                "</radialGradient>",
                '<clipPath id="nameClip"><rect x="126" y="58" width="194" height="26"/></clipPath>',
                '<clipPath id="bio1Clip"><rect x="126" y="86" width="194" height="14"/></clipPath>',
                '<clipPath id="bio2Clip"><rect x="126" y="100" width="194" height="14"/></clipPath>',
                '<clipPath id="avClip"><rect x="24" y="62" width="88" height="88" rx="18"/></clipPath>',
                "</defs>",
                '<rect width="340" height="200" rx="18" fill="#070b1a"/>',
                '<rect width="340" height="200" rx="18" fill="url(#bloom)" opacity="',
                bloomOpacity,
                '">',
                '<animate attributeName="opacity" values="',
                bloomOpacity,
                ";.82;",
                bloomOpacity,
                '" dur="7s" repeatCount="indefinite"/>',
                "</rect>",
                '<path d="M0 168C72 142 158 188 240 156C290 137 320 142 340 130V200H0Z" fill="',
                accent,
                '" opacity=".13"/>',
                '<path d="M0 184C82 162 168 192 248 174C300 162 326 168 340 158V200H0Z" fill="',
                accent,
                '" opacity=".07"/>',
                '<rect x="6" y="6" width="328" height="188" rx="14" fill="none" stroke="#ffffff" stroke-opacity=".09"/>',
                '<g font-family="ui-monospace,SFMono-Regular,monospace">',
                '<text x="20" y="26" font-size="11" font-weight="700" fill="#f8fafc" letter-spacing="2.5">SERIES9</text>',
                '<text x="20" y="38" font-size="6" fill="#94a3b8" letter-spacing="3">IDENTITY PROTOCOL</text>',
                "</g>"
            )
        );
    }

    function _svgBody(uint256 tokenId, RenderProfile memory p, string memory light)
        internal
        pure
        returns (string memory)
    {
        (string memory bio1, string memory bio2) = _splitBio(p.bio);

        return string(
            abi.encodePacked(
                '<g clip-path="url(#nameClip)">',
                '<text x="126" y="78" font-family="Inter,system-ui,sans-serif" font-size="18" font-weight="700" fill="#f8fafc" letter-spacing="-.3">',
                _escapeXml(p.name),
                "</text>",
                "</g>",
                '<g font-family="Inter,system-ui,sans-serif" font-size="9" fill="#cbd5e1">',
                '<g clip-path="url(#bio1Clip)"><text x="126" y="97">',
                _escapeXml(bio1),
                "</text></g>",
                '<g clip-path="url(#bio2Clip)" opacity=".82"><text x="126" y="111">',
                _escapeXml(bio2),
                "</text></g>",
                "</g>",
                '<rect x="126" y="124" width="64" height="3" rx="1.5" fill="url(#hueBar)"/>',
                '<text x="126" y="140" font-family="ui-monospace,SFMono-Regular,monospace" font-size="7" fill="#94a3b8" letter-spacing="1.5">SIG ',
                _colorFromHue(p.hue, 0),
                "</text>",
                '<line x1="20" y1="160" x2="320" y2="160" stroke="#ffffff" stroke-opacity=".09"/>',
                '<g font-family="ui-monospace,SFMono-Regular,monospace">',
                '<text x="20" y="178" font-size="7" fill="#64748b" letter-spacing="1.2">EST ',
                _uint2str(_yearOf(p.registeredAt)),
                "</text>",
                '<text x="172" y="178" font-size="7" fill="#475569" letter-spacing="1.2">SAT ',
                _uint2str(p.saturation),
                "</text>",
                '<text x="320" y="178" text-anchor="end" font-size="13" font-weight="700" fill="',
                light,
                '" letter-spacing="-.3">#',
                _uint2str(tokenId),
                "</text>",
                "</g>",
                "</svg>"
            )
        );
    }

    function _entityBadge(uint8 entityType) internal pure returns (string memory) {
        if (entityType == ENTITY_AI) {
            return string(
                abi.encodePacked(
                    '<g font-family="ui-monospace,SFMono-Regular,monospace" font-size="9" font-weight="700">',
                    '<rect x="234" y="16" width="44" height="20" rx="6" fill="#020617" fill-opacity=".7" stroke="#818cf8" stroke-opacity=".55"/>',
                    '<circle cx="244" cy="26" r="3" fill="#818cf8">',
                    '<animate attributeName="opacity" values=".5;1;.5" dur="2.4s" repeatCount="indefinite"/>',
                    "</circle>",
                    '<text x="263" y="29" fill="#eef2ff" text-anchor="middle" letter-spacing="1">AI</text>',
                    "</g>"
                )
            );
        }

        return string(
            abi.encodePacked(
                '<g font-family="ui-monospace,SFMono-Regular,monospace" font-size="9" font-weight="700">',
                '<rect x="218" y="16" width="60" height="20" rx="6" fill="#020617" fill-opacity=".7" stroke="#34d399" stroke-opacity=".55"/>',
                '<circle cx="228" cy="26" r="3" fill="#34d399">',
                '<animate attributeName="opacity" values=".5;1;.5" dur="2.4s" repeatCount="indefinite"/>',
                "</circle>",
                '<text x="251" y="29" fill="#ecfdf5" text-anchor="middle" letter-spacing="1">HUMAN</text>',
                "</g>"
            )
        );
    }

    function _verifiedBadge(bool verified) internal pure returns (string memory) {
        if (verified) {
            return string(
                abi.encodePacked(
                    '<g transform="translate(286 14)">',
                    '<path d="M12 0L23 4V12C23 18 18 22 12 24C6 22 1 18 1 12V4Z" fill="#0ea5e9" fill-opacity=".18" stroke="#38bdf8" stroke-width="1.2">',
                    '<animate attributeName="fill-opacity" values=".18;.45;.18" dur="3s" repeatCount="indefinite"/>',
                    "</path>",
                    '<path d="M7 12l4 4 6-7" fill="none" stroke="#e0f2fe" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"/>',
                    "</g>"
                )
            );
        }

        return string(
            abi.encodePacked(
                '<g transform="translate(286 14)">',
                '<path d="M12 0L23 4V12C23 18 18 22 12 24C6 22 1 18 1 12V4Z" fill="#020617" fill-opacity=".55" stroke="#475569" stroke-width="1" stroke-dasharray="2 2"/>',
                '<text x="12" y="16" font-family="ui-monospace,SFMono-Regular,monospace" font-size="9" fill="#64748b" text-anchor="middle">?</text>',
                "</g>"
            )
        );
    }

    function _generateAvatarPattern(uint256 tokenId, RenderProfile memory p) internal pure returns (string memory) {
        uint256 seed =
            uint256(keccak256(abi.encodePacked(tokenId, p.hue, p.saturation, p.registeredAt, p.avatarSeed)));

        return string(
            abi.encodePacked(
                "<g>",
                '<rect x="22" y="60" width="92" height="92" rx="20" fill="',
                _colorFromHue(p.hue, 0),
                '" opacity=".22"/>',
                '<rect x="24" y="62" width="88" height="88" rx="18" fill="url(#avBg)"/>',
                '<g clip-path="url(#avClip)">',
                _constellation(seed, _colorFromHue(p.hue, 2)),
                _entityGlyph(p.entityType),
                "</g>",
                '<rect x="24" y="62" width="88" height="88" rx="18" fill="none" stroke="#ffffff" stroke-opacity=".22" stroke-width="1"/>',
                _avatarCornerMarks(),
                "</g>"
            )
        );
    }

    function _avatarCornerMarks() internal pure returns (string memory) {
        return string(
            abi.encodePacked(
                '<g stroke="#ffffff" stroke-opacity=".55" stroke-width="1" stroke-linecap="round" fill="none">',
                '<path d="M28 66h6M28 66v6"/>',
                '<path d="M108 66h-6M108 66v6"/>',
                '<path d="M28 148h6M28 148v-6"/>',
                '<path d="M108 148h-6M108 148v-6"/>',
                "</g>"
            )
        );
    }

    function _constellation(uint256 seed, string memory dotColor) internal pure returns (string memory) {
        string memory stars = "";
        uint256[8] memory xs;
        uint256[8] memory ys;

        for (uint8 i = 0; i < 8; i++) {
            seed = _nextSeed(seed);
            uint256 cx = 32 + ((seed >> 8) % 72);
            uint256 cy = 70 + ((seed >> 16) % 72);
            uint256 r = 1 + ((seed >> 24) % 3);
            xs[i] = cx;
            ys[i] = cy;

            stars = string(
                abi.encodePacked(
                    stars,
                    '<circle cx="',
                    _uint2str(cx),
                    '" cy="',
                    _uint2str(cy),
                    '" r="',
                    _uint2str(r),
                    '" fill="',
                    dotColor,
                    '" opacity=".85"/>'
                )
            );
        }

        string memory link = string(
            abi.encodePacked(
                '<path d="M',
                _uint2str(xs[0]),
                " ",
                _uint2str(ys[0]),
                "L",
                _uint2str(xs[1]),
                " ",
                _uint2str(ys[1]),
                "L",
                _uint2str(xs[2]),
                " ",
                _uint2str(ys[2]),
                "L",
                _uint2str(xs[3]),
                " ",
                _uint2str(ys[3]),
                '" stroke="',
                dotColor,
                '" stroke-opacity=".4" stroke-width=".5" fill="none"/>'
            )
        );

        return string(abi.encodePacked(link, stars));
    }

    function _entityGlyph(uint8 entityType) internal pure returns (string memory) {
        if (entityType == ENTITY_AI) {
            return string(
                abi.encodePacked(
                    '<g transform="translate(68 106)" fill="none" stroke="#f8fafc" stroke-linecap="round" stroke-linejoin="round" opacity=".92">',
                    '<path d="M0-22L19-11V11L0 22L-19 11V-11Z" stroke-width="1.5"/>',
                    '<circle cx="0" cy="0" r="9" stroke-width="1.2"/>',
                    '<circle cx="0" cy="0" r="3" fill="#f8fafc">',
                    '<animate attributeName="r" values="2;4;2" dur="2.6s" repeatCount="indefinite"/>',
                    "</circle>",
                    '<path d="M0-22V-30M19-11L26-7M19 11L26 15M0 22V30M-19 11L-26 15M-19-11L-26-7" stroke-width=".8" stroke-opacity=".7"/>',
                    "</g>"
                )
            );
        }

        return string(
            abi.encodePacked(
                '<g transform="translate(68 108)" fill="#f8fafc" opacity=".92">',
                '<circle cx="0" cy="-10" r="9"/>',
                '<path d="M-16 22C-13 8 -7 2 0 2C7 2 13 8 16 22Z"/>',
                '<circle cx="0" cy="-10" r="13" fill="none" stroke="#f8fafc" stroke-width=".8" stroke-opacity=".5"/>',
                "</g>"
            )
        );
    }

    function _opacityPercent(uint256 percent) internal pure returns (string memory) {
        if (percent >= 100) return "1";
        if (percent < 10) return string(abi.encodePacked("0.0", _uint2str(percent)));
        return string(abi.encodePacked("0.", _uint2str(percent)));
    }

    function _colorFromHue(uint8 h, uint8 variant) internal pure returns (string memory) {
        // prettier-ignore
        string[16][3] memory palette = [
            [
                "#e74c3c",
                "#e67e22",
                "#f1c40f",
                "#2ecc71",
                "#1abc9c",
                "#3498db",
                "#6c5ce7",
                "#9b59b6",
                "#e84393",
                "#fd79a8",
                "#00cec9",
                "#0984e3",
                "#fdcb6e",
                "#55efc4",
                "#a29bfe",
                "#dfe6e9"
            ],
            [
                "#c0392b",
                "#d35400",
                "#f39c12",
                "#27ae60",
                "#16a085",
                "#2980b9",
                "#5b4cde",
                "#8e44ad",
                "#d63384",
                "#e6688c",
                "#0097a7",
                "#0772c7",
                "#e5b825",
                "#45d4a8",
                "#8c7be6",
                "#b2bec3"
            ],
            [
                "#ff6b6b",
                "#feca57",
                "#ffeaa7",
                "#55efc4",
                "#81ecec",
                "#74b9ff",
                "#a29bfe",
                "#dfe6e9",
                "#fd79a8",
                "#fab1a0",
                "#7efff5",
                "#a6c5ff",
                "#fff3b0",
                "#b8f5d0",
                "#c8b6ff",
                "#f5f6fa"
            ]
        ];

        return palette[variant % 3][h % 16];
    }

    bytes internal constant BASE64_CHARS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

    function _base64Encode(bytes memory data) internal pure returns (string memory) {
        if (data.length == 0) return "";

        uint256 encodedLen = 4 * ((data.length + 2) / 3);
        bytes memory result = new bytes(encodedLen);

        uint256 i = 0;
        uint256 j = 0;

        for (; i + 3 <= data.length; i += 3) {
            uint24 chunk = uint24(uint8(data[i])) << 16 | uint24(uint8(data[i + 1])) << 8 | uint24(uint8(data[i + 2]));

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
            uint24 chunk = uint24(uint8(data[i])) << 16 | uint24(uint8(data[i + 1])) << 8;
            result[j++] = BASE64_CHARS[chunk >> 18];
            result[j++] = BASE64_CHARS[(chunk >> 12) & 0x3F];
            result[j++] = BASE64_CHARS[(chunk >> 6) & 0x3F];
            result[j++] = bytes1("=");
        }

        return string(result);
    }

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
        bytes memory src = bytes(s);
        bytes memory dst = new bytes(src.length * 5);
        uint256 j = 0;
        for (uint256 i = 0; i < src.length; i++) {
            if (src[i] == "<") {
                dst[j++] = "&";
                dst[j++] = "l";
                dst[j++] = "t";
                dst[j++] = ";";
            } else if (src[i] == ">") {
                dst[j++] = "&";
                dst[j++] = "g";
                dst[j++] = "t";
                dst[j++] = ";";
            } else if (src[i] == "&") {
                dst[j++] = "&";
                dst[j++] = "a";
                dst[j++] = "m";
                dst[j++] = "p";
                dst[j++] = ";";
            } else if (src[i] == '"') {
                dst[j++] = "&";
                dst[j++] = "q";
                dst[j++] = "u";
                dst[j++] = "o";
                dst[j++] = "t";
                dst[j++] = ";";
            } else if (src[i] == "'") {
                dst[j++] = "&";
                dst[j++] = "a";
                dst[j++] = "p";
                dst[j++] = "o";
                dst[j++] = "s";
                dst[j++] = ";";
            } else {
                dst[j++] = src[i];
            }
        }

        bytes memory trimmed = new bytes(j);
        for (uint256 i = 0; i < j; i++) {
            trimmed[i] = dst[i];
        }
        return string(trimmed);
    }

    function _escapeJson(string memory s) internal pure returns (string memory) {
        bytes16 hexDigits = "0123456789abcdef";
        bytes memory src = bytes(s);
        bytes memory dst = new bytes(src.length * 6);
        uint256 j = 0;

        for (uint256 i = 0; i < src.length; i++) {
            uint8 c = uint8(src[i]);
            if (c == 0x22 || c == 0x5c) {
                dst[j++] = bytes1(uint8(0x5c));
                dst[j++] = src[i];
            } else if (c < 0x20) {
                dst[j++] = bytes1(uint8(0x5c));
                dst[j++] = "u";
                dst[j++] = "0";
                dst[j++] = "0";
                dst[j++] = hexDigits[c >> 4];
                dst[j++] = hexDigits[c & 0x0f];
            } else {
                dst[j++] = src[i];
            }
        }

        bytes memory trimmed = new bytes(j);
        for (uint256 i = 0; i < j; i++) {
            trimmed[i] = dst[i];
        }
        return string(trimmed);
    }

    function _nextSeed(uint256 s) internal pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked(s)));
    }

    function _yearOf(uint256 ts) internal pure returns (uint256) {
        return 1970 + ts / 31556952;
    }

    function _splitBio(string memory bio) internal pure returns (string memory line1, string memory line2) {
        bytes memory b = bytes(bio);
        if (b.length <= 28) {
            return (bio, "");
        }

        uint256 cap = b.length < 56 ? b.length : 56;
        uint256 split = 28;

        uint256 searchIndex = 28;
        while (searchIndex > 14) {
            if (b[searchIndex - 1] == 0x20) {
                split = searchIndex - 1;
                break;
            }
            unchecked {
                searchIndex--;
            }
        }

        bytes memory l1 = new bytes(split);
        for (uint256 i = 0; i < split; i++) {
            l1[i] = b[i];
        }

        uint256 start2 = split;
        if (start2 < b.length && b[start2] == 0x20) {
            start2 += 1;
        }
        if (start2 >= cap) {
            return (string(l1), "");
        }

        uint256 len2 = cap - start2;
        bytes memory l2 = new bytes(len2);
        for (uint256 i = 0; i < len2; i++) {
            l2[i] = b[start2 + i];
        }

        return (string(l1), string(l2));
    }
}
