// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.4;
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

interface IAuroraStNear {
    function swapwNEARForstNEAR(uint256 _amount) external;
}