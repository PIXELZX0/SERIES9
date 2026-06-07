# Series9IdentityRenderer

| 항목 | 값 |
|------|----|
| 파일 | [`src/Series9IdentityRenderer.sol`](../src/Series9IdentityRenderer.sol) |
| 라인 수 | 1,150 |
| 상속 | 없음 |
| 배포 형태 | **독립 배포 없음**. `Series9Identity`가 base contract로 상속 |
| 모든 함수 | `internal pure` (외부 노출 0개) |

## 개요

`Series9IdentityRenderer`는 `Series9Identity`의 `tokenURI(tokenId)` 호출에 응답하기 위한
**상태 없는 온체인 메타데이터 생성기**입니다.
프로필 데이터(이름/바이오/색상/엔티티 타입 등)와 `AvatarConfig`를 받아
SVG 이미지 + JSON 메타데이터를 합쳐 base64로 인코딩한 `data:` URI를 반환합니다.

외부 의존성/스토리지가 없어 가스 비용은 입력 길이에만 비례합니다.

## 핵심 데이터 구조

```solidity
struct AvatarConfig {
    uint8 skinTone;   // 0..7
    uint8 hairStyle;  // 0..7
    uint8 hairColor;  // 0..7
    uint8 eyes;       // 0..7
    uint8 mouth;      // 0..7
    uint8 outfit;     // 0..7
    uint8 accessory;  // 0..7
    uint8 background; // 0..7
}

struct RenderProfile {
    string name; string bio;
    uint8 entityType;  // 0 = Human, 1 = AI
    uint8 hue; uint8 saturation;
    bool verified; uint64 registeredAt;
    uint256 reputationScore;
    string handle;
    AvatarConfig avatar;
}
```

## 진입점

### `_renderTokenURI(tokenId, name, bio, entityType, hue, saturation, verified, registeredAt, reputationScore, handle, avatar) -> string`

`Series9Identity.tokenURI(tokenId)`가 직접 호출하는 함수.

처리 흐름:
1. 입력값을 `RenderProfile`로 묶음
2. `_generateSVG(tokenId, p)`로 SVG 문자열 생성
3. JSON 속성(`attributes` 배열)을 구성: 기본 6개 + 아바타 8개
4. 전체 JSON을 base64 인코딩하여 `data:application/json;base64,...` 형태로 반환

### `_generateSVG(tokenId, p) -> string`
1. `hue` / `saturation`을 기반으로 primary/dark/light/accent 색 4종 산출
2. `_svgHead` — `<defs>`, gradient, clipPath 정의
3. `_entityBadge`, `_verifiedBadge` — 우상단 배지
4. `_renderCharacter` — 배경/몸/옷/얼굴/머리/액세서리 합성
5. `_svgBody` — 좌측 텍스트 영역(name/handle/bio 2줄), 하단 푸터, 토큰 ID 표시

## 함수 목록 (전부 `internal pure`)

### Rendering 메인
- `_renderTokenURI(...)`
- `_avatarTraits(AvatarConfig)`
- `_generateSVG(uint256, RenderProfile)`
- `_svgHead(tokenId, primary, dark, light, accent, bloomOpacity)`
- `_svgBody(tokenId, RenderProfile, light)`

### 배지
- `_entityBadge(uint8 entityType)` — `Human`/`AI` 표시
- `_verifiedBadge(bool verified)` — 인증 마크

### 캐릭터 합성
- `_renderCharacter(RenderProfile)` — 배경 + body + outfit + eyes + mouth + hair + accessory 순서 합성
- `_renderBackground(uint8 opt, uint8 hue)` — 8종 배경 패턴
- `_renderBody(uint8 skinTone, uint8 outfit)`
- `_renderOutfit(uint8 o, string skin)`
- `_renderMouth(uint8 opt)` — 8종 표정
- `_renderEyes(uint8 opt)` — 8종 눈 스타일
- `_renderHair(uint8 style, uint8 color)`
- `_renderAccessory(uint8 opt)`

### Palette
- `_skinColor(uint8 tone)` — 피부톤 16진수
- `_hairColorHex(uint8 c)`
- `_outfitColor(uint8 o)`
- `_colorFromHue(uint8 h, uint8 variant)` — hue/variant 조합으로 16색 팔레트 산출

### 라벨 (JSON `attributes`용)
- `_skinToneName`, `_hairStyleName`, `_hairColorName`, `_eyesName`, `_mouthName`, `_outfitName`, `_accessoryName`, `_backgroundName`

### 유틸리티
- `_opacityPercent(uint256 percent)` — 0..100을 "0.xx" 문자열로
- `_base64Encode(bytes)` — RFC4648 base64
- `_uint2str(uint256)` — 10진수 ASCII
- `_escapeXml(string)` — SVG 안전 이스케이프 (`& < > " '`)
- `_escapeJson(string)` — JSON 안전 이스케이프 (`" \\` 및 제어문자 `\\uXXXX`)
- `_nextSeed(uint256)` — keccak 기반 의사난수 progression
- `_yearOf(uint256 ts)` — Unix timestamp → 연도 (간단 산식)
- `_splitBio(string)` — bio를 2줄로 분리

## 출력 예시

`tokenURI` 반환은 `data:application/json;base64,...` 형태이며, 디코드하면 다음과 같은 JSON:

```json
{
  "name": "alice",
  "description": "Series9 Identity NFT",
  "image": "data:image/svg+xml;base64,...",
  "attributes": [
    {"trait_type":"Entity Type","value":"Human"},
    {"trait_type":"Verified","value":"true"},
    {"trait_type":"Hue","value":"42"},
    {"trait_type":"Saturation","value":"200"},
    {"trait_type":"Reputation Score","value":"9"},
    {"trait_type":"Handle","value":"alice"},
    {"trait_type":"Skin Tone","value":"..."},
    {"trait_type":"Hair Style","value":"..."},
    {"trait_type":"Hair Color","value":"..."},
    {"trait_type":"Eyes","value":"..."},
    {"trait_type":"Mouth","value":"..."},
    {"trait_type":"Outfit","value":"..."},
    {"trait_type":"Accessory","value":"..."},
    {"trait_type":"Background","value":"..."}
  ]
}
```

## SVG 캔버스 사양

- 뷰박스: `0 0 340 200`, 라운드 코너 18px
- 베이스 색: `#070b1a` (어두운 남청), bloom 그라데이션 오버레이
- 좌측: 88×88 아바타 영역 (`avClip` clip-path), 우측: name/handle/bio 텍스트
- 하단: 토큰 ID + 등록 연도 푸터

## 구현 상태

| 기능 | 상태 |
|------|------|
| `_renderTokenURI` 진입점 | 완전 구현 |
| 8슬롯 아바타 합성 | 완전 구현 (skin/hair/eyes/mouth/outfit/accessory/background) |
| Entity 배지 (Human/AI) | 완전 구현 |
| Verified 배지 | 완전 구현 |
| Reputation/Handle/Hue/Saturation 트레잇 노출 | 완전 구현 |
| `data:` URI base64 인코딩 | 완전 구현 |
| XML / JSON 이스케이프 | 완전 구현 |
| 외부 호출 가능 함수 | **0개** — 모두 `internal`이므로 base contract로만 사용 |
| 스토리지 사용 | **0 슬롯** — 상태 없음 |

## 보안/품질 노트

1. **순수 함수**: 모든 함수가 `internal pure` — 외부 호출 차단 + 가스 측정 안정성.
2. **이스케이프 처리**: `_escapeXml`은 SVG 인젝션 방지, `_escapeJson`은 JSON 파서 안전성 보장.
3. **결정론적 렌더링**: 같은 입력이면 항상 같은 출력 (스토리지 의존 없음).
4. **확장성**: 새 슬롯/팔레트를 추가하려면 `AvatarConfig` 구조와 모든 `_*Name` 라벨 함수, 렌더 함수를 함께 업데이트해야 함. `Series9Identity`의 storage layout(`avatarConfig`)도 동일 구조여야 하므로 업그레이드 시 주의.

## Series9Identity와의 관계

```solidity
contract Series9Identity is
    Initializable,
    ERC721Upgradeable,
    OwnableUpgradeable,
    PausableUpgradeable,
    ReentrancyGuard,
    UUPSUpgradeable,
    Series9IdentityRenderer  // ← 상속만, 별도 배포 없음
{
    // ...
    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        // profile, avatarConfig 조회 후 _renderTokenURI(...) 호출
    }
}
```

**중요**: `Series9IdentityRenderer`는 **자체 배포되지 않습니다**. 업그레이드 시 Renderer 변경이 필요하면
`Series9Identity` implementation을 새로 빌드/배포한 뒤 `upgradeToAndCall`로 교체하는 방식입니다.
