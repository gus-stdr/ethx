// SPDX-License-Identifier: MIT
pragma solidity ^0.8.16;

import './IStaderConfig.sol';

interface IValidatorWithdrawalVault {
    // Errors
    error InvalidRewardAmount();
    error ValidatorNotWithdrawn();
    error InsufficientBalance();
    error ETHTransferFailed(address recipient, uint256 amount);

    // Events
    event ETHReceived(address indexed sender, uint256 amount);
    event DistributeRewardFailed(uint256 rewardAmount, uint256 rewardThreshold);
    event DistributedRewards(uint256 userShare, uint256 operatorShare, uint256 protocolShare);
    event SettledFunds(uint256 userShare, uint256 operatorShare, uint256 protocolShare);
    event UpdatedStaderConfig(address _staderConfig);

    // methods
    function distributeRewards() external;

    function settleFunds() external;

    // setters
    function updateStaderConfig(address _staderConfig) external;

    // getters
    function poolId() external view returns (uint8);

    function staderConfig() external view returns (IStaderConfig);

    function validatorId() external view returns (uint256);
}