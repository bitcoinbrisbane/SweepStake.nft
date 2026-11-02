// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {MelbourneCupSweep} from "../src/MelbourneCupSweep.sol";

/// @notice Deploys the 2026 Melbourne Cup sweep.
///
///   forge script script/Deploy.s.sol --rpc-url $ETH_RPC_URL --account <keystore> --broadcast --verify
///
/// Runs three sweeps on the one contract: sweep 0 = $1, sweep 1 = $2, sweep 2 = $10, in a USD stablecoin.
///
/// Env:
///   TOKEN           betting currency     (default on Ethereum mainnet: USDT. Required on any other chain.)
///   ENTRIES_CLOSE   unix seconds         (default: 1793677800 = 3 Nov 2026 2:50pm AEDT, 1:50pm Brisbane)
///   RESULTS_OPEN    unix seconds         (default: 1793679600 = 3 Nov 2026 3:20pm AEDT, 2:20pm Brisbane)
contract Deploy is Script {
    address constant MAINNET_USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;

    function run() external returns (MelbourneCupSweep sweep) {
        address token = block.chainid == 1 ? vm.envOr("TOKEN", MAINNET_USDT) : vm.envAddress("TOKEN");
        uint256[] memory fees = entryFees(IERC20Metadata(token).decimals());
        uint64 close = uint64(vm.envOr("ENTRIES_CLOSE", uint256(1793677800)));
        uint64 results = uint64(vm.envOr("RESULTS_OPEN", uint256(1793679600)));

        vm.startBroadcast();
        sweep = new MelbourneCupSweep(IERC20(token), fees, close, results, field());
        vm.stopBroadcast();

        console.log("MelbourneCupSweep:", address(sweep));
        console.log("Sweeps:", sweep.sweepCount());
        console.log("Token:", token, IERC20Metadata(token).symbol());
        console.log("Entries close:", close);
        console.log("Results open:", results);
    }

    /// @dev $1, $2 and $10 in the token's base units. Array position = sweep id.
    function entryFees(uint8 decimals) public pure returns (uint256[] memory f) {
        uint256 one = uint256(10) ** decimals;
        f = new uint256[](3);
        f[0] = 1 * one;
        f[1] = 2 * one;
        f[2] = 10 * one;
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
