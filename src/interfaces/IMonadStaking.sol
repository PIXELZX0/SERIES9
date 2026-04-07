// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

interface IMonadStaking {
    function delegate(uint64 validatorId) external payable returns (bool success);

    function undelegate(uint64 validatorId, uint256 amount, uint8 withdrawId) external returns (bool success);

    function withdraw(uint64 validatorId, uint8 withdrawId) external returns (bool success);

    function claimRewards(uint64 validatorId) external returns (bool success);

    function getExecutionValidatorSet(uint32 startIndex)
        external
        returns (bool isDone, uint32 nextIndex, uint64[] memory valIds);

    function getValidator(uint64 validatorId)
        external
        returns (
            address authAddress,
            uint64 flags,
            uint256 stake,
            uint256 accRewardPerToken,
            uint256 commission,
            uint256 unclaimedRewards,
            uint256 consensusStake,
            uint256 consensusCommission,
            uint256 snapshotStake,
            uint256 snapshotCommission,
            bytes memory secpPubkey,
            bytes memory blsPubkey
        );

    function getDelegator(uint64 validatorId, address delegator)
        external
        returns (
            uint256 stake,
            uint256 accRewardPerToken,
            uint256 unclaimedRewards,
            uint256 deltaStake,
            uint256 nextDeltaStake,
            uint64 deltaEpoch,
            uint64 nextDeltaEpoch
        );

    function getEpoch() external returns (uint64 epoch, bool inEpochDelayPeriod);
}
