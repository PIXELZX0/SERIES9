import { mkdirSync } from 'node:fs';

mkdirSync(new URL('../build', import.meta.url), { recursive: true });
console.log('zk build workspace prepared');
console.log('Run `npx circom2 circuits/deposit.circom --r1cs --wasm --sym -o build` once dependencies are installed.');
console.log('Run `npx circom2 circuits/withdraw.circom --r1cs --wasm --sym -o build` once dependencies are installed.');
