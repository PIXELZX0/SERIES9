import { QueryClient } from '@tanstack/react-query';
import { createConfig, http } from 'wagmi';
import { injected, walletConnect } from 'wagmi/connectors';

import { monadMainnetChain, networkConfig } from './config/chain';

export const queryClient = new QueryClient();
const walletConnectProjectId = (import.meta.env.VITE_WALLETCONNECT_PROJECT_ID ?? '').trim();

export const wagmiConfig = createConfig({
  chains: [monadMainnetChain],
  connectors: [
    injected({
      shimDisconnect: true,
    }),
    ...(walletConnectProjectId
      ? [
          walletConnect({
            projectId: walletConnectProjectId,
            showQrModal: true,
          }),
        ]
      : []),
  ],
  transports: {
    [monadMainnetChain.id]: http(networkConfig.rpcUrl),
  },
});
