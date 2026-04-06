import type { Chain } from 'viem';

const DEFAULT_CHAIN_ID = 143;
const DEFAULT_RPC_URL = 'https://rpc.monad.xyz';
const DEFAULT_EXPLORER_BASE_URL = 'https://socialscan.io';

const configuredChainId = Number(import.meta.env.VITE_CHAIN_ID ?? DEFAULT_CHAIN_ID);
const configuredRpcUrl = (import.meta.env.VITE_RPC_URL ?? DEFAULT_RPC_URL).trim();
const configuredExplorerBaseUrl = (import.meta.env.VITE_EXPLORER_BASE_URL ?? DEFAULT_EXPLORER_BASE_URL)
  .trim()
  .replace(/\/+$/, '');

export const monadMainnetChain: Chain = {
  id: configuredChainId,
  name: 'Monad Mainnet',
  nativeCurrency: {
    name: 'MON',
    symbol: 'MON',
    decimals: 18,
  },
  rpcUrls: {
    default: {
      http: [configuredRpcUrl],
    },
    public: {
      http: [configuredRpcUrl],
    },
  },
  blockExplorers: {
    default: {
      name: 'SocialScan',
      url: configuredExplorerBaseUrl,
    },
  },
  testnet: false,
};

export const networkConfig = {
  chainId: configuredChainId,
  chainName: monadMainnetChain.name,
  rpcUrl: configuredRpcUrl,
  explorerBaseUrl: configuredExplorerBaseUrl,
};

export function explorerAddressUrl(address: string): string {
  return `${networkConfig.explorerBaseUrl}/address/${address}`;
}

export function explorerTxUrl(hash: string): string {
  return `${networkConfig.explorerBaseUrl}/tx/${hash}`;
}
