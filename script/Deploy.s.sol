// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MelbourneCupSweep} from "../src/MelbourneCupSweep.sol";

/// @notice Deploys the 2026 Melbourne Cup sweep.
///
///   forge script script/Deploy.s.sol --rpc-url $ETH_RPC_URL --account <keystore> --broadcast --verify
///
/// Runs three sweeps on the one contract: sweep 0 = 1 USDT, sweep 1 = 2 USDT, sweep 2 = 10 USDT.
///
/// Optional env overrides:
///   USDT            token address        (default: Ethereum mainnet USDT)
///   ENTRIES_CLOSE   unix seconds         (default: 1793674800 = 3 Nov 2026 2:00pm AEDT, 1:00pm Brisbane)
contract Deploy is Script {
    address constant MAINNET_USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;

    function run() external returns (MelbourneCupSweep sweep) {
        address usdt = vm.envOr("USDT", MAINNET_USDT);
        uint64 close = uint64(vm.envOr("ENTRIES_CLOSE", uint256(1793674800)));

        vm.startBroadcast();
        sweep = new MelbourneCupSweep(IERC20(usdt), entryFees(), close, field());
        vm.stopBroadcast();

        console.log("MelbourneCupSweep:", address(sweep));
        console.log("Sweeps:", sweep.sweepCount());
        console.log("Entries close:", close);
    }

    /// @dev USDT has 6 decimals. Array position = sweep id.
    function entryFees() public pure returns (uint256[] memory f) {
        f = new uint256[](3);
        f[0] = 1e6;
        f[1] = 2e6;
        f[2] = 10e6;
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
