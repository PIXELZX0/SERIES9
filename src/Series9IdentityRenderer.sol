// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

/// @title Series9IdentityRenderer
/// @notice Stateless on-chain metadata renderer for Series9Identity.
contract Series9IdentityRenderer {
    uint8 private constant ENTITY_HUMAN = 0;
    uint8 private constant ENTITY_AI = 1;

    /// @notice 8-slot character avatar configuration. Each field accepts values 0..7.
    struct AvatarConfig {
        uint8 skinTone;
        uint8 hairStyle;
        uint8 hairColor;
        uint8 eyes;
        uint8 mouth;
        uint8 outfit;
        uint8 accessory;
        uint8 background;
    }

    struct RenderProfile {
        string name;
        string bio;
        uint8 entityType;
        uint8 hue;
        uint8 saturation;
        bool verified;
        uint64 registeredAt;
        uint256 reputationScore;
        string handle;
        AvatarConfig avatar;
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
        string memory handle,
        AvatarConfig memory avatar
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
            handle: handle,
            avatar: avatar
        });

        string memory svg = _generateSVG(tokenId, p);

        string memory baseAttrs = string(
            abi.encodePacked(
                '{"trait_type":"Entity Type","value":"',
                p.entityType == ENTITY_AI ? "AI" : "Human",
                '"},{"trait_type":"Verified","value":"',
                p.verified ? "true" : "false",
                '"},{"trait_type":"Hue","value":"',
                _uint2str(p.hue),
                '"},{"trait_type":"Saturation","value":"',
                _uint2str(p.saturation),
                '"},{"trait_type":"Reputation Score","value":"',
                _uint2str(p.reputationScore),
                '"},{"trait_type":"Handle","value":"',
                _escapeJson(p.handle),
                '"}'
            )
        );

        string memory json = string(
            abi.encodePacked(
                '{"name":"',
                _escapeJson(p.name),
                '","description":"Series9 Identity NFT","image":"data:image/svg+xml;base64,',
                _base64Encode(bytes(svg)),
                '","attributes":[',
                baseAttrs,
                ",",
                _avatarTraits(p.avatar),
                "]}"
            )
        );

        return string(abi.encodePacked("data:application/json;base64,", _base64Encode(bytes(json))));
    }

    function _avatarTraits(AvatarConfig memory a) internal pure returns (string memory) {
        return string(
            abi.encodePacked(
                '{"trait_type":"Skin Tone","value":"',
                _skinToneName(a.skinTone),
                '"},{"trait_type":"Hair Style","value":"',
                _hairStyleName(a.hairStyle),
                '"},{"trait_type":"Hair Color","value":"',
                _hairColorName(a.hairColor),
                '"},{"trait_type":"Eyes","value":"',
                _eyesName(a.eyes),
                '"},{"trait_type":"Mouth","value":"',
                _mouthName(a.mouth),
                '"},{"trait_type":"Outfit","value":"',
                _outfitName(a.outfit),
                '"},{"trait_type":"Accessory","value":"',
                _accessoryName(a.accessory),
                '"},{"trait_type":"Background","value":"',
                _backgroundName(a.background),
                '"}'
            )
        );
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
                _renderCharacter(p),
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
                '<clipPath id="nameClip"><rect x="126" y="54" width="194" height="24"/></clipPath>',
                '<clipPath id="handleClip"><rect x="126" y="80" width="194" height="13"/></clipPath>',
                '<clipPath id="bio1Clip"><rect x="126" y="96" width="194" height="14"/></clipPath>',
                '<clipPath id="bio2Clip"><rect x="126" y="110" width="194" height="14"/></clipPath>',
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
                '<text x="126" y="73" font-family="Inter,system-ui,sans-serif" font-size="17" font-weight="700" fill="#f8fafc" letter-spacing="-.2">',
                _escapeXml(p.name),
                "</text>",
                "</g>",
                '<g clip-path="url(#handleClip)">',
                '<text x="126" y="90" font-family="ui-monospace,SFMono-Regular,monospace" font-size="8" font-weight="700" fill="',
                light,
                '" letter-spacing="1.2">',
                bytes(p.handle).length == 0 ? "HANDLE PENDING" : "@",
                _escapeXml(p.handle),
                "</text>",
                "</g>",
                '<g font-family="Inter,system-ui,sans-serif" font-size="9" fill="#cbd5e1">',
                '<g clip-path="url(#bio1Clip)"><text x="126" y="107">',
                _escapeXml(bio1),
                "</text></g>",
                '<g clip-path="url(#bio2Clip)" opacity=".82"><text x="126" y="121">',
                _escapeXml(bio2),
                "</text></g>",
                "</g>",
                '<rect x="126" y="132" width="64" height="3" rx="1.5" fill="url(#hueBar)"/>',
                '<text x="126" y="148" font-family="ui-monospace,SFMono-Regular,monospace" font-size="7" fill="#94a3b8" letter-spacing="1.5">SIG ',
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

    /// @notice Compose the 88x88 character avatar from layered slot renderers.
    /// @dev Avatar lives inside the SVG defs clip `avClip` at (24, 62) of the parent canvas.
    function _renderCharacter(RenderProfile memory p) internal pure returns (string memory) {
        AvatarConfig memory a = p.avatar;
        return string(
            abi.encodePacked(
                "<g>",
                '<rect x="22" y="60" width="92" height="92" rx="20" fill="',
                _colorFromHue(p.hue, 0),
                '" opacity=".22"/>',
                '<rect x="24" y="62" width="88" height="88" rx="18" fill="url(#avBg)"/>',
                '<g clip-path="url(#avClip)">',
                _renderBackground(a.background, p.hue),
                '<g transform="translate(0,8)">',
                _renderBody(a.skinTone, a.outfit),
                _renderMouth(a.mouth),
                _renderEyes(a.eyes),
                _renderHair(a.hairStyle, a.hairColor),
                _renderAccessory(a.accessory),
                "</g>",
                "</g>",
                '<rect x="24" y="62" width="88" height="88" rx="18" fill="none" stroke="#ffffff" stroke-opacity=".22" stroke-width="1"/>',
                "</g>"
            )
        );
    }

    // ─────────────────── Avatar palettes ───────────────────

    /// @dev Skin tone palette. 0=light, 1=tan, 2=brown, 3=dark, 4=olive, 5=pink, 6=alien green, 7=robot gray.
    function _skinColor(uint8 tone) internal pure returns (string memory) {
        if (tone == 0) return "#ffe0bd";
        if (tone == 1) return "#f1c27d";
        if (tone == 2) return "#c68642";
        if (tone == 3) return "#8d5524";
        if (tone == 4) return "#d4a373";
        if (tone == 5) return "#ffc1cc";
        if (tone == 6) return "#9ee493";
        return "#b0bec5"; // robot
    }

    function _hairColorHex(uint8 c) internal pure returns (string memory) {
        if (c == 0) return "#1a1a1a";
        if (c == 1) return "#6f4e37";
        if (c == 2) return "#f0e68c";
        if (c == 3) return "#c1440e";
        if (c == 4) return "#808080";
        if (c == 5) return "#f5f5f5";
        if (c == 6) return "#3b82f6";
        return "#8b5cf6";
    }

    function _outfitColor(uint8 o) internal pure returns (string memory) {
        if (o == 0) return "#3b82f6"; // tee
        if (o == 1) return "#22c55e"; // hoodie
        if (o == 2) return "#1e293b"; // suit
        if (o == 3) return "#ef4444"; // tank
        if (o == 4) return "#9333ea"; // jacket
        if (o == 5) return "#ec4899"; // dress
        if (o == 6) return "#94a3b8"; // armor
        return "#64748b"; // none/bare neutral
    }

    // ─────────────────── Avatar layers ───────────────────

    function _renderBackground(uint8 opt, uint8 hue) internal pure returns (string memory) {
        string memory primary = _colorFromHue(hue, 0);
        string memory light = _colorFromHue(hue, 2);

        if (opt == 0) {
            return string(abi.encodePacked('<rect x="24" y="62" width="88" height="88" fill="', primary, '" opacity=".55"/>'));
        }
        if (opt == 1) {
            return string(
                abi.encodePacked(
                    '<rect x="24" y="62" width="88" height="44" fill="',
                    light,
                    '" opacity=".55"/>',
                    '<rect x="24" y="106" width="88" height="44" fill="',
                    primary,
                    '" opacity=".55"/>'
                )
            );
        }
        if (opt == 2) {
            return string(
                abi.encodePacked(
                    '<rect x="24" y="62" width="88" height="88" fill="',
                    primary,
                    '" opacity=".4"/>',
                    '<rect x="24" y="74" width="88" height="6" fill="',
                    light,
                    '" opacity=".55"/>',
                    '<rect x="24" y="100" width="88" height="6" fill="',
                    light,
                    '" opacity=".55"/>',
                    '<rect x="24" y="126" width="88" height="6" fill="',
                    light,
                    '" opacity=".55"/>'
                )
            );
        }
        if (opt == 3) {
            return string(
                abi.encodePacked(
                    '<rect x="24" y="62" width="88" height="88" fill="',
                    primary,
                    '" opacity=".4"/>',
                    '<g fill="',
                    light,
                    '" opacity=".7">',
                    '<circle cx="36" cy="74" r="2"/><circle cx="60" cy="74" r="2"/><circle cx="84" cy="74" r="2"/>',
                    '<circle cx="48" cy="92" r="2"/><circle cx="72" cy="92" r="2"/><circle cx="96" cy="92" r="2"/>',
                    '<circle cx="36" cy="110" r="2"/><circle cx="60" cy="110" r="2"/><circle cx="84" cy="110" r="2"/>',
                    '<circle cx="48" cy="128" r="2"/><circle cx="72" cy="128" r="2"/><circle cx="96" cy="128" r="2"/>',
                    "</g>"
                )
            );
        }
        if (opt == 4) {
            return string(
                abi.encodePacked(
                    '<rect x="24" y="62" width="88" height="88" fill="',
                    primary,
                    '" opacity=".35"/>',
                    '<g stroke="',
                    light,
                    '" stroke-opacity=".55" stroke-width=".5" fill="none">',
                    '<path d="M40 62v88M56 62v88M72 62v88M88 62v88M104 62v88M24 78h88M24 94h88M24 110h88M24 126h88M24 142h88"/>',
                    "</g>"
                )
            );
        }
        if (opt == 5) {
            return string(
                abi.encodePacked(
                    '<rect x="24" y="62" width="88" height="88" fill="#0f172a" opacity=".75"/>',
                    '<g fill="#f8fafc">',
                    '<circle cx="32" cy="70" r="1"/><circle cx="46" cy="80" r=".8"/><circle cx="58" cy="68" r="1.2"/>',
                    '<circle cx="72" cy="76" r=".9"/><circle cx="88" cy="72" r="1"/><circle cx="100" cy="84" r=".8"/>',
                    '<circle cx="40" cy="100" r=".7"/><circle cx="80" cy="108" r="1"/><circle cx="106" cy="120" r=".9"/>',
                    '<circle cx="30" cy="132" r="1"/><circle cx="64" cy="140" r=".8"/><circle cx="96" cy="144" r="1.1"/>',
                    "</g>"
                )
            );
        }
        if (opt == 6) {
            return string(
                abi.encodePacked(
                    '<rect x="24" y="62" width="88" height="88" fill="',
                    primary,
                    '" opacity=".4"/>',
                    '<g stroke="',
                    light,
                    '" stroke-opacity=".7" stroke-width=".7" fill="none">',
                    '<path d="M68 106L24 62M68 106L112 62M68 106L24 150M68 106L112 150M68 106L24 106M68 106L112 106M68 106L68 62M68 106L68 150"/>',
                    "</g>"
                )
            );
        }
        return string(
            abi.encodePacked(
                '<rect x="24" y="62" width="88" height="88" fill="#1a103d" opacity=".85"/>',
                '<circle cx="40" cy="80" r="14" fill="',
                primary,
                '" opacity=".5"/>',
                '<circle cx="90" cy="120" r="20" fill="',
                light,
                '" opacity=".4"/>',
                '<circle cx="68" cy="100" r="8" fill="#f8fafc" opacity=".25"/>'
            )
        );
    }

    function _renderBody(uint8 skinTone, uint8 outfit) internal pure returns (string memory) {
        string memory skin = _skinColor(skinTone);
        return string(
            abi.encodePacked(
                _renderOutfit(outfit, skin),
                '<rect x="62" y="86" width="12" height="10" fill="',
                skin,
                '"/>',
                '<circle cx="68" cy="80" r="22" fill="',
                skin,
                '"/>'
            )
        );
    }

    function _renderOutfit(uint8 o, string memory skin) internal pure returns (string memory) {
        string memory color = _outfitColor(o);
        if (o == 0) {
            return string(
                abi.encodePacked(
                    '<path d="M40 150 Q40 116 60 110 L76 110 Q96 116 96 150 Z" fill="',
                    color,
                    '"/>'
                )
            );
        }
        if (o == 1) {
            return string(
                abi.encodePacked(
                    '<path d="M36 150 Q36 114 56 108 L80 108 Q100 114 100 150 Z" fill="',
                    color,
                    '"/>',
                    '<path d="M52 96 Q68 90 84 96 L82 112 L54 112 Z" fill="',
                    color,
                    '" opacity=".85"/>'
                )
            );
        }
        if (o == 2) {
            return string(
                abi.encodePacked(
                    '<path d="M40 150 Q40 116 58 110 L78 110 Q96 116 96 150 Z" fill="',
                    color,
                    '"/>',
                    '<path d="M58 110 L68 130 L78 110 Z" fill="#f8fafc"/>',
                    '<path d="M68 112 L66 124 L68 128 L70 124 Z" fill="#ef4444"/>'
                )
            );
        }
        if (o == 3) {
            return string(
                abi.encodePacked(
                    '<path d="M48 150 Q48 118 60 112 L76 112 Q88 118 88 150 Z" fill="',
                    color,
                    '"/>',
                    '<rect x="58" y="100" width="4" height="14" fill="',
                    color,
                    '"/>',
                    '<rect x="74" y="100" width="4" height="14" fill="',
                    color,
                    '"/>'
                )
            );
        }
        if (o == 4) {
            return string(
                abi.encodePacked(
                    '<path d="M36 150 Q36 116 56 110 L80 110 Q100 116 100 150 Z" fill="',
                    color,
                    '"/>',
                    '<path d="M56 110 L60 138 L68 116 L76 138 L80 110 Z" fill="#1e293b"/>'
                )
            );
        }
        if (o == 5) {
            return string(
                abi.encodePacked(
                    '<path d="M30 150 Q34 120 60 114 L76 114 Q102 120 106 150 Z" fill="',
                    color,
                    '"/>',
                    '<path d="M56 114 Q68 108 80 114 L78 122 L58 122 Z" fill="',
                    color,
                    '" opacity=".7"/>'
                )
            );
        }
        if (o == 6) {
            return string(
                abi.encodePacked(
                    '<path d="M38 150 L38 116 L58 108 L78 108 L98 116 L98 150 Z" fill="',
                    color,
                    '"/>',
                    '<path d="M50 116 L86 116 L86 140 L50 140 Z" fill="#cbd5e1" opacity=".5"/>',
                    '<circle cx="68" cy="128" r="3" fill="#fbbf24"/>'
                )
            );
        }
        return string(
            abi.encodePacked(
                '<path d="M48 150 Q48 120 60 114 L76 114 Q88 120 88 150 Z" fill="',
                skin,
                '" opacity=".9"/>'
            )
        );
    }

    function _renderMouth(uint8 opt) internal pure returns (string memory) {
        if (opt == 0) {
            return '<rect x="62" y="90" width="12" height="2" rx="1" fill="#3a2a1a"/>';
        }
        if (opt == 1) {
            return '<path d="M60 88 Q68 96 76 88" stroke="#3a2a1a" stroke-width="1.6" fill="none" stroke-linecap="round"/>';
        }
        if (opt == 2) {
            return string(
                abi.encodePacked(
                    '<path d="M58 88 Q68 98 78 88 L78 92 Q68 100 58 92 Z" fill="#3a2a1a"/>',
                    '<rect x="60" y="90" width="16" height="2" fill="#f8fafc"/>'
                )
            );
        }
        if (opt == 3) {
            return '<ellipse cx="68" cy="91" rx="5" ry="4" fill="#3a2a1a"/>';
        }
        if (opt == 4) {
            return string(
                abi.encodePacked(
                    '<ellipse cx="68" cy="91" rx="6" ry="4" fill="#3a2a1a"/>',
                    '<ellipse cx="68" cy="93" rx="3" ry="2" fill="#f472b6"/>'
                )
            );
        }
        if (opt == 5) {
            return '<path d="M60 94 Q68 86 76 94" stroke="#3a2a1a" stroke-width="1.6" fill="none" stroke-linecap="round"/>';
        }
        if (opt == 6) {
            return '<path d="M60 92 Q66 88 76 90" stroke="#3a2a1a" stroke-width="1.6" fill="none" stroke-linecap="round"/>';
        }
        return string(
            abi.encodePacked(
                '<path d="M62 88 Q60 92 64 94" stroke="#3a2a1a" stroke-width="1.4" fill="none" stroke-linecap="round"/>',
                '<path d="M68 88 L68 94" stroke="#3a2a1a" stroke-width="1.4" stroke-linecap="round"/>',
                '<path d="M74 88 Q76 92 72 94" stroke="#3a2a1a" stroke-width="1.4" fill="none" stroke-linecap="round"/>'
            )
        );
    }

    function _renderEyes(uint8 opt) internal pure returns (string memory) {
        if (opt == 0) {
            return '<g fill="#1a1a1a"><circle cx="60" cy="78" r="1.6"/><circle cx="76" cy="78" r="1.6"/></g>';
        }
        if (opt == 1) {
            return string(
                abi.encodePacked(
                    '<g><circle cx="60" cy="78" r="2.8" fill="#1a1a1a"/><circle cx="76" cy="78" r="2.8" fill="#1a1a1a"/>',
                    '<circle cx="61" cy="77" r="1" fill="#f8fafc"/><circle cx="77" cy="77" r="1" fill="#f8fafc"/></g>'
                )
            );
        }
        if (opt == 2) {
            return string(
                abi.encodePacked(
                    '<g stroke="#1a1a1a" stroke-width="1.5" stroke-linecap="round" fill="none">',
                    '<path d="M56 78 L62 76"/><path d="M62 76 L62 80"/>',
                    '<path d="M80 78 L74 76"/><path d="M74 76 L74 80"/></g>'
                )
            );
        }
        if (opt == 3) {
            return '<g stroke="#1a1a1a" stroke-width="1.6" stroke-linecap="round" fill="none"><path d="M56 78 Q60 80 64 78"/><path d="M72 78 Q76 80 80 78"/></g>';
        }
        if (opt == 4) {
            return string(
                abi.encodePacked(
                    '<g fill="#1a1a1a"><circle cx="60" cy="78" r="2"/></g>',
                    '<path d="M72 78 Q76 78 80 78" stroke="#1a1a1a" stroke-width="1.6" stroke-linecap="round" fill="none"/>'
                )
            );
        }
        if (opt == 5) {
            return string(
                abi.encodePacked(
                    '<g fill="#fbbf24"><path d="M60 74 L61 77 L64 78 L61 79 L60 82 L59 79 L56 78 L59 77 Z"/>',
                    '<path d="M76 74 L77 77 L80 78 L77 79 L76 82 L75 79 L72 78 L75 77 Z"/></g>'
                )
            );
        }
        if (opt == 6) {
            return '<rect x="50" y="74" width="36" height="8" rx="3" fill="#1a1a1a"/><rect x="52" y="76" width="32" height="2" fill="#38bdf8" opacity=".7"/>';
        }
        return '<g stroke="#1a1a1a" stroke-width="1.5" stroke-linecap="round" fill="none"><path d="M56 78 L64 78"/><path d="M72 78 L80 78"/></g>';
    }

    function _renderHair(uint8 style, uint8 color) internal pure returns (string memory) {
        if (style == 0) {
            return "";
        }
        string memory hc = _hairColorHex(color);
        if (style == 1) {
            return string(
                abi.encodePacked('<path d="M48 62 Q68 50 88 62 L88 70 Q68 60 48 70 Z" fill="', hc, '"/>')
            );
        }
        if (style == 2) {
            return string(
                abi.encodePacked(
                    '<path d="M46 60 Q68 48 90 60 L92 96 L84 90 L84 70 Q68 60 52 70 L52 90 L44 96 Z" fill="',
                    hc,
                    '"/>'
                )
            );
        }
        if (style == 3) {
            return string(
                abi.encodePacked(
                    '<path d="M48 64 Q68 52 88 64 L88 74 Q68 64 48 74 Z" fill="',
                    hc,
                    '"/>',
                    '<ellipse cx="92" cy="82" rx="6" ry="10" fill="',
                    hc,
                    '"/>'
                )
            );
        }
        if (style == 4) {
            return string(
                abi.encodePacked(
                    '<circle cx="68" cy="54" r="8" fill="',
                    hc,
                    '"/>',
                    '<path d="M50 64 Q68 56 86 64 L86 72 Q68 64 50 72 Z" fill="',
                    hc,
                    '"/>'
                )
            );
        }
        if (style == 5) {
            return string(
                abi.encodePacked(
                    '<g fill="',
                    hc,
                    '"><circle cx="52" cy="62" r="6"/><circle cx="62" cy="56" r="6"/><circle cx="74" cy="56" r="6"/><circle cx="84" cy="62" r="6"/><circle cx="50" cy="74" r="5"/><circle cx="86" cy="74" r="5"/></g>'
                )
            );
        }
        if (style == 6) {
            return string(
                abi.encodePacked(
                    '<path d="M64 50 L62 80 L74 80 L72 50 Z" fill="',
                    hc,
                    '"/>'
                )
            );
        }
        return string(
            abi.encodePacked(
                '<path d="M44 70 Q68 50 92 70 L92 78 L44 78 Z" fill="',
                hc,
                '"/>',
                '<rect x="42" y="74" width="52" height="4" fill="#1a1a1a"/>'
            )
        );
    }

    function _renderAccessory(uint8 opt) internal pure returns (string memory) {
        if (opt == 0) {
            return "";
        }
        if (opt == 1) {
            return string(
                abi.encodePacked(
                    '<g stroke="#1a1a1a" stroke-width="1.4" fill="none">',
                    '<circle cx="60" cy="78" r="5"/><circle cx="76" cy="78" r="5"/>',
                    '<path d="M65 78 L71 78"/></g>'
                )
            );
        }
        if (opt == 2) {
            return string(
                abi.encodePacked(
                    '<g fill="#0f172a">',
                    '<rect x="54" y="74" width="12" height="8" rx="2"/>',
                    '<rect x="70" y="74" width="12" height="8" rx="2"/>',
                    '<rect x="66" y="77" width="4" height="2"/></g>'
                )
            );
        }
        if (opt == 3) {
            return '<g fill="#fbbf24"><circle cx="46" cy="86" r="2"/><circle cx="90" cy="86" r="2"/></g>';
        }
        if (opt == 4) {
            return string(
                abi.encodePacked(
                    '<path d="M52 102 Q68 116 84 102" stroke="#fbbf24" stroke-width="1.4" fill="none"/>',
                    '<circle cx="68" cy="112" r="3" fill="#ef4444"/>'
                )
            );
        }
        if (opt == 5) {
            return '<rect x="54" y="85" width="28" height="12" rx="3" fill="#f8fafc" opacity=".85"/>';
        }
        if (opt == 6) {
            return string(
                abi.encodePacked(
                    '<path d="M44 78 Q44 56 68 56 Q92 56 92 78" stroke="#1a1a1a" stroke-width="2.5" fill="none"/>',
                    '<rect x="40" y="76" width="10" height="14" rx="3" fill="#1a1a1a"/>',
                    '<rect x="86" y="76" width="10" height="14" rx="3" fill="#1a1a1a"/>'
                )
            );
        }
        return string(
            abi.encodePacked(
                '<path d="M50 62 L54 50 L58 60 L62 46 L68 58 L74 46 L78 60 L82 50 L86 62 Z" fill="#fbbf24" stroke="#b45309" stroke-width=".6"/>',
                '<circle cx="68" cy="54" r="1.5" fill="#ef4444"/>'
            )
        );
    }

    // ─────────────────── Avatar trait name helpers ───────────────────

    function _skinToneName(uint8 v) internal pure returns (string memory) {
        if (v == 0) return "Light";
        if (v == 1) return "Tan";
        if (v == 2) return "Brown";
        if (v == 3) return "Dark";
        if (v == 4) return "Olive";
        if (v == 5) return "Pink";
        if (v == 6) return "Alien";
        return "Robot";
    }

    function _hairStyleName(uint8 v) internal pure returns (string memory) {
        if (v == 0) return "Bald";
        if (v == 1) return "Short";
        if (v == 2) return "Long";
        if (v == 3) return "Ponytail";
        if (v == 4) return "Bun";
        if (v == 5) return "Curly";
        if (v == 6) return "Mohawk";
        return "Hat";
    }

    function _hairColorName(uint8 v) internal pure returns (string memory) {
        if (v == 0) return "Black";
        if (v == 1) return "Brown";
        if (v == 2) return "Blonde";
        if (v == 3) return "Red";
        if (v == 4) return "Gray";
        if (v == 5) return "White";
        if (v == 6) return "Blue";
        return "Purple";
    }

    function _eyesName(uint8 v) internal pure returns (string memory) {
        if (v == 0) return "Dot";
        if (v == 1) return "Round";
        if (v == 2) return "Sharp";
        if (v == 3) return "Sleepy";
        if (v == 4) return "Wink";
        if (v == 5) return "Star";
        if (v == 6) return "Visor";
        return "Closed";
    }

    function _mouthName(uint8 v) internal pure returns (string memory) {
        if (v == 0) return "Neutral";
        if (v == 1) return "Smile";
        if (v == 2) return "Grin";
        if (v == 3) return "Open";
        if (v == 4) return "Tongue";
        if (v == 5) return "Frown";
        if (v == 6) return "Smirk";
        return "Heh";
    }

    function _outfitName(uint8 v) internal pure returns (string memory) {
        if (v == 0) return "Tee";
        if (v == 1) return "Hoodie";
        if (v == 2) return "Suit";
        if (v == 3) return "Tank";
        if (v == 4) return "Jacket";
        if (v == 5) return "Dress";
        if (v == 6) return "Armor";
        return "Bare";
    }

    function _accessoryName(uint8 v) internal pure returns (string memory) {
        if (v == 0) return "None";
        if (v == 1) return "Glasses";
        if (v == 2) return "Sunglasses";
        if (v == 3) return "Earring";
        if (v == 4) return "Necklace";
        if (v == 5) return "Mask";
        if (v == 6) return "Headphones";
        return "Crown";
    }

    function _backgroundName(uint8 v) internal pure returns (string memory) {
        if (v == 0) return "Solid";
        if (v == 1) return "Gradient";
        if (v == 2) return "Stripes";
        if (v == 3) return "Dots";
        if (v == 4) return "Grid";
        if (v == 5) return "Starfield";
        if (v == 6) return "Rays";
        return "Cosmic";
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
