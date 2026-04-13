export const privatePoolAbi = [
  {
    type: 'function',
    name: 'ser9',
    inputs: [],
    outputs: [{ name: '', type: 'address', internalType: 'contract IERC20' }],
    stateMutability: 'view',
  },
  {
    type: 'function',
    name: 'privateToken',
    inputs: [],
    outputs: [{ name: '', type: 'address', internalType: 'contract PrivateToken' }],
    stateMutability: 'view',
  },
  {
    type: 'function',
    name: 'shield',
    inputs: [
      { name: 'stealthAddress', type: 'bytes32', internalType: 'bytes32' },
      { name: 'ephemeralPubKey', type: 'bytes', internalType: 'bytes' },
      { name: 'viewTag', type: 'bytes1', internalType: 'bytes1' },
      { name: 'commitmentHash', type: 'bytes32', internalType: 'bytes32' },
      { name: 'amount', type: 'uint256', internalType: 'uint256' },
      {
        name: 'proof',
        type: 'tuple',
        internalType: 'struct PrivateToken.Proof',
        components: [
          { name: 'a', type: 'uint256[2]', internalType: 'uint256[2]' },
          { name: 'b', type: 'uint256[2][2]', internalType: 'uint256[2][2]' },
          { name: 'c', type: 'uint256[2]', internalType: 'uint256[2]' },
          { name: 'publicInputs', type: 'uint256[]', internalType: 'uint256[]' },
        ],
      },
    ],
    outputs: [{ name: 'leafIndex', type: 'uint256', internalType: 'uint256' }],
    stateMutability: 'nonpayable',
  },
  {
    type: 'function',
    name: 'unshield',
    inputs: [
      { name: 'nullifierHash', type: 'bytes32', internalType: 'bytes32' },
      { name: 'merkleRoot', type: 'bytes32', internalType: 'bytes32' },
      { name: 'recipient', type: 'address', internalType: 'address' },
      { name: 'amount', type: 'uint256', internalType: 'uint256' },
      {
        name: 'proof',
        type: 'tuple',
        internalType: 'struct PrivateToken.Proof',
        components: [
          { name: 'a', type: 'uint256[2]', internalType: 'uint256[2]' },
          { name: 'b', type: 'uint256[2][2]', internalType: 'uint256[2][2]' },
          { name: 'c', type: 'uint256[2]', internalType: 'uint256[2]' },
          { name: 'publicInputs', type: 'uint256[]', internalType: 'uint256[]' },
        ],
      },
    ],
    outputs: [],
    stateMutability: 'nonpayable',
  },
] as const;
