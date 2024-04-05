// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";
import "../src/PimlicoEntryPointSimulations.sol";

contract PimlicoEntryPointSimulationsScript is Script {
    function setUp() public {}

    function run()
        public
        returns (address pimlicoEntryPointSimulationsAddress)
    {
        pimlicoEntryPointSimulationsAddress = address(
            new PimlicoEntryPointSimulations()
        );
    }
}
