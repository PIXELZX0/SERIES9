export const walletAbi = [
  {
    type: 'function',
    name: 'identity',
    inputs: [],
    outputs: [{ name: '', type: 'address', internalType: 'address' }],
    stateMutability: 'view',
  },
  {
    type: 'function',
    name: 'tokenId',
    inputs: [],
    outputs: [{ name: '', type: 'uint256', internalType: 'uint256' }],
    stateMutability: 'view',
  },
  {
    type: 'function',
    name: 'execute',
    inputs: [
      { name: 'to', type: 'address', internalType: 'address' },
      { name: 'value', type: 'uint256', internalType: 'uint256' },
      { name: 'data', type: 'bytes', internalType: 'bytes' },
    ],
    outputs: [{ name: 'result', type: 'bytes', internalType: 'bytes' }],
    stateMutability: 'nonpayable',
  },
  {
    type: 'function',
    name: 'executeBatch',
    inputs: [
      { name: 'tos', type: 'address[]', internalType: 'address[]' },
      { name: 'values', type: 'uint256[]', internalType: 'uint256[]' },
      { name: 'datas', type: 'bytes[]', internalType: 'bytes[]' },
    ],
    outputs: [{ name: 'results', type: 'bytes[]', internalType: 'bytes[]' }],
    stateMutability: 'nonpayable',
  },
] as const;
