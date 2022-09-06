// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.4;


interface IBastionRewardClaimer {
    function claimReward(uint8 rewardType,address recipient) external;
}