# Series9IdentityWallet

| 항목 | 값 |
|------|----|
| 파일 | [`src/Series9IdentityWallet.sol`](../src/Series9IdentityWallet.sol) |
| 라인 수 | 153 |
| 상속 | `Initializable`, `UUPSUpgradeable`, `ReentrancyGuard` |
| 업그레이드 | per-wallet UUPS, `_authorizeUpgrade` = identity NFT 보유자 + 허용목록(아래) |
| 배포 | [`Series9Identity`](./Series9Identity.md)가 ERC1967 프록시 + CREATE2(salt=tokenId)로 팩토리 배포 |

## 개요

각 [`Series9Identity`](./Series9Identity.md) NFT는 **정확히 하나**의 `Series9IdentityWallet`을 소유합니다. 실제 EVM 어카운트처럼 동작:

- 자체 주소로 **native MON·ERC20·NFT** 보유 (`receive()` + 토큰 receiver 훅)
- 임의 호출 **`execute` / `executeBatch`** (value 포함)
- 컨트랙트 **배포 `deployContract`(CREATE) / `deployContract2`(CREATE2)**

**모든 권한은 EOA가 아니라 identity NFT에 귀속**됩니다. 지갑은 소유자 주소를 저장하지 않고, 매 호출마다 identity 컨트랙트의 `ownerOf(tokenId)`로 권한을 확인합니다. 따라서 NFT가 이전되면 새 보유자가 지갑(잔액·배포한 컨트랙트 포함)을 자동 승계하고, 구 보유자는 즉시 권한을 잃습니다. 마이그레이션 없음, 주소 고정.

## 스토리지

```solidity
address public identity;   // Series9Identity 프록시
uint256 public tokenId;    // 이 지갑을 통제하는 identity NFT id
```
- clone/proxy로 배포되며 `initialize(identity, tokenId)`로 1회 설정. impl 자체는 생성자에서 `_disableInitializers()`.
- 권한·freeze·업그레이드 허용목록은 **모두 identity 컨트랙트에 위임**되어 지갑은 상태를 최소로 유지.

## 함수

| 함수 | 보호 | 동작 |
|------|------|------|
| `initialize(identity_, tokenId_)` | initializer | 프록시 생성 시 1회. identity/tokenId 바인딩 |
| `receive() payable` | — | MON 입금 수령. `Received` emit |
| `execute(to, value, data)` | onlyOperator, nonReentrant | 임의 호출. 실패 시 `CallFailed(returnData)` |
| `executeBatch(tos, values, datas)` | onlyOperator, nonReentrant | 배치 호출. 길이 불일치 시 `LengthMismatch` |
| `deployContract(value, bytecode)` | onlyOperator, nonReentrant | CREATE 배포. 0 주소면 `DeployFailed` |
| `deployContract2(salt, value, bytecode)` | onlyOperator, nonReentrant | CREATE2 배포 |
| `onERC721Received` / `onERC1155Received` / `onERC1155BatchReceived` | pure | NFT 보유용 selector 반환 |
| `_authorizeUpgrade(newImpl)` | internal view override | identity의 `authorizeWalletUpgrade`에 위임 |

### `onlyOperator` 게이트

```solidity
ISeries9IdentityForWallet(identity).authorizeWalletCall(tokenId, msg.sender);
```
identity 컨트랙트가 다음을 강제:
- `ownerOf(tokenId) == msg.sender` 아니면 `NotTokenOwner`
- 전송 freeze(Pending/Accepted) 중이면 `WalletFrozenDuringTransfer`

→ 진행 중인 정체성 전송(6시간 에스크로) 동안 지갑의 **모든 출금/배포/업그레이드가 동결**되어 수신자가 본 잔액 그대로 수령. 입금(`receive`/토큰 전송)은 영향 없음.

## 업그레이드 모델 (소유자 주도 + 허용목록 + 다운그레이드 금지)

per-wallet UUPS. `_authorizeUpgrade` → `Series9Identity.authorizeWalletUpgrade(tokenId, msg.sender, ERC1967Utils.getImplementation(), newImpl)`가 강제:

1. `msg.sender`가 현재 NFT 보유자 (`NotTokenOwner`) — **업그레이드 권한도 NFT에 귀속**, 플랫폼이 강제 불가
2. `newImpl`이 허용목록에 있음 — `walletImplVersion[newImpl] > 0` (`WalletImplNotApproved`)
3. **다운그레이드 금지** — `walletImplVersion[newImpl] > walletImplVersion[currentImpl]` (`WalletDowngradeNotAllowed`)
4. 전송 freeze 중 아님 (`WalletFrozenDuringTransfer`)

허용목록은 `Series9Identity` owner(Safe multisig)가 `setWalletImplApproved(impl, version)`로 큐레이션 — 이는 **글로벌 안전장치**일 뿐 개별 지갑을 조작/탈취할 수 없음. bootstrap impl은 `initializeWalletFactory`에서 version 1로 등록.

## 결정론적 주소

지갑 프록시 init-code = `ERC1967Proxy` creationCode + `(walletImplementation, initialize(identity, tokenId) calldata)`. `walletImplementation`(bootstrap)은 고정이고 salt=tokenId이므로 주소는 **tokenId만으로 결정**되며 `predictWalletAddress(tokenId)`로 사전 예측 가능. UUPS 업그레이드는 birth 이후 일어나 주소를 바꾸지 않음.

## Errors

| Error | 발생 조건 |
|-------|----------|
| `CallFailed(returnData)` | `execute`/`executeBatch` 하위 호출 revert |
| `DeployFailed()` | CREATE/CREATE2가 0 주소 반환 |
| `LengthMismatch()` | `executeBatch` 배열 길이 불일치 |

> 권한/freeze/업그레이드 관련 revert(`NotTokenOwner`, `WalletFrozenDuringTransfer`, `WalletImplNotApproved`, `WalletDowngradeNotAllowed`)는 [`Series9Identity`](./Series9Identity.md)에서 발생해 전파됨.

## Events

`Executed(to, value, data, result)`, `ContractDeployed(deployed, value)`, `Received(from, amount)`

## 보안 노트

- 임의 `execute` + 컨트랙트 배포가 가능한 고권한 어카운트. 오직 **현 NFT 보유자**만 조작 (매 호출 `ownerOf` 재확인).
- 전송 시 새 보유자가 지갑·잔액·배포 컨트랙트를 전부 승계 — UX에서 명확히 안내 필요. 송신자가 자산을 유지하려면 `initiate` **이전에** 옮겨야 함(이후 freeze).
- 업그레이드는 소유자 주도 + 허용목록 + 전진 버전만 — 피싱당한 소유자도 임의 drainer impl 설치 불가, 취약 버전으로 롤백 불가.
- 불변 bootstrap 주소 → CREATE2 지갑 주소 영구 고정·예측 가능.

## ERC-1271 서명 (지갑 로직 v2, `Series9IdentityWalletV2`)

v2부터 지갑이 **서명자**가 된다. `isValidSignature(bytes32 hash, bytes signature) → bytes4`:

```
holder = ownerOf(tokenId)                       // 실패(소각 등) → 0xffffffff
authorizeWalletCall(tokenId, holder)            // revert(freeze 등) → 0xffffffff
SignatureChecker.isValidSignatureNow(holder, hash, signature)
    ? 0x1626ba7e : 0xffffffff
```

- **서명 권한도 NFT에 귀속** — `execute`와 동일하게 매 호출 현재 `ownerOf(tokenId)`를 재확인. 정체성이 이전되면 이전 보유자의 서명은 즉시 무효, 새 보유자의 서명이 유효해짐.
- **freeze 중 서명 무효** — 전송(Pending/Accepted) 중에는 `authorizeWalletCall`이 revert하므로 `0xffffffff` 반환. 출금 동결과 동일한 규칙을 재사용(권한 로직 사본 없음).
- **절대 revert하지 않음** — 모든 실패 경로는 `0xffffffff` 반환.
- **컨트랙트 보유자 지원** — `SignatureChecker`가 EOA(ECDSA) / 컨트랙트(중첩 ERC-1271) 양쪽을 처리. 다른 스마트 어카운트가 정체성을 보유해도 서명 가능.
- **raw hash 방식** — dapp이 넘긴 `hash`를 그대로 검증(도메인 래핑 없음). Permit2·마켓플레이스 리스팅·SIWE 등 표준 서명 플로우와 그대로 호환.
  - ⚠️ 트레이드오프: 한 보유자가 여러 정체성 지갑을 가질 경우, **같은 hash에 대한 서명은 그 보유자의 모든 지갑에서 유효**하다(지갑별 도메인 바인딩 없음). 지갑별 분리가 필요한 프로토콜은 자기 도메인에 `verifyingContract`로 지갑 주소를 넣어 hash 자체를 분리할 것.
- v2는 **스토리지를 추가하지 않음** → 보유자가 `upgradeToAndCall(walletV2, "")`로 직접 업그레이드(init data 불필요). 배포·허용목록은 `script/UpgradeIdentityWalletV2.s.sol`이 Safe TX JSON으로 생성.

## 통합 포인트

- **Series9Identity**: 팩토리(`createWallet`/`predictWalletAddress`) + 권한 훅(`authorizeWalletCall`/`authorizeWalletUpgrade`) + 허용목록(`setWalletImplApproved`).
