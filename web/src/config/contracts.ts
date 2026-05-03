import { getAddress, isAddress, type Address } from 'viem';

const FALLBACK_CONTRACTS = {
  ser9Proxy: '0x461b9beFb3c81c988501C89F5caaBa03b02565d0',
  stakingProxy: '0xFa76a92716D9fE7DF902266651Ca64014c4dC35A',
  identityProxy: '0xEBa0Fd485ADe50AE5182EbB4ff98fCC5613572e9',
  permit2: '0x000000000022D473030F116dDEE9F6B43aC78BA3',
  ser9Implementation: '0x25144ac0787a2AE5E963D309e43f3251f80Fad87',
  managedTokenImplementation: '0x7Fb4D4d14FF5c3e03A8227cC7182CF4284ceeaE8',
  stakingImplementation: '0xBfBc7Dab0d72f1DBe61ab157C20A3B6eB3E34672',
} as const;

function readAddressFromEnv(envKey: string, fallback: string): Address {
  const raw = (import.meta.env[envKey] as string | undefined)?.trim();

  if (raw && isAddress(raw)) {
    return getAddress(raw);
  }

  return getAddress(fallback);
}

export const contracts = {
  ser9Proxy: readAddressFromEnv('VITE_SER9_PROXY', FALLBACK_CONTRACTS.ser9Proxy),
  stakingProxy: readAddressFromEnv('VITE_STAKING_PROXY', FALLBACK_CONTRACTS.stakingProxy),
  identityProxy: readAddressFromEnv('VITE_IDENTITY_PROXY', FALLBACK_CONTRACTS.identityProxy),
  permit2: readAddressFromEnv('VITE_PERMIT2', FALLBACK_CONTRACTS.permit2),
  ser9Implementation: readAddressFromEnv(
    'VITE_SER9_IMPLEMENTATION',
    FALLBACK_CONTRACTS.ser9Implementation,
  ),
  managedTokenImplementation: readAddressFromEnv(
    'VITE_MANAGED_IMPLEMENTATION',
    FALLBACK_CONTRACTS.managedTokenImplementation,
  ),
  stakingImplementation: readAddressFromEnv(
    'VITE_STAKING_IMPLEMENTATION',
    FALLBACK_CONTRACTS.stakingImplementation,
  ),
} as const;

export const contractEntries = [
  {
    key: 'ser9Proxy',
    title: 'SER9 Proxy',
    address: contracts.ser9Proxy,
  },
  {
    key: 'stakingProxy',
    title: 'Staking Proxy',
    address: contracts.stakingProxy,
  },
  {
    key: 'identityProxy',
    title: 'Identity Proxy',
    address: contracts.identityProxy,
  },
  {
    key: 'permit2',
    title: 'Permit2',
    address: contracts.permit2,
  },
  {
    key: 'ser9Implementation',
    title: 'SER9 Implementation',
    address: contracts.ser9Implementation,
  },
  {
    key: 'managedTokenImplementation',
    title: 'ManagedToken Implementation',
    address: contracts.managedTokenImplementation,
  },
  {
    key: 'stakingImplementation',
    title: 'Staking Implementation',
    address: contracts.stakingImplementation,
  },
] as const;

export type ContractEntryKey = (typeof contractEntries)[number]['key'];
