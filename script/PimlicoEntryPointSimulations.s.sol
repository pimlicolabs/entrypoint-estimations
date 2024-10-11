// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";
import "../src/v07/PimlicoEntryPointSimulations.sol";

contract PimlicoEntryPointSimulationsScript is Script {
    function setUp() public {}

    function run() public returns (address pimlicoEntryPointSimulationsAddress) {
        address deployerSigner = vm.envAddress("SIGNER");
        bytes32 salt = vm.envBytes32("SALT");

        vm.startBroadcast(deployerSigner);

        pimlicoEntryPointSimulationsAddress = address(new PimlicoEntryPointSimulations{salt: salt}());

        vm.stopBroadcast();
    }
}
