# SER9 컨트랙트 문서

`src/` 아래 모든 컨트랙트의 기능과 구현 상태를 정리한 문서입니다.
모든 핵심 컨트랙트는 **UUPS + ERC1967Proxy** 업그레이드 패턴(`_authorizeUpgrade onlyOwner`)을 사용합니다.

Identity NFT / identity 지갑 문서는 [SERIES9Identity](https://github.com/PIXELZX0/SERIES9Identity) 레포로 이전했습니다.

## 컨트랙트 목록

| 컨트랙트 | 파일 | 라인 수 | 역할 |
|----------|------|--------:|------|
| `SER9Token` | [`src/SER9Token.sol`](../src/SER9Token.sol) | 51 | ERC20 토큰. 초기 1조 발행 후 staking 컨트랙트만 추가 mint 가능 |
| `Series9Staking` | [`src/Series9Staking.sol`](../src/Series9Staking.sol) | 1,708 | SER9/MON 듀얼 스테이킹 + Monad validator 위임/리밸런싱 |
| `IMonadStaking` | [`src/interfaces/IMonadStaking.sol`](../src/interfaces/IMonadStaking.sol) | 47 | Monad staking precompile (`0x1000`) 인터페이스 |
| `IPermit2` | [`src/interfaces/IPermit2.sol`](../src/interfaces/IPermit2.sol) | 21 | Uniswap Permit2 부분 인터페이스 |

## 개별 문서

- [`DeveloperGuide.md`](./DeveloperGuide.md) — **개발자용 사용 가이드** (SER9/Staking 통합 방법, cast/viem 예시)
- [`SER9Token.md`](./SER9Token.md) — SER9 ERC20 토큰
- [`Series9Staking.md`](./Series9Staking.md) — 스테이킹 + Monad 위임 (핵심 컨트랙트)
- [`Interfaces.md`](./Interfaces.md) — 외부 인터페이스

## 구현 상태 한눈에 보기

| 영역 | 상태 |
|------|------|
| SER9 ERC20 + 초기 발행 + staking-only mint | 완전 구현 |
| SER9 stake/unstake (epoch 지연 청구) | 완전 구현 |
| MON stake/unstake (Monad precompile 위임) | 완전 구현 |
| Permit2 기반 stake | 완전 구현 |
| Monad validator 스코어 기반 자동 위임/리밸런싱 | 완전 구현 |
| Pending unstake coverage (permissionless 처리) | 완전 구현 |
| Slashing shortfall 추적 (`monadSlashingDeficit`) | 누적만 — 분배/회수 로직 없음 |

자세한 구현/미구현 내역은 각 컨트랙트 문서의 **"구현 상태"** 섹션을 참조하세요.

## 업그레이드 구조

```
SER9Token (UUPS)              <-- owner: Series9Staking (이관됨)
  └─ upgrade는 Series9Staking.upgradeSer9(...) 경유

Series9Staking (UUPS)         <-- owner: deployer (또는 Safe)
  └─ self upgrade: upgradeToAndCall (onlyOwner)
```

Identity/Wallet 업그레이드 구조는 [SERIES9Identity](https://github.com/PIXELZX0/SERIES9Identity) 레포 문서 참조.

## 빠른 시작

```bash
forge build
forge test -vv
```

자세한 배포/업그레이드 절차는 루트 [`README.md`](../README.md) 참조.
