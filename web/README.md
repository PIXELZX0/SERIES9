# SER9 Web DApp

Monad Mainnet(`chainId=143`)용 SER9 풀 기능 DApp입니다.

## Setup

```bash
npm install
cp .env.example .env
npm run dev
```

## Build

```bash
npm run build
npm run preview
```

## Features

- 지갑 연결 / 네트워크 전환 안내
- 컨트랙트 주소 복사 + Explorer 링크
- 사용자 기능: 스테이킹, 락, 보상 청구, 관리 토큰 민트/소각, fee 토큰 스테이킹
- 생성자 기능: `setTokenFeeBps`
- 오너 기능: pause/unpause, 보상률/수수료/권한 설정
- 전문가 모드: `upgradeToAndCall`, `upgradeTokens` (이중 확인)
- 국문/영문 전환
