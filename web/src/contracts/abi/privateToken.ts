export const privateTokenAbi = [
  {
    type: 'function',
    name: 'announcementsLength',
    inputs: [],
    outputs: [{ name: '', type: 'uint256', internalType: 'uint256' }],
    stateMutability: 'view',
  },
  {
    type: 'function',
    name: 'currentRoot',
    inputs: [],
    outputs: [{ name: '', type: 'bytes32', internalType: 'bytes32' }],
    stateMutability: 'view',
  },
  {
    type: 'function',
    name: 'getAnnouncementsByViewTag',
    inputs: [
      { name: 'viewTag', type: 'bytes1', internalType: 'bytes1' },
      { name: 'fromBlock', type: 'uint256', internalType: 'uint256' },
      { name: 'limit', type: 'uint256', internalType: 'uint256' },
    ],
    outputs: [
      {
        name: 'items',
        type: 'tuple[]',
        internalType: 'struct PrivateToken.Announcement[]',
        components: [
          { name: 'stealthAddress', type: 'bytes32', internalType: 'bytes32' },
          { name: 'ephemeralPubKey', type: 'bytes', internalType: 'bytes' },
          { name: 'viewTag', type: 'bytes1', internalType: 'bytes1' },
          { name: 'blockNumber', type: 'uint64', internalType: 'uint64' },
          { name: 'leafIndex', type: 'uint32', internalType: 'uint32' },
          { name: 'commitmentHash', type: 'bytes32', internalType: 'bytes32' },
        ],
      },
    ],
    stateMutability: 'view',
  },
  {
    type: 'function',
    name: 'isKnownRoot',
    inputs: [{ name: 'root', type: 'bytes32', internalType: 'bytes32' }],
    outputs: [{ name: '', type: 'bool', internalType: 'bool' }],
    stateMutability: 'view',
  },
  {
    type: 'function',
    name: 'nullifierSpent',
    inputs: [{ name: '', type: 'bytes32', internalType: 'bytes32' }],
    outputs: [{ name: '', type: 'bool', internalType: 'bool' }],
    stateMutability: 'view',
  },
] as const;
