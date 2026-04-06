import { QueryClient } from '@tanstack/react-query';
import { createConfig, http } from 'wagmi';
import { injected } from 'wagmi/connectors';

import { monadMainnetChain, networkConfig } from './config/chain';

export const queryClient = new QueryClient();

export const wagmiConfig = createConfig({
  chains: [monadMainnetChain],
  connectors: [
    injected({
      shimDisconnect: true,
    }),
  ],
  transports: {
    [monadMainnetChain.id]: http(networkConfig.rpcUrl),
  },
});
