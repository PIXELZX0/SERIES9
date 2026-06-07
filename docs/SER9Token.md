# SER9Token

| 항목 | 값 |
|------|----|
| 파일 | [`src/SER9Token.sol`](../src/SER9Token.sol) |
| 라인 수 | 51 |
| 상속 | `Initializable`, `ERC20Upgradeable`, `OwnableUpgradeable`, `UUPSUpgradeable` |
| 이름 / 심볼 | `SERIES9` / `SER9` |
| 소수점 | 18 (ERC20 기본) |
| 업그레이드 | UUPS, `_authorizeUpgrade` = `onlyOwner` |

## 개요

`SER9`은 Series9 생태계의 기본 ERC20 토큰입니다.

- **초기 발행**: `initialize()` 시 `initialOwner`에게 `INITIAL_SUPPLY = 1_000_000_000_000 ether` (1조 SER9, 18 decimals)을 단발 mint합니다.
- **추가 발행 권한**: 오직 `stakingContract`(보통 `Series9Staking` 프록시) 주소만 `mint()`를 호출할 수 있습니다.
  Owner라도 직접 mint할 수 없습니다.
- **소유권 이관 흐름**: 배포 후 `setStakingContract(staking)` → `transferOwnership(staking)`을 거쳐
  staking 컨트랙트가 SER9의 owner를 겸합니다(`Series9Staking.upgradeSer9(...)`에서 이 전제를 검증).

## 상수 / 스토리지

| 이름 | 타입 | 설명 |
|------|------|------|
| `INITIAL_SUPPLY` | `uint256 constant` | `1_000_000_000_000 ether` |
| `stakingContract` | `address public` | `mint()` 호출 권한을 가지는 단일 주소 |
| `_gap` | `uint256[49] private` | UUPS 스토리지 갭 |

## Errors

| Error | 발생 조건 |
|-------|----------|
| `InvalidStakingAddress()` | `setStakingContract`에 0 주소 또는 코드가 없는 EOA가 들어왔을 때 |
| `UnauthorizedMinter()` | `mint()`를 `stakingContract` 이외가 호출했을 때 |

## Events

| Event | 시점 |
|-------|------|
| `StakingContractSet(address previousStakingContract, address stakingContractAddress)` | `setStakingContract` 성공 시 |

(ERC20 표준 `Transfer`, `Approval` / Ownable의 `OwnershipTransferred` / UUPS의 `Upgraded`는 상속 그대로)

## 함수

### `constructor()`
- 프록시 사용을 위해 `_disableInitializers()` 호출. 직접 implementation에는 initialize 불가.

### `initialize(address initialOwner) external initializer`
- ERC20 이름/심볼을 `"SERIES9" / "SER9"`로 초기화.
- `__Ownable_init(initialOwner)`.
- `initialOwner`에게 `INITIAL_SUPPLY` mint.
- **호출자**: 프록시 배포 직후 1회.

### `setStakingContract(address stakingContractAddress) external onlyOwner`
- 입력 주소가 0이거나 코드가 없으면 `InvalidStakingAddress` revert.
- `stakingContract`를 갱신, `StakingContractSet` emit.
- 이후 `mint()` 권한이 새 주소로 이동.

### `mint(address to, uint256 amount) external`
- `msg.sender != stakingContract`이면 `UnauthorizedMinter` revert.
- 내부 `_mint(to, amount)`. 캡 없음 (전체 공급량 제한 없음 — staking 보상 지급 경로 전용).

### `_authorizeUpgrade(address newImplementation) internal override onlyOwner {}`
- 본문 없음. owner만 UUPS upgrade 가능.

## 구현 상태

| 기능 | 상태 |
|------|------|
| ERC20 표준 동작 (transfer/approve 등) | OZ `ERC20Upgradeable` 그대로 |
| 초기 발행 1조 SER9 | 완전 구현 |
| Staking-only mint | 완전 구현 |
| UUPS 업그레이드 (owner gated) | 완전 구현 |
| Burn 기능 | **없음** (의도적, 이 컨트랙트에서는 노출하지 않음) |
| Pausable / Blacklist | **없음** |
| Permit (EIP-2612) | **없음** — Permit2 사용은 `Series9Staking`에서 처리 |

## 통합 포인트

- **Series9Staking**: `stakingContract`로 설정되고, owner도 양도받음.
  - 보상 청구(`claimRewards`) 시 `SER9.mint(user, reward)` 호출.
  - 업그레이드는 `Series9Staking.upgradeSer9(impl, data)` 경유.
- **Series9Identity**: `safeTransferFrom`로 mint fee 수취 후 `Series9Staking.stake(fee)`로 전달.

## 스토리지 갭

`uint256[49] private _gap` — UUPS 업그레이드 시 신규 storage 슬롯 확보용.
**주의**: 새 상태변수 추가 시 `_gap` 크기를 같은 양만큼 줄여야 합니다.

## 보안 고려사항

- `mint()`에 캡이 없으므로 `stakingContract`가 신뢰할 수 있는 컨트랙트여야 합니다.
- `setStakingContract`는 owner(= staking 프록시)만 호출 가능. 따라서 staking 자체를 통한 거버넌스/Safe가 최종 통제자.
- `_disableInitializers()`로 implementation 직접 초기화 차단.
