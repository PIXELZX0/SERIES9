# SER9 개발자 가이드 (SER9 Token / Staking)

이 문서는 SER9 토큰과 스테이킹 컨트랙트를 **처음 통합하는 개발자** 대상 실전 가이드입니다.
구현 상태/설계 디테일은 [`docs/README.md`](./README.md) 및 개별 문서(`SER9Token.md`, `Series9Staking.md`)를 참고하세요. 여기서는 "어떻게 호출하나"에 집중합니다.
Identity/Wallet 가이드는 [SERIES9Identity](https://github.com/PIXELZX0/SERIES9Identity) 레포에 있습니다.

전부 **UUPS + ERC1967Proxy** 업그레이드 패턴. ABI는 `abi/*.json`, 프론트엔드용 TS ABI는 [SERIES9_Front](https://github.com/PIXELZX0/SERIES9_Front)의 `src/contracts/abi/*.ts`.

## 0. 네트워크 / 배포 주소

Monad L1 (chainId `143`), RPC `https://rpc.monad.xyz` ([SERIES9_Front](https://github.com/PIXELZX0/SERIES9_Front)의 `src/config` 참고).

| 컨트랙트 | Proxy 주소 |
|---|---|
| SER9 (ERC20) | `0x461b9beFb3c81c988501C89F5caaBa03b02565d0` |
| Series9Staking | `0xFa76a92716D9fE7DF902266651Ca64014c4dC35A` |
| Series9Identity | `0xEBa0Fd485ADe50AE5182EbB4ff98fCC5613572e9` |
| Permit2 | `0x000000000022D473030F116dDEE9F6B43aC78BA3` |

호출은 항상 **proxy 주소**로. [SERIES9_Front](https://github.com/PIXELZX0/SERIES9_Front)의 `src/config`에서 `VITE_*` 환경변수로 override 가능(테스트넷/포크용).

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


## 3. 컨트랙트 간 관계 요약

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

## 4. 로컬 개발 / 테스트

```bash
forge build
forge test -vv
# 특정 컨트랙트만
forge test --match-path test/Series9Staking.t.sol -vvv
forge test --match-path test/SER9Token.t.sol -vvv
```

배포 스크립트: `script/DeploySeries9.s.sol`(SER9+Staking). Safe 멀티시그 업그레이드 트랜잭션 예시는 `safe/*.json` 참고.
Identity 배포는 [SERIES9Identity](https://github.com/PIXELZX0/SERIES9Identity) 레포의 `script/DeployIdentity.s.sol` 참고.
