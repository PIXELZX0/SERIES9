# SER9 개발자 가이드 (SERIES9 / Staking / Identity / Wallet)

이 문서는 SER9 생태계 4개 핵심 컨트랙트를 **처음 통합하는 개발자** 대상 실전 가이드입니다.
구현 상태/설계 디테일은 [`docs/README.md`](./README.md) 및 개별 문서(`Series9Staking.md`, `Series9Identity.md`, `Series9IdentityWallet.md`)를 참고하세요. 여기서는 "어떻게 호출하나"에 집중합니다.

전부 **UUPS + ERC1967Proxy** 업그레이드 패턴. ABI는 `abi/*.json`, 프론트엔드용 TS ABI는 `web/src/contracts/abi/*.ts`.

## 0. 네트워크 / 배포 주소

Monad L1 (chainId `143`), RPC `https://rpc.monad.xyz` (`web/src/config` 참고).

| 컨트랙트 | Proxy 주소 |
|---|---|
| SER9 (ERC20) | `0x461b9beFb3c81c988501C89F5caaBa03b02565d0` |
| Series9Staking | `0xFa76a92716D9fE7DF902266651Ca64014c4dC35A` |
| Series9Identity | `0xEBa0Fd485ADe50AE5182EbB4ff98fCC5613572e9` |
| Permit2 | `0x000000000022D473030F116dDEE9F6B43aC78BA3` |

호출은 항상 **proxy 주소**로. `web/src/config`에 `VITE_*` 환경변수로 override 가능(테스트넷/포크용).

---

## 1. SER9 (Token) — `src/SER9Token.sol`

표준 ERC20 + mint 게이트만 추가된 얇은 토큰.

- `mint(address to, uint256 amount)` — **staking 컨트랙트만 호출 가능**. 직접 mint 불가 (owner 포함).
- `setStakingContract(address)` — `onlyOwner`, 최초 배포 스크립트가 1회 설정 후 소유권을 staking으로 이관.
- 나머지는 표준 ERC20 (`transfer`, `approve`, `balanceOf` ...).

개발자 입장에서 SER9은 "일반 ERC20"으로 다루면 됨 — `stake`/`unstake`는 Staking 컨트랙트가 담당.

```bash
cast call $SER9 "balanceOf(address)(uint256)" $USER --rpc-url $RPC
cast send $SER9 "approve(address,uint256)" $STAKING $AMOUNT --private-key $PK --rpc-url $RPC
```

---

## 2. Series9Staking — `src/Series9Staking.sol`

SER9 스테이킹 + MON(Monad native) 듀얼 스테이킹. 보상은 **초 단위가 아니라 블록 단위** 누적.

### 사용자 플로우 (SER9)

```bash
# 1. approve
cast send $SER9 "approve(address,uint256)" $STAKING $AMOUNT --private-key $PK --rpc-url $RPC
# 2. stake
cast send $STAKING "stake(uint256)" $AMOUNT --private-key $PK --rpc-url $RPC
# 3. 언제든 보상 청구
cast send $STAKING "claimRewards()" --private-key $PK --rpc-url $RPC
# 4. unstake (epoch 지연 후 청구 가능한 요청 생성)
cast send $STAKING "unstake(uint256)" $AMOUNT --private-key $PK --rpc-url $RPC
# 5. 지연 경과 후 원금 청구
cast send $STAKING "claimUnstaked(uint256)" $REQUEST_ID --private-key $PK --rpc-url $RPC
```

Permit2 서명으로 approve 없이 stake하려면 `stakeWithPermit2(...)` 사용 (`src/interfaces/IPermit2.sol` 참고).

### MON(네이티브) 스테이킹 — Monad validator 위임

```bash
cast send $STAKING "stakeMonad()" --value $AMOUNT --private-key $PK --rpc-url $RPC
cast send $STAKING "requestUnstakeMonad(uint256)" $AMOUNT --private-key $PK --rpc-url $RPC
cast send $STAKING "claimUnstakedMonad(uint256)" $REQUEST_ID --private-key $PK --rpc-url $RPC
```

MON 언스테이킹은 백엔드에서 Monad validator unstake/undelegate가 실제 처리돼야 청구 가능합니다. 이건 **permissionless**하게 아무나 진행시킬 수 있음 (봇/키퍼가 주기적으로 호출):

```bash
cast send $STAKING "processPendingMonadUnstakeCoverage(uint256)" $MAX_VALIDATORS --rpc-url $RPC --private-key $PK
cast send $STAKING "processMaturedMonadUndelegations(uint256)" $MAX_TICKETS --rpc-url $RPC --private-key $PK
```

`Monad epoch` 조회 실패 시 fail-open 하지 않고 즉시 `MonadEpochReadFailed`로 revert함 — 재시도 로직 필요.

### 조회 (view)

| 함수 | 용도 |
|---|---|
| `earned(address)` | SER9 청구 가능 보상 |
| `monadEarned(address)` | MON 청구 가능 보상 |
| `unlockedStake(address)` | 락업 해제된 스테이크 잔액 |
| `rewardPerToken()` / `monadRewardPerToken()` | 누적 보상 지수 |

### Owner 전용 (운영)

`setRewardRatePerBlock`, `setMonadRewardRatePerBlock`, `setMonadRebalanceKeeper`, `pause`/`unpause`, `upgradeSer9(...)`. 자세한 파라미터는 `docs/Series9Staking.md` 참고.

<remember priority>Series9Staking 밸리데이터 전체 스캔(rebalance 등)은 의도된 설계 — 페이지네이션으로 바꾸지 말 것.</remember>

---

## 3. Series9Identity — `src/Series9Identity.sol`

주소당 1개 identity NFT + handle 결제 + 지갑 팩토리 + 에스크로 전송.

### 3.1 Mint

```bash
# entityType: 0=Human, 1=AI (EntityType enum 확인 필요)
cast send $IDENTITY "mintIdentity(string,string,uint8,uint8,uint8)" \
  "Alice" "bio here" 0 200 80 --private-key $PK --rpc-url $RPC

# handle까지 한번에 등록
cast send $IDENTITY "mintIdentityWithHandle(string,string,uint8,uint8,uint8,string)" \
  "Alice" "bio" 0 200 80 "alice" --private-key $PK --rpc-url $RPC
```

Mint fee(SER9)는 자동으로 staking에 위임됨(reputation 가중 분배, 기본 Human:AI = 9:1).

### 3.2 Handle 기반 결제

```bash
# 다른 handle로 직접 송금 (ERC20 또는 MON, token=address(0)이면 MON)
cast send $IDENTITY "payToHandle(address,string,uint256,string)" \
  $TOKEN "bob" $AMOUNT "invoice #1" --private-key $PK --rpc-url $RPC

# 결제 요청 생성 → 상대가 승인해야 이체
cast send $IDENTITY "createPaymentRequest(...)" ... --private-key $PK --rpc-url $RPC
cast send $IDENTITY "payPaymentRequest(uint256)" $REQUEST_ID --private-key $PK --rpc-url $RPC
```

EIP-712 서명 위임 결제는 `payPaymentRequestWithSig(requestId, nonce, deadline, signature)` — 릴레이어가 가스 대납 가능. 도메인 해시는 `paymentDomainSeparator()`.

**중요:** 결제는 항상 identity의 **현재 소유자 본인**만 실행 가능(승인된 ERC20 또는 본인이 보낸 MON만 이동).

### 3.3 조회

| 함수 | 용도 |
|---|---|
| `hasIdentity(address)` | identity 보유 여부 |
| `handleOf(tokenId)` / `tokenIdOfHandle(handle)` / `ownerOfHandle(handle)` | handle ↔ tokenId ↔ owner 매핑 |
| `reputationScoreOf(address)` | 보상 가중치 |
| `isAI` / `isHuman` / `isVerified` | entity 상태 |

### 3.4 지갑 팩토리 (→ 4번 섹션과 연결)

```bash
cast send $IDENTITY "createWallet(uint256)" $TOKEN_ID --private-key $PK --rpc-url $RPC
cast call $IDENTITY "predictWalletAddress(uint256)(address)" $TOKEN_ID --rpc-url $RPC
```

`createWallet`은 CREATE2(salt=tokenId) — 배포 전에도 `predictWalletAddress`로 주소 계산 가능(counterfactual 입금 가능).

### 3.5 에스크로 전송 (identity 소유권 이전)

```bash
cast send $IDENTITY "initiateIdentityTransfer(address)" $NEW_OWNER --private-key $PK_OLD --rpc-url $RPC
cast send $IDENTITY "acceptIdentityTransfer(uint256)" $TOKEN_ID --private-key $PK_NEW --rpc-url $RPC
# 6시간 지연 후
cast send $IDENTITY "finalizeIdentityTransfer(uint256)" $TOKEN_ID --rpc-url $RPC --private-key $PK
```

양측 모두 `cancelIdentityTransfer`로 취소 가능. **전송 진행 중엔 지갑이 동결**되어 `execute`/`upgrade` 불가.

주의: `approve`/`setApprovalForAll`은 항상 revert (identity NFT는 일반 마켓플레이스로 거래 불가 — 에스크로 전송만 유효 경로).

---

## 4. Series9IdentityWallet — `src/Series9IdentityWallet.sol`

identity별 스마트 어카운트. 소유자는 이 지갑을 위해 별도 EOA 키를 갖지 않음 — **권한은 전부 identity NFT 소유자에게 위임**됨 (Series9Identity가 매 호출마다 `authorizeWalletCall`로 검증).

```bash
# 임의 호출 실행 (지갑 주소에서 to로 call)
cast send $WALLET "execute(address,uint256,bytes)" $TO $VALUE $CALLDATA --private-key $PK --rpc-url $RPC

# 배치 실행
cast send $WALLET "executeBatch(address[],uint256[],bytes[])" "[$TO1,$TO2]" "[0,0]" "[$DATA1,$DATA2]" --private-key $PK --rpc-url $RPC

# 컨트랙트 배포 (CREATE / CREATE2)
cast send $WALLET "deployContract(uint256,bytes)" 0 $BYTECODE --private-key $PK --rpc-url $RPC
cast send $WALLET "deployContract2(bytes32,uint256,bytes)" $SALT 0 $BYTECODE --private-key $PK --rpc-url $RPC
```

- `PK`는 **현재 identity NFT를 보유한 주소의 키**여야 함 — identity가 이전되면 지갑 권한도 즉시 새 소유자에게 넘어감(구 소유자 키는 즉시 무력화).
- ERC721/ERC1155 수신 hook 내장 — NFT 보관 가능.
- MON은 plain `.transfer()`/`.send()` (2300 gas)로도 입금 가능 (`receive()`가 SSTORE/LOG 없음).
- 업그레이드: 현재 NFT 보유자만, `Series9Identity.setWalletImplApproved`로 허용목록에 등록된 **더 높은 버전**으로만 가능(다운그레이드 금지). `Series9Identity.initializeWalletFactory` / `setWalletImplApproved`는 owner 전용.

### viem/wagmi 예시 (프론트엔드)

```ts
import { walletAbi } from './contracts/abi/wallet';
import { writeContract } from 'wagmi/actions';

await writeContract(config, {
  address: walletAddress,
  abi: walletAbi,
  functionName: 'execute',
  args: [toAddress, value, calldata],
});
```

실제 프론트엔드 통합 참고 코드는 `web/src/contracts/abi/{wallet,identity,staking}.ts` + `web/src/hooks`, `web/src/components`.

---

## 5. 컨트랙트 간 관계 요약

```
사용자 EOA
  └─ mintIdentity() ──────────────► Series9Identity NFT (1개)
         │                                │
         │                                ├─ createWallet() ─► Series9IdentityWallet (CREATE2, tokenId salt)
         │                                │       └─ execute/deployContract: NFT 소유자만 (authorizeWalletCall 경유)
         │                                │
         │                                └─ payToHandle / paymentRequest: handle 기반 P2P 결제
         │
         └─ stake() / stakeMonad() ──────► Series9Staking
                  └─ mint 권한 보유 ──────► SER9Token (staking만 mint 가능)
```

Identity mint fee, staking reward 모두 SER9 단일 토큰 경유. Wallet은 별도 자산을 갖지 않고 NFT 소유권만 신뢰 루트로 사용.

## 6. 로컬 개발 / 테스트

```bash
forge build
forge test -vv
# 특정 컨트랙트만
forge test --match-path test/Series9Staking.t.sol -vvv
forge test --match-path test/Series9Identity.t.sol -vvv
forge test --match-path test/Series9IdentityWallet.t.sol -vvv
```

배포 스크립트: `script/DeploySeries9.s.sol`(SER9+Staking), `script/DeployIdentity.s.sol`(Identity). Safe 멀티시그 업그레이드 트랜잭션 예시는 `safe/*.json` 참고.
