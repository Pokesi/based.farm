// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

interface IVoter {
    function gauges(address) external view returns (address);
}