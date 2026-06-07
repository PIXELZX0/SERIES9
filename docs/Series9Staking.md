# Series9Staking

| 항목 | 값 |
|------|----|
| 파일 | [`src/Series9Staking.sol`](../src/Series9Staking.sol) |
| 라인 수 | 1,708 |
| 상속 | `Initializable`, `OwnableUpgradeable`, `PausableUpgradeable`, `ReentrancyGuard`, `UUPSUpgradeable` |
| 업그레이드 | UUPS, `_authorizeUpgrade` = `onlyOwner` |
| 의존 | `SER9Token`, `IPermit2`, `IMonadStaking` (precompile `0x1000`) |

## 개요

Series9Staking은 두 종류의 자산을 동시에 받는 **듀얼 스테이킹 컨트랙트**입니다.

1. **SER9 스테이킹** — 사용자가 SER9 ERC20을 예치하면 블록당 누적 보상으로 SER9를 추가 mint하여 지급.
2. **MON(native) 스테이킹** — 사용자가 MON을 예치하면 컨트랙트가 Monad staking precompile을 호출해
   상위 validator들에게 자동 위임/리밸런싱하고, validator 보상은 프로토콜이 회수하며,
   사용자에게는 별도의 블록당 SER9 보상을 지급.

두 스테이킹은 보상 지표(`rewardPerToken` / `monadRewardPerToken`)와 잔액 매핑이 분리되어 있고
청구는 `claimRewards()`에서 합산 mint로 1회 수령합니다.

업그레이드 권한은 `Series9Staking` owner이며, `SER9` 토큰 자체의 업그레이드도 `upgradeSer9(...)`를 통해
이 컨트랙트가 대신 수행합니다 (SER9의 owner가 이 staking 프록시이기 때문).

## 핵심 상수

| 이름 | 값 | 용도 |
|------|----|------|
| `PRECISION` | `1e18` | rewardPerToken 누적 정밀도 |
| `BPS_DENOMINATOR` | `10_000` | weight 표현 |
| `MONAD_SCORE_PRECISION` | `1e18` | validator 점수 스케일 |
| `MONAD_BLOCKS_PER_YEAR` | `31_536_000` | observed APY 환산 |
| `MONAD_TARGET_COUNT` | `5` | 동시에 위임하는 상위 validator 개수 |
| `MONAD_VALIDATOR_BATCH_LIMIT` | `25` | validator 루프 1회 처리 한도 |
| `MONAD_TICKET_BATCH_LIMIT` | `25` | undelegation ticket 1회 처리 한도 |
| `MONAD_COMPACTION_BATCH_LIMIT` | `50` | 배열 compaction 1회 한도 |
| `UNSTAKE_DELAY_EPOCHS` | `5` | SER9 unstake 청구 가능까지 epoch 수 (MON 기본값도 동일) |
| `MONAD_MAX_UNSTAKE_DELAY_EPOCHS` | `30` | owner가 설정 가능한 MON unstake 지연 상한 |
| `MONAD_PRECOMPILE_ADDRESS` | `0x1000` | Monad staking precompile 주소 |
| `IMPLEMENTATION_SLOT` | EIP-1967 | UUPS implementation 슬롯 검증용 |

## 주요 데이터 구조

```solidity
struct ValidatorSample { uint256 accRewardPerToken; uint256 sampledBlock; uint256 commission; }
struct PendingUndelegateTicket {
    uint64 validatorId; uint8 withdrawId; uint256 amount;
    uint64 claimableEpoch; bool withdrawn;
}
struct MonadUnstakeRequest {
    uint256 amount; uint64 requestEpoch; uint64 minClaimEpoch;
    bool claimed; uint256 uncoveredAmount;
}
struct MonadUnstakeRequestRef { address user; uint256 requestId; }
struct Ser9UnstakeRequest { uint256 amount; uint64 requestEpoch; uint64 minClaimEpoch; bool claimed; }
struct CandidateScore { uint64 validatorId; uint256 score; uint256 commission; }
struct UnstakeCandidate { uint64 validatorId; uint256 score; uint256 commission; bool hasKnownScore; }
```

## 스토리지 레이아웃 (요약)

### 코어 / SER9 트랙
- `SER9Token public ser9` — SER9 프록시 주소
- `IPermit2 public permit2`
- `uint256 public tokenCreationFee` — **사용되지 않음** (관련 deadcode 참조)
- `uint256 public rewardRatePerBlock` — SER9 블록당 보상
- `uint256 public rewardPerTokenStored`, `lastUpdateBlock`, `totalStaked`
- `mapping(address => uint256) public stakedBalance / userRewardPerTokenPaid / rewards`

### MON 트랙
- `uint256 public monadRewardRatePerBlock` (기본값 `rewardRatePerBlock / 8`)
- `uint256 public monadRewardPerTokenStored`, `monadLastUpdateBlock`
- `uint256 public totalMonadStaked / totalDelegatedMonad / totalPendingUndelegateMonad`
- `uint256 public pendingMonadUnstakePrincipal` — 모든 미청구 unstake 요청의 원금 합
- `uint256 public protocolMonadYieldAccrued` — validator 보상으로 회수한 MON (사용자 원금과 분리)
- `mapping(address => uint256) public monadStakedBalance / userMonadRewardPerTokenPaid / monadRewards`
- `mapping(address => bool) public monadRebalanceKeepers` — owner 외에 일부 rebalance 함수를 호출할 수 있는 주소

### Validator 메타
- `uint64[5] public targetValidatorIds`
- `uint16[5] public targetValidatorWeightsBps`
- `uint8 public targetValidatorCount`
- `mapping(uint64 => ValidatorSample) public validatorSamples`
- `mapping(uint64 => uint256) public cachedValidatorScore / hasCachedValidatorScore(bool)`
- `mapping(uint64 => uint256) public validatorDelegatedAmount / validatorPendingUndelegateAmount`
- `mapping(uint64 => uint8) public nextWithdrawIdByValidator`
- `mapping(uint64 => mapping(uint8 => bool)) private _withdrawIdInUse`
- `uint64[] public trackedValidators` + `mapping(uint64 => bool) public isTrackedValidator`

### Undelegation / Coverage queue
- `PendingUndelegateTicket[] public pendingUndelegateTickets`
- 커서 4종 (cursor 기반 bounded batch 처리):
  - `monadHarvestValidatorCursor` — validator 보상 회수
  - `monadUndelegateValidatorCursor` — undelegate 후보 스캔
  - `monadFallbackValidatorCursor` — target 미설정 시 fallback delegate
  - `monadRebalanceValidatorCursor` — rebalance 시 over-delegated validator 스캔
  - `monadPendingUndelegateCursor` — 만기 ticket 처리
  - `monadCoverageRequestCursor` — pending unstake 요청 coverage 할당
- `uint256 public totalPendingMonadUnstakeUncovered`
- `mapping(address => uint256) public monadUnstakeRequestCount`
- `mapping(address => mapping(uint256 => MonadUnstakeRequest)) private _monadUnstakeRequests`
- `MonadUnstakeRequestRef[] private _pendingMonadUnstakeRequests`
- `mapping(address => uint256) public ser9UnstakeRequestCount`
- `mapping(address => mapping(uint256 => Ser9UnstakeRequest)) private _ser9UnstakeRequests`

### Tail storage (업그레이드로 추가됨)
- `uint256 public cachedMonadObservedApy` — 마지막 `_updateMonadTargets` 시 환산 APY
- `uint256 public cachedMonadDelegatedShareBps` — 사용되는 floor 값(`BPS_DENOMINATOR`로 초기화)
- `uint64 public monadUnstakeDelayEpochs` — 0이면 `UNSTAKE_DELAY_EPOCHS` 사용
- `uint256 public accruedCreationFees` — **사용되지 않음** (deadcode)
- `uint256 public monadSlashingDeficit` — withdraw 부족분 누적
- `uint256[10] private _gap`

## Modifier

- `updateReward(account)` — 호출 시 두 트랙의 `rewardPerTokenStored`/`lastUpdateBlock`를 최신화.
  `account != 0`이면 해당 사용자의 `rewards`/`monadRewards`도 정산.
- `onlyMonadRebalanceOperator` — `owner || monadRebalanceKeepers[msg.sender]`.
- `whenInitialized` — `ser9 != 0 && lastUpdateBlock != 0` 강제.

## Initialize 함수

- `initialize(address ser9Token, uint256 rewardPerBlock, address initialOwner, uint256 initialCreationFee)`
  - SER9 트랙 / MON 트랙 보상 비율, owner, pausable 초기화
  - `monadRewardRatePerBlock = rewardPerBlock / 8`
  - `cachedMonadDelegatedShareBps = BPS_DENOMINATOR (10000)`
- `initializeV2() reinitializer(2)` — 기존 deployment에 MON 트랙 필드(`monadLastUpdateBlock`, `monadRewardRatePerBlock`) 백필.
- `initializeV3() reinitializer(3)` — 빈 reinitializer (현재는 슬롯 점유만). 새 storage 백필 필요 시 사용.

## 외부/공개 함수

### 어드민 (onlyOwner)

| 함수 | 동작 |
|------|------|
| `setRewardRatePerBlock(uint256)` | SER9 트랙 블록당 보상 변경 + `updateReward(0)` |
| `setMonadRewardRatePerBlock(uint256)` | MON 트랙 블록당 보상 변경 + `updateReward(0)` |
| `setMonadRebalanceKeeper(address keeper, bool allowed)` | keeper 권한 부여/회수 |
| `forceReleaseUndelegateTicket(uint256 ticketIndex)` | 정상 처리되지 않은 ticket을 강제 회수 처리. 카운터/withdrawId 해제 |
| `setMonadUnstakeDelayEpochs(uint64)` | MON unstake 지연 epoch (1~30) |
| `pause()` / `unpause()` | OZ Pausable |
| `setSer9StakingContract(address)` | SER9 컨트랙트의 `setStakingContract` 위임 호출 (staking 권한 이양) |
| `setTokenCreationFee(uint256)` | **deadcode** — 저장만 됨 |
| `sweepCreationFees(address to, uint256 amount)` | **deadcode** — `accruedCreationFees`가 늘어나는 경로가 없어 항상 0 |
| `setPermit2(address)` | Permit2 주소 갱신 |
| `upgradeSer9(address impl, bytes data)` | SER9 토큰 프록시 업그레이드 (`SER9.owner()`가 이 컨트랙트여야 함) |

### SER9 스테이킹

| 함수 | 보호 modifier | 설명 |
|------|--------------|------|
| `stake(uint256 amount)` | whenInitialized, whenNotPaused, nonReentrant, updateReward | SER9를 `transferFrom`으로 예치 |
| `stakeWithPermit2(amount, permitSingle, signature)` | 동일 | Permit2 서명으로 1-tx 예치. token/spender/amount 검증 후 `permit2.permit` → `permit2.transferFrom` |
| `unstake(uint256 amount)` | 동일 | `stakedBalance`에서 차감 후 epoch 지연 청구 요청 생성 (`Ser9UnstakeRequest`). 토큰 즉시 출금 X |
| `claimUnstaked(uint256 requestId)` | nonReentrant (paused 무관) | `currentEpoch >= minClaimEpoch`이면 원금 출금. **paused 상태에서도 호출 가능** |

### MON 스테이킹

| 함수 | 보호 modifier | 설명 |
|------|--------------|------|
| `stakeMonad() payable` | whenInitialized, whenNotPaused, nonReentrant, updateReward | `msg.value` 만큼 가산 후 `_autoDelegateMonadStake()` 자동 위임 |
| `requestUnstakeMonad(uint256 amount) returns (uint256 requestId)` | whenNotPaused, nonReentrant, updateReward | `monadStakedBalance` 차감, `pendingMonadUnstakePrincipal` 가산, `MonadUnstakeRequest` 생성. 즉시 `_queuePendingMonadUnstakeCoverage`로 backing 시도 |
| `claimUnstakedMonad(uint256 requestId)` | nonReentrant (paused 무관) | `uncoveredAmount == 0 && currentEpoch >= minClaimEpoch`이고 컨트랙트 가용 MON 충분하면 출금 |

### Permissionless 진행 함수 (누구나 호출 가능)

| 함수 | 설명 |
|------|------|
| `processPendingMonadUnstakeCoverage(uint256 maxValidators) returns (uint64 maxClaimEpoch)` | 미커버 unstake 요청에 대해 validator로부터 undelegate 시도 + coverage 할당 |
| `processMaturedMonadUndelegations(uint256 maxTickets) returns (uint256 processed)` | 만기 도달한 `PendingUndelegateTicket`을 `withdraw()`하여 회수 |
| `harvestMonadValidatorRewards()` | **onlyMonadRebalanceOperator** — 모든 tracked validator에 대해 `claimRewards()` 시도, 회수액은 `protocolMonadYieldAccrued`로 누적 |
| `claimMonadValidatorReward(uint64 validatorId)` | **onlyOwner** — 특정 validator만 회수 |
| `delegateUnstakedMonad()` | **onlyOwner** — `_autoDelegateMonadStake()` 수동 호출 (액티브 잔액 재위임) |
| `transferExcessMonadYield(address payable recipient, uint256 amount)` | **onlyOwner** — 프로토콜 yield 일부 인출 |
| `transferAllExcessMonadYield(address payable recipient)` | **onlyOwner** — 프로토콜 yield 전액 인출 |
| `updateMonadTargets()` | **onlyMonadRebalanceOperator** — execution validator set을 스캔해 상위 5명 재선정 + weight 계산 |
| `rebalanceMonadDelegations()` | **onlyMonadRebalanceOperator** — harvest + matured withdraw + coverage + target 재위임을 한 번에. cursor 기반 bounded |

### 보상 / 청구

| 함수 | 설명 |
|------|------|
| `claimRewards()` | SER9 + MON 트랙 누적 보상을 합산해 `SER9.mint(msg.sender, total)`. paused 시 호출 불가 |
| `rewardPerToken()` view | SER9 트랙 누적 인덱스 (현재 블록 기준) |
| `monadRewardPerToken()` view | MON 트랙 누적 인덱스 |
| `earned(address)` view | SER9+MON 합산 미청구 보상 |
| `monadEarned(address)` view | MON 트랙만 미청구 보상 |

### View Helper

| 함수 | 설명 |
|------|------|
| `monadUnstakeRequest(user, requestId)` | (amount, requestEpoch, minClaimEpoch, claimed) |
| `ser9UnstakeRequest(user, requestId)` | 동일 형식 |
| `unlockedStake(user)` | 현재 `stakedBalance` (별도 잠금 없음) |

### Receive

- `receive() external payable {}` — MON 입금 허용 (precompile withdraw 등이 이 경로로 들어옴).

## 내부 동작 흐름

### SER9 보상 누적
- `rewardPerToken = stored + (blockDelta * rewardRatePerBlock * PRECISION / totalStaked)`
- `earned = stakedBalance * (rewardPerToken - paid) / PRECISION + rewards[acc]`

### MON 보상 누적
- 별도 인덱스(`monadRewardPerToken`)로 동일 공식. `totalMonadStaked == 0`이면 정지.

### MON 자동 위임 (`_autoDelegateMonadStake`)
1. `_availableLiquidForActiveDelegation()`로 가용 잔액 산출 (= `balance - pendingMonadUnstakePrincipal - protocolMonadYieldAccrued`).
2. target validator(`targetValidatorIds`)가 있으면 weight 비율로 분배.
3. target 미설정이면 tracked validator 중 잔액 보유 1명에게 fallback delegate.
4. precompile `delegate{value:amount}` 실패는 `MonadDelegateFailed` 이벤트로 기록 후 진행 — revert 하지 않음.

### MON unstake coverage (`_queuePendingMonadUnstakeCoverage`)
1. 현재 가용 MON + 이미 큐된 undelegation으로 cover되지 않는 부족분만큼 validator에서 `undelegate` 시도.
2. 새로 생성된 ticket은 `pendingUndelegateTickets`에 push, `withdrawId`는 `_tryReserveWithdrawId`로 0~255 슬롯 중 미사용 ID 예약.
3. `_allocateMonadRequestCoverage(amount, claimEpoch)`로 FIFO 순서대로 요청의 `uncoveredAmount`를 차감하고 `minClaimEpoch`을 설정.

### Validator 점수 계산 (`_updateMonadTargets`)
- `getExecutionValidatorSet(...)`을 페이지네이션으로 모두 스캔.
- 각 validator의 `accRewardPerToken` 변화량 / 블록 수로 **delta-based score** 계산, commission만큼 차감.
- 상위 5명만 보관, `targetValidatorWeightsBps`를 score 비율로 산정 (모두 0이면 균등).
- 가중 점수로 `cachedMonadObservedApy = portfolioScore * MONAD_BLOCKS_PER_YEAR / SCORE_PRECISION` 계산.

### Matured undelegation 처리 (`_processMaturedUndelegations`)
- 만기 ticket에 대해 `withdraw(validatorId, withdrawId)` 호출.
- 회수액이 ticket.amount 이상이면 surplus는 `protocolMonadYieldAccrued`로 누적.
- **부족분(slashing 등)은 `monadSlashingDeficit`에 누적되며 `MonadWithdrawShortfall` 이벤트 발생** — 보충 메커니즘은 없음.

### 배열 compaction
- `_compactTrackedValidators` — 위임/언위임 잔액이 모두 0인 validator를 배열에서 제거 (커서 안전 재조정 포함).
- `_compactPendingUndelegateTickets` — `withdrawn = true`인 ticket을 swap-pop.

## Errors (요약)

`ZeroAmount`, `InvalidTokenAddress`, `InsufficientStakedBalance`, `NoRewards`,
`InvalidImplementation`, `ImplementationNotUUPSCompatible`, `UnsupportedProxiableUUID`,
`UnauthorizedTokenOwner`, `InvalidPermit2Address`, `Permit2NotConfigured`, `InvalidPermit2Token`,
`InvalidPermit2Spender`, `Permit2AmountTooLow`, `UnauthorizedRebalanceOperator`,
`InsufficientMonadStakedBalance`, `InvalidUnstakeRequest`, `UnstakeRequestAlreadyClaimed`,
`UnstakeRequestNotClaimable`, `InsufficientLiquidMonad`, `MonadPayoutFailed`, `NotInitialized`,
`MonadEpochReadFailed` (precompile epoch 읽기 실패 시 즉시 revert — fail-open 금지),
`InvalidUnstakeDelayEpochs`, `InvalidSweepRecipient`, `InvalidUndelegateTicket`,
`InsufficientCreationFees`.

## Events (요약)

운영/관측용:
`Staked`, `Unstaked`, `RewardClaimed`, `RewardRateUpdated`, `Ser9Upgraded`,
`TokenCreationFeeUpdated`, `Permit2Updated`,
`MonadRewardRateUpdated`, `MonadRebalanceKeeperUpdated`, `MonadUnstakeDelayEpochsUpdated`,
`MonadStaked`,
`Ser9UnstakeRequested`, `Ser9UnstakeClaimed`,
`MonadUnstakeRequested`, `MonadUnstakeClaimed`,
`MonadUndelegateQueued`, `MonadWithdrawProcessed`,
`MonadYieldAccrued`, `MonadYieldTransferred`,
`MonadTargetsUpdated`, `MonadRebalanced`,
`MonadDelegateFailed`, `MonadClaimRewardsFailed`,
`CreationFeesSwept`, `MonadUndelegateTicketForceReleased`, `MonadWithdrawShortfall`.

## 구현 상태

| 기능 | 상태 | 비고 |
|------|------|------|
| SER9 stake / unstake (epoch 지연) | 완전 구현 | `claimUnstaked`는 paused 무관하게 호출 가능 |
| SER9 Permit2 stake | 완전 구현 | `setPermit2`로 주소 설정 필요 |
| SER9 블록당 보상 + mint 청구 | 완전 구현 | `claimRewards`에서 `SER9.mint` |
| MON stake (자동 위임) | 완전 구현 | target 미설정 시 fallback 1명 |
| MON unstake 요청 + coverage 큐 | 완전 구현 | permissionless `processPendingMonadUnstakeCoverage` |
| MON matured undelegation 회수 | 완전 구현 | permissionless `processMaturedMonadUndelegations` |
| Validator 점수 계산 + 상위 5 선정 | 완전 구현 | `updateMonadTargets`로 명시 호출 (rebalance와 분리됨) |
| Cursor 기반 bounded batch | 완전 구현 | harvest/undelegate/fallback/rebalance/coverage/tickets |
| Withdraw shortfall 추적 | 부분 구현 | `monadSlashingDeficit`만 누적, 보충/분배 로직 없음 |
| SER9 토큰 업그레이드 위임 (`upgradeSer9`) | 완전 구현 | SER9 owner == staking 전제 검증 |
| `tokenCreationFee` / `accruedCreationFees` / `sweepCreationFees` | **dead code** | `managedToken` 제거 후 잔재. 수수료 누적 경로 없음 — sweep 호출 시 `InsufficientCreationFees` revert |
| Reentrancy 보호 | 완전 구현 | `nonReentrant`로 모든 상태 변경 함수 보호 |
| Pause 회피 경로 | 의도적 | `claimUnstaked`, `claimUnstakedMonad`, permissionless processor는 paused에서도 동작 |

## 보안/운영 노트

1. **Monad epoch 실패는 fail-open 금지**: `_getEpoch()`는 `MonadEpochReadFailed`로 revert.
2. **Precompile yield 누적**: 모든 delegate/undelegate/withdraw 전후 `balance` 차이를 측정해 예상치를 초과하는 잔액은 `protocolMonadYieldAccrued`로 누적 (사용자 원금 격리).
3. **WithdrawId 충돌 방지**: validator당 0~255 슬롯을 비트맵으로 추적 (`_withdrawIdInUse`). 256개 모두 점유 시 `_tryReserveWithdrawId`가 `false` 반환 → 해당 라운드 skip.
4. **Cursor 기반 처리**: validator/ticket이 많아도 한 트랜잭션 가스 한도 안에서 점진적으로 진행. 외부에서 여러 번 호출 가능.
5. **Storage gap**: `uint256[10] private _gap`. 새 상태변수 추가 시 같은 양만큼 감소.
6. **Force release**: validator 슬래시/오작동으로 ticket이 영원히 처리 안 될 때 owner가 `forceReleaseUndelegateTicket`으로 상태 복구 가능 (자금 회수는 별도 처리 필요).
