// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";
import "../src/PimlicoTestInfiniteSupplyToken.sol";

contract PimlicoTestInfiniteSupplyTokenScript is Script {
    function setUp() public {}

    function run() public returns (address pimlicoTestInfiniteSupplyTokenAddress) {
        address deployerSigner = vm.envAddress("SIGNER");
        bytes32 salt = vm.envBytes32("SALT");

        vm.startBroadcast(deployerSigner);

        pimlicoTestInfiniteSupplyTokenAddress =
            address(new PimlicoTestInfiniteSupplyToken{salt: salt}("Pimlico Test Token", "PIM"));

        vm.stopBroadcast();
    }
}
