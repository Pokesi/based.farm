// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

interface IBondTreasury {
    function totalVested() external view returns (uint256);
}