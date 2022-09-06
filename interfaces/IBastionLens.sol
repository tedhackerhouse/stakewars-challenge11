//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.4;

interface IBastionLens {
    struct RewardBalances {
        uint8 rewardType;
        address token;
        address holder;
        uint256 rewardAccrue;
        uint256 rewardEstimate;
        uint256 borrowSpeed;
        uint256 supplySpeed;
    }

    struct CTokenBalances {
        address cToken;
        uint256 balanceOf;
        uint256 borrowBalanceStored;
        uint256 exchangeRateStored;
        uint256 tokenBalance;
        uint256 tokenAllowance;
        uint256 borrowIndex;
        RewardBalances[] rewardBalances;
    }

    function cTokenBalances(
        address cTokenAddress,
        address account,
        uint8 rewardType
    ) external view returns (CTokenBalances memory);
}
