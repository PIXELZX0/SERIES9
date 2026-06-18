# Series9DEX — 설계 명세서

> **프로젝트:** Series9 Decentralized Exchange
> **위치:** `series9/Series9DEX/`
> **상태:** 초안 (Draft v0.1)

---

## 1. 개요 (Overview)

**Series9DEX**는 **SER9 네이티브 토큰**과 **ERC-20 토큰** 간의 탈중앙화 거래소(DEX)입니다.
AMM 기반의 시장가 주문과, 오프체인 호가창 또는 온체인 주문簿 기반의 **지정가 주문**을 모두 지원합니다.

모든 거래 페어는 고유한 **Pair ID** 로 식별되며, 해당 ID 는 페어에 속한 **풀(Pool)** 을 조회·연결하는 키로 사용됩니다.

---

## 2. 핵심 구조 (Core Architecture)

```
Series9DEX
├── Pairs (페어 목록)
│   ├── Pair ID  ──→  Pair Metadata (tokenA, tokenB, feeTier, ...)
│   │
│   ├── Spot Pool (현물 풀)
│   │     ├── tokenA reserves
│   │     └── tokenB reserves
│   │
│   └── Futures Pool (선물 풀)
│         ├── Long positions
│         ├── Short positions
│         └── Collateral (USDC 등)
│
└── Orderbook (주문 시스템)
    ├── Market Orders  (시장가)
    └── Limit Orders   (지정가)
```

---

## 3. 페어 (Pairs)

### 3.1 페어 구성
- 모든 페어는 **SER9 ↔ ERC-20 토큰** 형태로 구성됩니다.
- 예시:
  - `SER9 / USDC`
  - `SER9 / WETH`
  - `SER9 / USDT`

### 3.2 Pair ID
- 각 페어는 **고유한 `pairId`** (예: `bytes32` 또는 `uint256`) 를 가집니다.
- **용도:** 동일한 페어에 속한 모든 풀(현물/선물)을 조회·연결하기 위한 **공통 식별자**.
- 페어 ID 는 풀 컨트랙트에 저장되며, 새 풀을 추가할 때 동일한 페어 ID 를 공유합니다.

```
pairId = keccak256(abi.encodePacked(tokenSER9, tokenERC20, feeTier))
```

### 3.3 페어 ↔ 풀 매핑
- 단일 페어 ID 는 **여러 풀**을 가질 수 있습니다.
  - 현물 풀 1개
  - 선물 풀 1개 (또는 만기/마진 종류별 N개)
- 페어 ID 로 모든 풀을 조회할 수 있어야 합니다.

---

## 4. 주문 유형 (Order Types)

### 4.1 시장가 주문 (Market Order)
- AMM 의 현재 호가(현물 풀 reserves 기반)로 즉시 체결.
- 슬리피지 허용치(`minAmountOut`) 지정 필수.
- 페어 ID → 해당 현물 풀 라우팅.

### 4.2 지정가 주문 (Limit Order)
- 원하는 가격에 도달했을 때 자동 체결.
- 오프체인 오더북 + 온체인 settlement 하이브리드 구조 권장.
- 페어 ID 와 목표 가격(`limitPrice`)을 주문에 포함.

#### Limit Order 필드 (예시)
| 필드 | 타입 | 설명 |
|---|---|---|
| `maker` | `address` | 주문 등록자 |
| `pairId` | `bytes32` | 페어 ID |
| `side` | `enum (BUY / SELL)` | 매수/매도 |
| `price` | `uint256` | 지정 가격 |
| `amount` | `uint256` | 주문 수량 |
| `expiry` | `uint256` | 만료 시각 |
| `status` | `enum (OPEN / FILLED / CANCELLED)` | 주문 상태 |

---

## 5. 풀 (Pools)

### 5.1 현물 풀 (Spot Pool)
- **AMM 기반** 유동성 풀 (Uniswap V2/V3 스타일).
- 동일 페어 ID 안에서 토큰 ↔ 토큰 즉시 스왑.
- 유동성 제공자(LP) 가 유동성 공급 및 fee 분배.

### 5.2 선물 풀 (Futures Pool)
- **레버리지 포지션** 관리 (Long / Short).
- 마진 담보 기반.
- 펀딩레이트, 청산 메커니즘, 만기 처리 등 포함.
- 페어 ID 로 현물 풀과 연결되어 가격 오라클 공유.

### 5.3 현물 ↔ 선물 풀 관계
| 항목 | 현물 풀 | 선물 풀 |
|---|---|---|
| 용도 | 즉시 스왑 | 레버리지 포지션 |
| 가격 결정 | reserves 비 (x*y=k) | 오라클 / 마크 가격 |
| 페어 ID 공유 | ✅ | ✅ |
| LP / 트레이더 | LP (유동성 공급) | 트레이더 (포지션 진입) |

---

## 6. 향후 보완 항목 (To Be Defined)

> 아래 항목은 추후 상세 설계 시 결정합니다.

- [ ] 정확한 페어 수수료 티어 (`feeTier`) 구조
- [ ] 오프체인 오더북 운영 방식 (centralized relayer vs. on-chain orderbook)
- [ ] 선물 풀의 마진 통화 (USDC 단일 or 페어 quote token)
- [ ] 청산 봇 / Keeper 인센티브
- [ ] 크로스 체인 SER9 처리 여부
- [ ] 거버넌스 토큰 및 파라미터 업데이트 방식

---

## 변경 이력 (Changelog)

| 버전 | 날짜 (UTC) | 작성자 | 변경 |
|---|---|---|---|
| v0.1 | 2026-06-18 | 유서연 | 초안 작성 (페어 ID, 현물/선물 풀, 시장가/지정가 주문) |
