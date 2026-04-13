export type ProofArtifactManifest = {
  depositCircuitPath: string;
  withdrawCircuitPath: string;
  depositZkeyPath: string;
  withdrawZkeyPath: string;
};

export const defaultProofArtifacts: ProofArtifactManifest = {
  depositCircuitPath: '/zk/build/deposit_js/deposit.wasm',
  withdrawCircuitPath: '/zk/build/withdraw_js/withdraw.wasm',
  depositZkeyPath: '/zk/build/deposit_final.zkey',
  withdrawZkeyPath: '/zk/build/withdraw_final.zkey',
};

export async function ensureProofArtifact(path: string): Promise<boolean> {
  const response = await fetch(path, { method: 'HEAD' });
  return response.ok;
}
