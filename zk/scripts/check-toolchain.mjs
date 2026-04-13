import { spawnSync } from 'node:child_process';

const circomCheck = spawnSync('npx', ['circom2', '--help'], { stdio: 'ignore' });
const snarkjsCheck = spawnSync('npx', ['snarkjs', '--help'], { stdio: 'ignore' });

if (circomCheck.status !== 0 || snarkjsCheck.status !== 0) {
  console.error('circom2 and snarkjs must be installable through the local zk workspace.');
  process.exit(1);
}

console.log('zk toolchain resolved through local workspace');
