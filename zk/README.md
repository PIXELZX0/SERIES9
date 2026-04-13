# SERIES9 private transaction workspace

This workspace holds the circuit and prover pipeline for the private SER9 pool.

## Commands

```bash
npm install
npm run check:toolchain
npm run build:circuits
npm run export:verifiers
npm run test:vectors
```

## Notes

- The Solidity contracts in the root repo intentionally keep verifier addresses configurable.
- Shield / unshield amounts remain explicit at the ERC-20 escrow boundary.
- Private note commitments, roots, nullifiers, and announcement scanning live in the private subsystem.
