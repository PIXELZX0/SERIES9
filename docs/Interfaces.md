# Interfaces

`src/interfaces/` 디렉터리의 외부 인터페이스 정의입니다.
구현체는 본 리포에 없으며, 각각 **Monad chain precompile** 또는 **Uniswap Permit2** 외부 컨트랙트를 참조합니다.

---

## IMonadStaking

| 항목 | 값 |
|------|----|
| 파일 | [`src/interfaces/IMonadStaking.sol`](../src/interfaces/IMonadStaking.sol) |
| 라인 수 | 47 |
| 구현체 | Monad chain 내장 staking **precompile** (`Series9Staking`에서 `0x1000` 주소로 호출) |
| 사용처 | `Series9Staking._monadStaking()` |

### 함수

| 함수 | 종류 | 설명 |
|------|------|------|
| `delegate(uint64 validatorId) payable returns (bool success)` | mutating | `msg.value` MON을 validator에게 위임 |
| `undelegate(uint64 validatorId, uint256 amount, uint8 withdrawId) returns (bool success)` | mutating | 위임 해제 요청. `withdrawId`는 validator당 0~255 슬롯에서 컨트랙트가 예약 |
| `withdraw(uint64 validatorId, uint8 withdrawId) returns (bool success)` | mutating | 만기 도달한 undelegation 회수 (MON 반환은 `address(this).balance` 증가로 측정) |
| `claimRewards(uint64 validatorId) returns (bool success)` | mutating | validator 보상을 컨트랙트로 회수 |
| `getExecutionValidatorSet(uint32 startIndex) returns (bool isDone, uint32 nextIndex, uint64[] valIds)` | view-like (mutating signature) | 페이지네이션으로 execution validator id 목록 조회. `updateMonadTargets` 스캔용 |
| `getValidator(uint64 validatorId) returns (...)` | view-like | validator 메타 (`accRewardPerToken`, `commission`, stake, BLS/secp pubkey 등 12개 필드) |
| `getDelegator(uint64 validatorId, address delegator) returns (...)` | view-like | 위임자 잔액/누적 보상/대기중 변경분 |
| `getEpoch() returns (uint64 epoch, bool inEpochDelayPeriod)` | view-like | 현재 epoch와 epoch 전환 대기 구간 여부 |

> 모든 getter도 `external` (view/pure 아님) — precompile 특성상 mutating 시그니처. 호출 실패는 try/catch로 잡으며 `Series9Staking`은 `getEpoch` 실패 시 **fail-open 금지**(`MonadEpochReadFailed` revert), 그 외 함수는 실패해도 진행하고 이벤트로 기록.

### `Series9Staking`에서의 사용 패턴

```solidity
function _monadStaking() internal pure returns (IMonadStaking) {
    return IMonadStaking(address(uint160(MONAD_PRECOMPILE_ADDRESS))); // 0x1000
}
```

| 호출 | 위치 | 실패 처리 |
|------|------|----------|
| `delegate{value:amount}` | `_delegateMonadAmountToValidator` | `MonadDelegateFailed` 이벤트, false 반환 |
| `undelegate` | `_undelegateFromValidator` | withdrawId 해제 후 0 반환 (해당 라운드 skip) |
| `withdraw` | `_processMaturedUndelegations` | scanned++ 후 다음 ticket로 |
| `claimRewards` | `harvestMonadValidatorRewards`, `claimMonadValidatorReward` | `MonadClaimRewardsFailed` 이벤트 |
| `getEpoch` | `_getEpoch` | `MonadEpochReadFailed` revert (fail-open 금지) |
| `getValidator` | `_updateMonadTargets` | continue (해당 validator skip) |
| `getDelegator` | `_undelegateFromValidator` | 캐치만 하고 기본값 사용 |
| `getExecutionValidatorSet` | `_updateMonadTargets` | catch 없음 — 실패 시 전체 함수 revert |

---

## IPermit2

| 항목 | 값 |
|------|----|
| 파일 | [`src/interfaces/IPermit2.sol`](../src/interfaces/IPermit2.sol) |
| 라인 수 | 21 |
| 구현체 | Uniswap [Permit2](https://github.com/Uniswap/permit2) (체인별로 동일 주소 배포) |
| 사용처 | `Series9Staking.stakeWithPermit2(...)` 및 내부 `_transferFromWithPermit2` |

### 구조체

```solidity
struct PermitDetails {
    address token;
    uint160 amount;
    uint48 expiration;
    uint48 nonce;
}

struct PermitSingle {
    PermitDetails details;
    address spender;
    uint256 sigDeadline;
}
```

### 함수

| 함수 | 설명 |
|------|------|
| `permit(address owner, PermitSingle permitSingle, bytes signature) external` | EIP-712 서명을 기반으로 `owner`가 `spender`에게 `details.token`을 `details.amount`만큼 위임 |
| `transferFrom(address from, address to, uint160 amount, address token) external` | `permit`으로 설정된 권한을 사용해 토큰 이동 (Permit2가 별도로 추적하는 allowance) |

### `Series9Staking`에서의 검증 로직

`_transferFromWithPermit2(token, amount, permitSingle, signature)`:

1. `permit2` 주소 미설정 → `Permit2NotConfigured`
2. `permitSingle.details.token != token` → `InvalidPermit2Token`
3. `permitSingle.spender != address(this)` → `InvalidPermit2Spender`
4. `uint256(permitSingle.details.amount) < amount` → `Permit2AmountTooLow`
5. `permit2.permit(msg.sender, permitSingle, signature)` 호출
6. `permit2.transferFrom(msg.sender, address(this), SafeCast.toUint160(amount), token)` 실행

→ 단일 트랜잭션으로 사용자 서명 검증 + 토큰 이동 + 스테이킹 완료.

### 운영 노트

- Permit2 주소는 `setPermit2(address)` (onlyOwner)로 배포 후 설정해야 `stakeWithPermit2` 사용 가능.
- Permit2는 `expiration`까지 유효한 별도 allowance를 보관하므로, 처음 1회 영구 ERC20 approve(Permit2에 대해)를 한 후
  매번 다른 EIP-712 서명만으로 결제 가능 (UX 개선).
- `SafeCast.toUint160(amount)`로 `amount`가 `uint160`을 초과하면 revert.

---

## 구현 상태 종합

| 인터페이스 | 상태 |
|-----------|------|
| `IMonadStaking` (모든 9개 함수) | 외부 의존(precompile), 8개 함수 호출에서 사용 |
| `IPermit2` (`permit`, `transferFrom`) | `stakeWithPermit2` 흐름에서 완전 사용 |
| `getValidator` 12개 반환 필드 | `Series9Staking`은 `accRewardPerToken`과 `commission` 2개만 활용 (나머지는 무시) |
| `getDelegator` 7개 반환 필드 | `validatorStake`(첫 번째)만 활용 |
