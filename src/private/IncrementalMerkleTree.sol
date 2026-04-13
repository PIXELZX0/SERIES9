// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

library IncrementalMerkleTree {
    uint32 internal constant ROOT_HISTORY_SIZE = 100;

    struct Tree {
        uint32 depth;
        uint32 nextLeafIndex;
        bytes32 root;
        uint32 currentRootIndex;
        mapping(uint256 => bytes32) filledSubtrees;
        mapping(bytes32 => bool) knownRoots;
        bytes32[ROOT_HISTORY_SIZE] recentRoots;
    }

    error TreeAlreadyInitialized();
    error TreeDepthZero();
    error TreeIsFull();

    function initialize(Tree storage self, uint32 depth) internal {
        if (self.depth != 0) revert TreeAlreadyInitialized();
        if (depth == 0) revert TreeDepthZero();

        self.depth = depth;

        bytes32 current = bytes32(0);
        for (uint32 level = 0; level < depth; ++level) {
            self.filledSubtrees[level] = current;
            current = hashPair(current, current);
        }

        self.root = current;
        self.knownRoots[current] = true;
        self.recentRoots[0] = current;
    }

    function insert(Tree storage self, bytes32 leaf) internal returns (uint256 index, bytes32 newRoot) {
        index = self.nextLeafIndex;
        uint256 capacity = uint256(1) << self.depth;
        if (index >= capacity) revert TreeIsFull();

        bytes32 current = leaf;
        uint256 currentIndex = index;

        for (uint32 level = 0; level < self.depth; ++level) {
            if ((currentIndex & 1) == 0) {
                self.filledSubtrees[level] = current;
                current = hashPair(current, zeroValue(level));
            } else {
                current = hashPair(self.filledSubtrees[level], current);
            }

            currentIndex >>= 1;
        }

        // forge-lint: disable-next-line(unsafe-typecast)
        self.nextLeafIndex = uint32(index + 1);
        self.root = current;
        self.currentRootIndex = uint32((self.currentRootIndex + 1) % ROOT_HISTORY_SIZE);
        self.recentRoots[self.currentRootIndex] = current;
        self.knownRoots[current] = true;
        newRoot = current;
    }

    function isKnownRoot(Tree storage self, bytes32 root) internal view returns (bool) {
        return self.knownRoots[root];
    }

    function zeroValue(uint32 level) internal pure returns (bytes32 value) {
        value = bytes32(0);
        for (uint32 i = 0; i < level; ++i) {
            value = hashPair(value, value);
        }
    }

    function hashPair(bytes32 left, bytes32 right) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(left, right));
    }
}
