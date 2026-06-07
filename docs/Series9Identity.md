# Series9Identity

| 항목 | 값 |
|------|----|
| 파일 | [`src/Series9Identity.sol`](../src/Series9Identity.sol) |
| 라인 수 | 1,151 |
| 상속 | `Initializable`, `ERC721Upgradeable`, `OwnableUpgradeable`, `PausableUpgradeable`, `ReentrancyGuard`, `UUPSUpgradeable`, [`Series9IdentityRenderer`](./Series9IdentityRenderer.md) |
| 이름 / 심볼 | `Series9 Identity` / `S9ID` |
| 업그레이드 | UUPS, `_authorizeUpgrade` = `onlyOwner` |

## 개요

`Series9Identity`는 **1 주소당 최대 1개**의 정체성 ERC721 NFT를 발행하는 컨트랙트입니다.

- Mint 시 `Human` 또는 `AI` 유형을 선택하고 유형별 SER9 수수료를 납부합니다.
- 수수료는 본 컨트랙트가 받은 즉시 `Series9Staking.stake(fee)`로 자동 스테이킹됩니다.
- 스테이킹에서 발생한 SER9 보상은 `collectStakingRewards()`로 끌어와
  **각 identity의 reputation score 비율**로 NFT 보유자에게 분배됩니다.
  (기본값: Human = 9, AI = 1, owner가 token별로 조정 가능)
- 각 identity는 고유한 **payment handle**(예: `alice`)을 등록할 수 있고,
  다른 사용자가 `payToHandle`로 ERC20/MON을 송금하거나
  `createPaymentRequest` → `payPaymentRequest`로 청구/결제 흐름을 사용할 수 있습니다.
- EIP-712 서명으로 결제 권한을 **위임**(`payPaymentRequestWithSig`)할 수 있어, 가스/실행 주체와 자금 출처 분리 가능.
- 메타데이터(SVG/JSON)는 100% 온체인으로 `Series9IdentityRenderer`가 생성합니다.

## 주요 상수

| 이름 | 값 | 의미 |
|------|----|------|
| `PRECISION` | `1e18` | reward 인덱스 스케일 |
| `NATIVE_MON` | `address(0)` | MON 결제 표기 |
| `MAX_AVATAR_SEED_BYTES` | `64` | (deprecated) 커스텀 시드 최대 |
| `MAX_AVATAR_SLOT_OPTION` | `7` | 8슬롯 아바타 각 필드 0~7 |
| `MIN_HANDLE_BYTES` / `MAX_HANDLE_BYTES` | `3` / `32` | handle 길이 제한 |
| `MAX_PAYMENT_MEMO_BYTES` | `128` | memo 최대 |
| `LEGACY_HANDLE_PRIORITY_DURATION` | `30 days` | 기존 보유자가 legacy handle을 우선 클레임할 수 있는 기간 |
| `DEFAULT_HUMAN_REPUTATION_SCORE` | `9` | Human 기본 reputation |
| `DEFAULT_AI_REPUTATION_SCORE` | `1` | AI 기본 reputation |
| `MAX_REPUTATION_SCORE` | `1_000_000` | per-token 상한 |

## 데이터 구조

```solidity
enum EntityType { Human, AI }
enum PaymentRequestStatus { None, Pending, Paid, Cancelled, Expired }

struct IdentityProfile {
    string name; string bio; EntityType entityType;
    uint8 hue; uint8 saturation; bool verified; uint64 registeredAt;
}

struct LegacyHandleReservation { uint256 tokenId; uint64 expiresAt; }

struct PaymentRequest {
    uint256 payerTokenId; uint256 payeeTokenId;
    address token; uint256 amount; uint64 dueAt;
    PaymentRequestStatus status; string memo;
}

// Series9IdentityRenderer에서 상속
struct AvatarConfig {
    uint8 skinTone; uint8 hairStyle; uint8 hairColor; uint8 eyes;
    uint8 mouth; uint8 outfit; uint8 accessory; uint8 background;
}
```

## 스토리지 레이아웃

### Identity core
- `uint256 private _nextTokenId` — 1부터 증가
- `mapping(uint256 => IdentityProfile) public profiles`
- `mapping(address => uint256) public ownerTokenId` — **1 주소 1 NFT**
- `mapping(uint256 => string) public customAvatarSeed` — **deprecated**, 렌더러 무시
- `mapping(uint256 => AvatarConfig) public avatarConfig` — 8슬롯 아바타

### 결제 인프라
- `IERC20 public ser9`, `address public stakingContract`
- `uint256 public aiMintFee`, `humanMintFee`

### NFT 보상 분배
- `uint256 public nftRewardPerToken` (PRECISION 스케일, 1 reputation당)
- `mapping(address => uint256) public nftUserRewardPerTokenPaid / nftRewards`
- `mapping(uint256 => uint256) public reputationScores` — 0이면 entity 기본값 사용
- `uint256 public totalReputationScore` — 0이고 token 발행 이력이 있으면 `_computeTotalReputationScore`로 재계산

### Handle
- `mapping(uint256 => string) public handles`
- `mapping(bytes32 => uint256) private _tokenIdByHandleHash`
- `mapping(bytes32 => LegacyHandleReservation) private _legacyHandleReservations`
- `uint256 public legacyHandleReservationCursor`
- `uint64 public legacyHandlePriorityDeadline`
- `bool public legacyHandleReservationsFinalized`

### Payment
- `uint256 private _nextPaymentId`, `_nextPaymentRequestId`
- `mapping(uint256 => PaymentRequest) private _paymentRequests`
- `mapping(uint256 => uint256[]) private _payerPaymentRequestIds / _payeePaymentRequestIds`
- `mapping(address => uint256) public paymentNonces` — EIP-712 서명 nonce

### Storage gap
- `uint256[35] private __gap`

## Initialize

### `initialize(initialOwner, ser9Token, stakingContract_, initialAIMintFee, initialHumanMintFee)`
- 이름/심볼 `"Series9 Identity"` / `"S9ID"` 설정
- ser9 / stakingContract / 수수료 저장
- `_nextTokenId = 1`, `_nextPaymentId = 1`, `_nextPaymentRequestId = 1`
- `legacyHandleReservationCursor = 1`, `legacyHandleReservationsFinalized = true` (신규 배포에는 legacy 없음)

### `initializePayment() reinitializer(2) onlyOwner`
기존 v1 identity 프록시에 결제 기능을 백필.
- 0으로 남아있는 결제 카운터를 1로 셋업.
- `legacyHandleReservationCursor = 1`, `legacyHandleReservationsFinalized = false`
- `legacyHandlePriorityDeadline = block.timestamp + 30 days` — 이 기간 동안 기존 identity 보유자가 자신의 profile name 기반 slug를 우선 점유 가능.

## 외부/공개 함수

### Mint

| 함수 | 보호 | 동작 |
|------|------|------|
| `mintIdentity(name, bio, entityType, hue, saturation)` | whenNotPaused, nonReentrant | 1 주소당 최대 1개. entityType에 따라 `humanMintFee` 또는 `aiMintFee` SER9를 `transferFrom`으로 받아 즉시 `Series9Staking.stake(fee)`. NFT 발행 + `reputationScores[tokenId] = 기본값` |
| `mintIdentityWithHandle(...handle)` | 동일 | 위와 같지만 `_requireHandleRegistrationReady()` 확인 후 handle도 1-tx 등록 |

수수료 처리는 SER9 잔액 변화를 확인 (`balanceBefore`/`balanceAfter`)하여 staking이 실제로 풀로 들어갔는지 검증 — 실패 시 `StakingFailed`.

### 보상 (NFT 보유자)

| 함수 | 보호 | 동작 |
|------|------|------|
| `collectStakingRewards()` | whenNotPaused, nonReentrant | **누구나 호출 가능**. `Series9Staking.claimRewards()`로 받은 SER9를 reputation 총량 비율로 `nftRewardPerToken`에 가산. `StakingRewardsCollected` emit |
| `claimNFTRewards()` | whenNotPaused, nonReentrant | 호출자의 누적 NFT 보상 출금. NFT 미보유 + 잔여 보상 0이면 `NotNFTHolder`/`NoNFTRewards` |
| `pendingNFTRewards(address)` view | — | 미청구 NFT 보상 미리보기 |
| `pendingStakingRewards()` view | — | staking 컨트랙트 측 `rewards(address(this))` |

### Profile / Avatar

| 함수 | 보호 | 동작 |
|------|------|------|
| `updateProfile(tokenId, name, bio, hue, saturation)` | whenNotPaused, 토큰 소유자 | 32/128 byte 제한, entityType은 변경 불가 |
| `setAvatar(tokenId, AvatarConfig)` | 동일 | 각 슬롯 0~7 검증 후 저장 |
| `setCustomAvatarSeed(tokenId, seed)` | 동일 | **deprecated**, 렌더러 무시 (스토리지 호환성용) |
| `verify(tokenId, bool status)` | onlyOwner | 프로필 `verified` flag 토글 |
| `setReputationScore(tokenId, newScore)` | onlyOwner | 1~`MAX_REPUTATION_SCORE`. 변경 전 owner의 보상 정산(`_accrueNFTReward`) 후 `totalReputationScore` 재계산 |

### Handle

| 함수 | 보호 | 동작 |
|------|------|------|
| `setHandle(tokenId, handle)` | whenNotPaused, 토큰 소유자 | 3~32 byte, `[a-z0-9-]`, 양끝 `-` 금지. 기존 등록되어 있고 활성 reservation 보유자가 다르면 `HandleReserved`. legacy 단계 미완료시 `LegacyHandleReservationsNotFinalized`(단, deadline 지났으면 통과) |
| `seedLegacyHandleReservations(maxTokens)` | whenNotPaused | **누구나 호출 가능**. 1부터 `_nextTokenId`까지 cursor 기반으로 스캔, 각 profile name을 `_legacyHandleSlug`로 변환해 처음 보는 슬러그에 `legacyHandlePriorityDeadline`까지의 reservation 부여. 모두 처리되면 `legacyHandleReservationsFinalized = true` + `LegacyHandleReservationsFinalized` emit |

handle 정규화 규칙(`_legacyHandleSlug`):
- 앞뒤 공백 trim, 대문자 → 소문자, 공백/`_` → `-`
- `[a-z0-9-]`만 허용. 다른 문자 발견 시 빈 문자열 반환 → reservation 스킵
- 길이 / `-` 양끝 검증 통과 시 슬러그 생성

### Payment

#### 즉시 결제

`payToHandle(token, recipientHandle, amount, memo) payable returns (uint256 paymentId)`
- `whenNotPaused, nonReentrant`
- `payerTokenId = ownerTokenId[msg.sender]` 필수 (== identity 보유자만 가능)
- `payerTokenId == payeeTokenId`이면 `SelfPayment`
- `_transferPaymentAsset(token, msg.sender, recipient, amount)`:
  - `token == NATIVE_MON(0)`이면 `msg.value == amount` 검증 후 `recipient.call{value:amount}`
  - ERC20이면 `msg.value == 0` 검증 후 `safeTransferFrom(msg.sender, recipient, amount)` (msg.sender의 사전 approve 필요)
- `IdentityPaymentSent` emit

#### 결제 요청

`createPaymentRequest(payerHandle, token, amount, dueAt, memo) returns (uint256 requestId)`
- 호출자가 payee, 인자 handle 보유자가 payer
- `dueAt == 0`은 무기한, 그 외에는 `dueAt > block.timestamp` 필수
- 요청을 `_paymentRequests`에 `Pending` 상태로 저장, payer/payee의 요청 인덱스에 push

`payPaymentRequest(requestId) payable returns (uint256 paymentId)`
- 호출자가 요청의 payer 본인일 때만 실행. `_effectivePaymentRequestStatus`로 `Pending`인지 확인 (만기는 자동 `Expired` 처리)
- 결제 자산 이동 + 상태를 `Paid`로 변경
- 두 이벤트 발생: `IdentityPaymentSent`, `PaymentRequestPaid`

`payPaymentRequestWithSig(requestId, nonce, deadline, signature) payable returns (uint256 paymentId)`
- **EIP-712 서명 위임 결제**: 서명자는 요청의 payer 본인이어야 하나, 실제 트랜잭션(가스/자금)은 `msg.sender`가 부담
- `nonce == paymentNonces[signer]` 검증 후 nonce 증가
- 동일하게 자산은 `msg.sender`로부터 recipient에게 전달 (ERC20 allowance / `msg.value`도 `msg.sender` 기준)
- 이벤트: `IdentityPaymentSent`, `PaymentRequestPaid`, `PaymentRequestPaidWithSig(signer, relayer, nonce)`

`cancelPaymentRequest(requestId)`
- payer 또는 payee identity 소유자만 호출. 상태 `Pending` → `Cancelled`

#### EIP-712 도메인

- `_EIP712_DOMAIN_TYPEHASH` = `keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)")`
- `_EIP712_NAME_HASH` = `keccak256("Series9Identity")`, `_EIP712_VERSION_HASH` = `keccak256("1")`
- struct: `PayPaymentRequestAuthorization(uint256 requestId,uint256 nonce,uint256 deadline)`
- `paymentDomainSeparator()`, `payPaymentRequestStructHash(...)`, `payPaymentRequestDigest(...)` 공개

### View 함수

| 함수 | 반환 |
|------|------|
| `hasIdentity(address)` | `ownerTokenId != 0` |
| `getEntityType(tokenId)` | `Human` 또는 `AI` (존재 검증) |
| `effectiveReputationScore(tokenId)` | per-token 점수 (없으면 기본값) |
| `reputationScoreOf(address)` | 보유 토큰 점수 (없으면 0) |
| `isAI(address)` / `isHuman(address)` | |
| `isVerified(tokenId)` | |
| `nameOf(address)` | profile name 또는 `""` |
| `handleOf(tokenId)` | 등록된 handle |
| `tokenIdOfHandle(handle)` | 해시 매핑 조회 |
| `ownerOfHandle(handle)` | 현재 owner |
| `legacyHandleReservationOf(handle)` | `(tokenId, expiresAt, active)` |
| `paymentRequest(requestId)` | 전체 필드 (상태는 raw) |
| `effectivePaymentRequestStatus(requestId)` | 만기 적용된 상태 |
| `payerPaymentRequestCount/IdAt(tokenId, index)` | payer 인덱스 |
| `payeePaymentRequestCount/IdAt(tokenId, index)` | payee 인덱스 |
| `tokenURI(tokenId)` | `data:application/json;base64,...` (renderer 호출) |

### 어드민

| 함수 | 동작 |
|------|------|
| `setAIMintFee(uint256)` / `setHumanMintFee(uint256)` | 수수료 변경 |
| `setStakingContract(address)` | staking 컨트랙트 주소 갱신 (코드 존재 검증) |
| `pause()` / `unpause()` | OZ Pausable |

## 내부 동작

### 1 주소 1 NFT 강제 (`_update`)
- 전송/발행 모두 `_update`를 거침.
- `from != 0 && ownerTokenId[from] == tokenId`이면 from의 보상 정산 후 `ownerTokenId[from]` 삭제.
- `to != 0`에 이미 다른 `tokenId`가 매핑되어 있으면 `AlreadyHasIdentity`로 revert (전송 차단).
- `totalReputationScore`가 0이고 발행 이력이 있으면 `_computeTotalReputationScore()`로 재산정 (마이그레이션 안전망).
- 신규 owner의 `nftUserRewardPerTokenPaid`를 현재 인덱스로 동기화하여 과거 인덱스만큼 보상받지 않게 함.

### 보상 누적 (`_accrueNFTReward`)
```
accumulated = nftRewardPerToken - paid
rewards[acc] += accumulated * reputation(token) / PRECISION
paid = nftRewardPerToken
```
- `claimNFTRewards`는 사용자가 호출하는 시점에 자기 인덱스를 동기화.

### Reputation 변경 (`setReputationScore`)
- 변경 전 owner의 보상을 정산 → `reputationScores[tokenId]` 갱신 → `totalReputationScore` 가산/감산
- 결과적으로 사용자는 변경 시점까지의 보상 정산 후 새 비율 적용

## Errors

| Error | 발생 조건 |
|-------|----------|
| `AlreadyHasIdentity(account)` | mint 또는 transfer로 1 주소 1 NFT 위배 |
| `InsufficientMintAllowance()` | (선언만, 미사용 — staking 실패는 `StakingFailed`로 표현) |
| `NameTooLong()` / `BioTooLong()` | 32 / 128 byte 초과 |
| `NotTokenOwner()` | profile/avatar/handle 변경 권한 없음 |
| `InvalidHue()` | (선언만 존재) |
| `ZeroSer9Address()` / `InvalidStakingContract()` | initialize / 어드민 검증 |
| `StakingFailed()` | staking 후에도 SER9 잔액이 증가 (실제로 풀로 들어가지 않음) |
| `NotNFTHolder()` / `NoNFTRewards()` | 보상 청구 자격/잔액 부족 |
| `InvalidReputationScore()` | 0 또는 `MAX_REPUTATION_SCORE` 초과 |
| `NonexistentToken()` | view/admin 호출 시 토큰 미존재 |
| `AvatarSeedTooLong()` / `InvalidAvatarSlot()` | 입력 검증 |
| `PaymentNotInitialized()` | `_nextPaymentId/_nextPaymentRequestId`가 0 (v1 프록시 미마이그레이션) |
| `LegacyHandleReservationsNotFinalized()` | seed가 끝나기 전 + deadline 이전 |
| `InvalidHandle()` / `HandleAlreadyTaken()` / `HandleReserved(...)` / `UnknownHandle()` | handle 규칙/충돌 |
| `InvalidPaymentAmount()` / `PaymentMemoTooLong()` / `SelfPayment()` | 결제 입력 검증 |
| `InvalidNativeValue()` / `NativePaymentFailed()` | MON 결제 시 value 불일치 또는 `.call` 실패 |
| `InvalidPaymentRequest()` / `PaymentRequestNotPending()` / `UnauthorizedPaymentActor()` / `InvalidPaymentDueAt()` | 요청 상태/권한 |
| `PaymentSignatureExpired()` / `InvalidPaymentSignature()` | EIP-712 검증 실패 |

## Events

```
AIMintFeeUpdated, HumanMintFeeUpdated, StakingContractUpdated
ProfileVerified, ProfileUpdated
IdentityStaked, StakingRewardsCollected, NFTRewardClaimed
ReputationScoreUpdated
IdentityHandleUpdated, AvatarUpdated
LegacyHandleReserved, LegacyHandleReservationsFinalized
IdentityPaymentSent
PaymentRequestCreated, PaymentRequestPaid, PaymentRequestPaidWithSig, PaymentRequestCancelled
```

## 구현 상태

| 기능 | 상태 | 비고 |
|------|------|------|
| 1 주소 1 NFT mint (Human/AI 수수료 차등) | 완전 구현 | 전송 시에도 강제됨 |
| 수수료 자동 staking | 완전 구현 | mint 흐름에 통합, 사후 balance 검증 |
| Profile 업데이트 (name/bio/hue/saturation) | 완전 구현 | entityType 불변 |
| Avatar 8슬롯 시스템 | 완전 구현 | 각 슬롯 0~7 |
| `customAvatarSeed` | **deprecated** | 스토리지/setter만 남고 렌더러는 무시 |
| Reputation 가중 보상 분배 | 완전 구현 | totalScore lazy-rebuild로 마이그레이션 안전 |
| `collectStakingRewards` (permissionless) | 완전 구현 | 누구나 보상 풀로 운반 가능 |
| Handle 등록 + 검증 | 완전 구현 | `[a-z0-9-]`, 3~32 byte |
| Legacy handle reservation (30일 우선권) | 완전 구현 | cursor 기반 bounded seeding |
| `payToHandle` (ERC20 / MON) | 완전 구현 | identity 보유자만 |
| 결제 요청 생성/지불/취소 | 완전 구현 | 만기 자동 Expired 처리 |
| EIP-712 서명 위임 결제 | 완전 구현 | nonce 기반 재사용 방지 |
| Owner 어드민 (수수료/staking/verify/reputation/pause) | 완전 구현 | |
| UUPS 업그레이드 | 완전 구현 | `_authorizeUpgrade onlyOwner` |
| `InsufficientMintAllowance` / `InvalidHue` 에러 | **선언만**, 실제 호출 경로 없음 | 향후 사용 가능성 위해 보존 |

## 통합 포인트

- **SER9Token**: mint 수수료 입금 + reward 분배 토큰
- **Series9Staking**:
  - `stake(amount)` — mint 흐름에서 자동 호출
  - `claimRewards()` — `collectStakingRewards`에서 호출
  - `rewards(address(this))` view — `pendingStakingRewards`에서 노출
- **Series9IdentityRenderer**: base contract로 상속, `_renderTokenURI(...)`만 호출

## Storage gap

`uint256[35] private __gap`. 새 상태변수 추가 시 같은 양만큼 감소하여 업그레이드 호환성 유지.

## 운영 노트

1. **결제 흐름은 paused 상태에서 차단됨** — 사용자 자산이 결제 컨트랙트 안에 잠기지 않도록 `whenNotPaused`를 강제. 단 NFT의 ERC721 전송 자체는 OZ 기본 정책을 따름.
2. **수수료 변경 시점**: `setAIMintFee` / `setHumanMintFee`는 이후 mint에만 영향, 과거 mint한 NFT의 보상 비율과는 무관.
3. **Reputation 변경**: 사용자가 보상 청구를 미루더라도 변경 직전까지의 보상이 자동 정산되므로 불공정 분배 없음.
4. **Legacy handle 클레임 기간 (30일)**: 기존 profile name이 정확히 슬러그 규칙에 맞아야 자동 reservation 부여. 다른 사용자는 deadline 이전이라도 `LegacyHandleReservationsNotFinalized`를 만나며, seed 완료 후 reservation 없는 handle은 정상 등록 가능.
