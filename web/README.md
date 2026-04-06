# SER9 Web DApp

Monad Mainnet(`chainId=143`)용 SER9 풀 기능 DApp입니다.

## Setup

```bash
npm install
cp .env.example .env
npm run dev
```

- 모바일/외부 지갑 연결이 필요하면 `.env`에 `VITE_WALLETCONNECT_PROJECT_ID`를 설정하세요.

## Build

```bash
npm run build
npm run preview
```

## Node.js 실행

```bash
npm run build
npm run start
```

- 기본 포트: `4173`
- 포트 변경: `PORT=8080 npm run start`

## Features

- 지갑 연결(브라우저 지갑, 선택적 WalletConnect) / 네트워크 전환 안내
- 사용자 기능: 스테이킹, 락, 보상 청구, 관리 토큰 민트/소각, fee 토큰 스테이킹
- 토큰 생성 시 `maxSupply`, `maxMultiplierBps`, `rampStartBps` 입력 및 토큰별 동적 민트 정책 조회
- 관리 토큰 민트 시 예상 담보(`previewMintCollateral`) 표시
- 생성자 기능: `setTokenFeeBps`
- 국문/영문 전환
