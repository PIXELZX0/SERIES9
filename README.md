# SERIES9

Foundry 기반의 `SER9` 토큰 + 스테이킹 시스템입니다.
모든 핵심 컨트랙트는 `UUPS + ERC1967Proxy` 기반 업그레이드 구조를 사용합니다.

## 핵심 개념

- `SERISE9 (SER9)`: 기본 토큰, 초기 1조 발행 후 스테이킹 보상 경로로만 추가 민트
- `Series9Staking`:
  - SER9 스테이킹/보상
  - Permit2 기반 서명 전송(`stakeWithPermit2`) 지원
  - Monad epoch 조회 실패 시 fail-open 하지 않고 즉시 revert (`MonadEpochReadFailed`)
  - pause 중에도 이미 만기 도달한 `claimUnstaked(...)`, `claimUnstakedMonad(...)` 원금 출금은 허용
  - Monad unstake coverage queueing은 `processPendingMonadUnstakeCoverage(maxValidators)`로 누구나 진행 가능하고, 만기 도달한 undelegation 출금은 `processMaturedMonadUndelegations(maxTickets)`로 누구나 진행 가능
  - `claimUnstakedMonad(...)`는 이미 backing/withdraw 처리가 끝난 요청만 청구하며, backlog를 durable 하게 전진시키는 경로는 위 permissionless processor들임
  - validator/ticket 전역 처리는 cursor 기반 bounded batch로 나뉘므로 backlog가 큰 경우 여러 번 호출해 점진적으로 처리 가능
- 업그레이드 경로:
  - `upgradeSer9(...)`로 `SER9`를 명시적으로 업그레이드

## 주요 규칙

1. SER9 스테이킹 보상은 초 단위가 아니라 블록 단위로 누적되며, 기본값은 `1 SER9 / block` (owner가 변경 가능)
2. `SER9.mint`는 staking 컨트랙트 주소만 호출 가능하며, owner 직접 민트는 불가
3. Monad unstake backing queue / validator reward harvest / matured undelegation withdraw / delegation rebalance는 더 이상 전체 배열 full scan에 의존하지 않고 bounded multi-call progress를 사용

## 컨트랙트

- `src/SER9Token.sol`
- `src/Series9Staking.sol`

Monad unstake/undelegation 관련 주요 함수:

- `requestUnstakeMonad(amount)`
- `claimUnstakedMonad(requestId)`
- `processPendingMonadUnstakeCoverage(maxValidators)`
- `processMaturedMonadUndelegations(maxTickets)`

## 빠른 시작

```bash
forge build
forge test -vv
```

## 배포 (예시)

```bash
export PRIVATE_KEY=<PRIVATE_KEY>
# 선택: 초기 블록당 보상 (기본값: 1 ether = 1 SER9)
export REWARD_PER_BLOCK=1000000000000000000

forge script script/DeploySeries9.s.sol:DeploySeries9 \
  --rpc-url <MONAD_RPC_URL> \
  --broadcast
```

배포 스크립트 동작:

- `SER9`, `Series9Staking` implementation 배포
- `SER9`, `Series9Staking` proxy(ERC1967Proxy) 배포 + initialize 실행
- `SER9.setStakingContract(stakingProxy)` 설정
- `SER9.transferOwnership(stakingProxy)`로 소유권을 staking에 이관
- `PRIVATE_KEY`의 주소를 staking owner/deployer로 사용

운영 중 블록당 보상 변경(Owner):

```bash
cast send <STAKING_ADDRESS> "setRewardRatePerBlock(uint256)" <NEW_REWARD_PER_BLOCK> \
  --private-key $PRIVATE_KEY \
  --rpc-url <MONAD_RPC_URL>
```

운영 중 Permit2 주소 설정(Owner):

```bash
cast send <STAKING_ADDRESS> "setPermit2(address)" <PERMIT2_ADDRESS> \
  --private-key $PRIVATE_KEY \
  --rpc-url <MONAD_RPC_URL>
```

운영 중 업그레이드(Owner):

```bash
export PRIVATE_KEY=<PRIVATE_KEY>
export STAKING_PROXY=<STAKING_PROXY_ADDRESS>

# 선택: 지정하지 않으면 스크립트가 새 implementation을 배포
# export NEW_SER9_IMPLEMENTATION=<SER9_IMPL>

# 선택: SER9 upgradeToAndCall용 calldata (hex, 예: 0x1234...)
# export SER9_UPGRADE_DATA=0x

forge script script/UpgradeTokens.s.sol:UpgradeTokens \
  --rpc-url <MONAD_RPC_URL> \
  --broadcast
```

## GitHub Actions 릴리즈 자동화

릴리즈(`published`) 시 Monad Mainnet에 새 implementation을 배포하고,
`safe.global` Transaction Builder import용 JSON을 자동 생성합니다.

- 워크플로: `.github/workflows/release-monad-mainnet-upgrade.yml`
- 배포 방식: `forge create`로 새 implementation(Staking/SER9) 배포 후 Safe JSON 생성
- 생성 파일: `safe-tx-upgrade-<release-tag-slug>.json`
  - 트랜잭션 2개: `upgradeToAndCall`(Staking) + `upgradeSer9`(SER9)
  - 온체인 bytecode가 이미 일치하면 해당 컨트랙트는 배포/트랜잭션에서 제외

필수 GitHub Secrets:

- `MONAD_RPC_URL`
- `PRIVATE_KEY`
- `STAKING_PROXY`

선택 GitHub Secrets:

- `STAKING_UPGRADE_DATA`
- `SER9_UPGRADE_DATA`

선택 GitHub Variables:

- `SKIP_VERIFY` (`true`/`false`, 기본값은 `false`이며 MonadVision 검증을 시도)

## 관련 레포

- [SERIES9Identity](https://github.com/PIXELZX0/SERIES9Identity) — Identity NFT + identity 지갑 컨트랙트
- [SERIES9DEX](https://github.com/PIXELZX0/SERIES9DEX) — DEX (현물/오더북/선물)
- [SERIES9_Front](https://github.com/PIXELZX0/SERIES9_Front) — 웹 프론트엔드
