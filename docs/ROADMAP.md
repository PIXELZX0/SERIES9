# 로드맵

## 크로스체인 브릿지 — Wormhole NTT

상태: **검토 완료, 미착수** (2026-10-11)

### 결정
- **Monad = hub, Locking 모드.** SER9 코드 변경 없음, staking-only mint 유지.
- Burning 모드 기각: `mint()`가 `stakingContract` 단일 민터라 다중 민터 + `burn(uint256)` 업그레이드 필요 (`upgradeSer9` 경유, `_gap` 47→46, 스토리지 레이아웃 리스크).
- spoke 체인: 새 ERC20(NTT `INttToken`: `mint` / `burn(uint256)` / `setMinter`), minter = spoke NttManager. Solana면 SPL(decimals 9) + mint authority를 NTT 프로그램에.
- 불변식: `hub NttManager 잠긴 SER9 ≥ Σ spoke totalSupply`.

### NTT 제약
- 8 decimals trimming: 1e-8 SER9 미만 dust는 미전송 → 프론트에서 금액 반올림.
- trimmed 금액 uint64 → 1회 최대 약 1.84e11 SER9. rate limit으로 더 낮게 제한.

### 보안 요구사항
1. NttManager / transceiver owner·업그레이드 권한 = Safe. pauser는 별도 키.
2. outbound/inbound rate limit 필수, 초과분은 queue.
3. 신뢰 모델 문서화 (Guardian 13/19). 필요 시 transceiver 2개 + threshold 2.
4. 배포 전 Executor capabilities에서 Monad·spoke 모두 NTT v1(ERN1) 릴레이 지원 확인.

### 미정
- [ ] spoke 체인 선정 (Ethereum / Base / Solana 등)
- [ ] rate limit 값 (일일 한도, 총공급 대비 %)

### 작업
- [ ] spoke 토큰 컨트랙트 + 테스트
- [ ] testnet 배포 (`ntt init` → `ntt add-chain Monad --mode locking` → spoke `--mode burning` → `ntt push`)
- [ ] testnet 검증: 왕복 후 locked == spoke supply, rate limit queue, pause 차단
- [ ] mainnet 배포 + owner Safe 이전
