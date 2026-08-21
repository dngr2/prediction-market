// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {PredictionMarket} from "../src/PredictionMarket.sol";

/// @notice Deploys the PredictionMarket factory. It has no constructor args and no
///         owner — every market carries its own collateral, oracle, and deadline.
contract Deploy is Script {
    function run() external returns (PredictionMarket market) {
        vm.startBroadcast();
        market = new PredictionMarket();
        vm.stopBroadcast();
    }
}
