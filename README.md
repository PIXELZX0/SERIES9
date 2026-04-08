# SERISE9 Multi-Token Staking System

Foundry 기반의 `SER9` 스테이킹 + 다중 관리 토큰 시스템입니다.
모든 핵심 컨트랙트는 `UUPS + ERC1967Proxy` 기반 업그레이드 구조를 사용합니다.

## 핵심 개념

- `SERISE9 (SER9)`: 기본 토큰, 초기 1조 발행 후 스테이킹 보상 경로로만 추가 민트
- `Series9Staking`: 
  - SER9 스테이킹/락/보상
  - 스테이킹 SER9 담보를 관리 토큰 민트 시 자동 락/번 시 자동 언락
  - fee 활성 토큰의 전송 수수료를 토큰별 스테이커에게 분배
  - Permit2 기반 서명 전송(`stakeWithPermit2`, `createManagedTokenWithPermit2`, `stakeFeeTokenWithPermit2`) 지원
  - 관리 토큰 생성 시 선택적 `maxSupply` + 동적 mint rate 정책(`maxMultiplierBps`, `rampStartBps`) 지원
- `Series9ManagedToken`:
  - 생성 시 `mintRate`(토큰 1개당 필요한 SER9)
  - 선택적 transfer fee(`feeEnabled`, `feeBps`)
  - staking 컨트랙트가 owner로서 mint/burn/fee 설정 제어
- `upgradeTokens`:
  - `SER9` + 생성된 모든 managed token을 한 번에 일괄 업그레이드
  - 선검증(UUPS 호환성/코드 존재) 후 단일 트랜잭션으로 원자적 실행

## 주요 규칙

1. `lock`된 SER9는 일반 스테이킹 SER9 대비 보상 가중치 1/2
2. SER9 스테이킹 보상은 초 단위가 아니라 블록 단위로 누적되며, 기본값은 `1 SER9 / block` (owner가 변경 가능)
3. 관리 토큰 민트 시 필요한 담보는 자동으로 lock되며, 전체 담보 사용량은 `usedLockedSer9 <= stakedSER9`를 유지
4. `burnAndUnlock`은 burn한 토큰 양에 해당하는 담보만 언락
5. `unlockUnused`는 레거시/잔여 미사용 락이 있는 경우에만 언락 가능
6. fee 토큰은 토큰별 독립 풀에서만 스테이킹/분배
7. transfer fee는 화이트리스트 면제형이며 staking 컨트랙트는 기본 면제
8. `burnAndUnlock`은 burn한 담보 비율만큼만 정확히 언락됨
9. `SER9.mint`는 staking 컨트랙트 주소만 호출 가능하며, owner 직접 민트는 불가
10. `maxSupply > 0`인 토큰은 공급량이 상한에 가까워질수록 민트 담보 비용이 증가하며, 상한 초과 mint는 revert

## 컨트랙트

- `src/SER9Token.sol`
- `src/Series9ManagedToken.sol`
- `src/Series9Staking.sol`

동적 mint rate 관련 주요 함수:

- `createManagedTokenWithPolicy(...)`
- `createManagedTokenWithPermit2WithPolicy(...)`
- `tokenMintPolicies(token)`
- `effectiveMintRate(token)`
- `previewMintCollateral(token, amount)`

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

- `SER9`, `Series9ManagedToken`, `Series9Staking` implementation 배포
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

운영 중 일괄 업그레이드(Owner):

```bash
export PRIVATE_KEY=<PRIVATE_KEY>
export STAKING_PROXY=<STAKING_PROXY_ADDRESS>

# 선택: 지정하지 않으면 스크립트가 새 implementation을 배포
# export NEW_SER9_IMPLEMENTATION=<SER9_IMPL>
# export NEW_MANAGED_IMPLEMENTATION=<MANAGED_IMPL>

# 선택: upgradeToAndCall용 calldata (hex, 예: 0x1234...)
# export SER9_UPGRADE_DATA=0x
# export MANAGED_UPGRADE_DATA=0x

forge script script/UpgradeTokens.s.sol:UpgradeTokens \
  --rpc-url <MONAD_RPC_URL> \
  --broadcast
```

## GitHub Actions 릴리즈 자동화

릴리즈(`published`) 시 Monad Mainnet에 새 implementation을 배포하고,
`safe.global` Transaction Builder import용 JSON을 자동 생성합니다.

- 워크플로: `.github/workflows/release-monad-mainnet-upgrade.yml`
- 배포 방식: `forge create`로 새 implementation 3개(Staking/SER9/ManagedToken) 배포 후 Safe JSON 생성
- 생성 파일: `safe-tx-upgrade-all-<release-tag>.json` (트랜잭션 2개: `upgradeToAndCall` + `upgradeTokens`)

필수 GitHub Secrets:

- `MONAD_RPC_URL`
- `PRIVATE_KEY`
- `STAKING_PROXY`

선택 GitHub Secrets:

- `STAKING_UPGRADE_DATA`
- `SER9_UPGRADE_DATA`
- `MANAGED_UPGRADE_DATA`

선택 GitHub Variables:

- `SKIP_VERIFY` (`true`/`false`, 기본값은 `false`이며 MonadVision 검증을 시도)
