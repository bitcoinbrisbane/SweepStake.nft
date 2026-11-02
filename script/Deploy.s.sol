// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Sweepstakes} from "../src/Sweepstakes.sol";

/// @notice Deploys Sweepstakes, creates the 2026 Melbourne Cup race and opens one sweep per price.
///
///   forge script script/Deploy.s.sol --rpc-url $ETH_RPC_URL --account <keystore> --broadcast --verify
///
/// Optional env overrides:
///   USDT            token address                      (default: Ethereum mainnet USDT)
///   SWEEP_FEES      comma-separated, token base units  (default: 5,10,50 USDT = 5000000,10000000,50000000)
///   ENTRIES_CLOSE   unix seconds                       (default: 1793674800 = 3 Nov 2026 2:00pm AEDT, 1:00pm Brisbane)
contract Deploy is Script {
    address constant MAINNET_USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;

    function run() external returns (Sweepstakes s) {
        address usdt = vm.envOr("USDT", MAINNET_USDT);
        uint64 close = uint64(vm.envOr("ENTRIES_CLOSE", uint256(1793674800)));
        uint256[] memory defaults = new uint256[](3);
        defaults[0] = 5e6; defaults[1] = 10e6; defaults[2] = 50e6;
        uint256[] memory fees = vm.envOr("SWEEP_FEES", ",", defaults);

        vm.startBroadcast();
        s = new Sweepstakes(IERC20(usdt));
        uint256 raceId = s.createRace("Melbourne Cup 2026", close, field());
        for (uint256 i; i < fees.length; ++i) {
            uint256 id = s.createSweep(raceId, fees[i]);
            console.log("Sweep", id, "entry fee", fees[i]);
        }
        vm.stopBroadcast();

        console.log("Sweepstakes:", address(s));
        console.log("Race id:", raceId);
        console.log("Entries close:", close);
    }

    /// @dev 2026 final field in saddlecloth order. Horse index = saddlecloth number - 1.
    ///      Check against the official racing.com / VRC field before deploying.
    function field() public pure returns (string[] memory h) {
        h = new string[](24);
        h[0] = "Sons And Lovers";
        h[1] = "Trustyourinstinct";
        h[2] = "Knight's Choice";
        h[3] = "Middle Earth";
        h[4] = "Vauban";
        h[5] = "Enfjaar";
        h[6] = "Royal Supremacy";
        h[7] = "Wine Dark Sea";
        h[8] = "Asterix";
        h[9] = "Goodie Two Shoes";
        h[10] = "Juja Kibo";
        h[11] = "Hopewell Rock";
        h[12] = "Onesmoothoperator";
        h[13] = "Soul Of Spain";
        h[14] = "Zahrann";
        h[15] = "So You Are";
        h[16] = "Future History";
        h[17] = "James J Braddock";
        h[18] = "Kizlyar";
        h[19] = "Point Of Law";
        h[20] = "Strictly Business";
        h[21] = "Mr Monaco";
        h[22] = "Zakouma";
        h[23] = "Shockletz";
    }
}
