// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

interface IGauge {
    function deposit(uint256 _amount, address _recipient) external;
    function getReward(address _account) external;
    function withdraw(uint256 _amount) external;
    function balanceOf(address) external view returns(uint256);
}