// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {MelbourneCupSweep} from "../src/MelbourneCupSweep.sol";
import {HorseArt} from "../src/HorseArt.sol";

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

    // Colours picked from Racing Australia's official silks images.
    uint24 private constant BLACK = 0x141414;
    uint24 private constant CERISE = 0xc9259b;
    uint24 private constant CREAM = 0xf6f0c0;
    uint24 private constant CROWN = 0xe8b92c;
    uint24 private constant DARKNAVY = 0x0b0b7a;
    uint24 private constant EMERALD = 0x0e9a4c;
    uint24 private constant GOLD = 0xffd21f;
    uint24 private constant GREEN = 0x35a84a;
    uint24 private constant GREY = 0xb7c2cc;
    uint24 private constant ICE = 0xb3e4f2;
    uint24 private constant INK = 0x1f2a7a;
    uint24 private constant KHAKI = 0xd0b04e;
    uint24 private constant LIME = 0xd4dd2a;
    uint24 private constant LOGO = 0x1f5fb4;
    uint24 private constant MIDBLUE = 0x1f3f9c;
    uint24 private constant ORANGE = 0xf28a1e;
    uint24 private constant PINK = 0xf5b6d0;
    uint24 private constant PURPLE = 0x8a2f9a;
    uint24 private constant RED = 0xe8202a;
    uint24 private constant ROYAL = 0x0a5fb4;
    uint24 private constant SKY = 0x40c0f0;
    uint24 private constant TEAL = 0x1a3a5c;
    uint24 private constant WHITE = 0xf8f8f8;
    uint24 private constant YELLOW = 0xffd800;

    // Jacket patterns: which of the 6x6 pixels use the accent colour.
    uint40 private constant BODY_BAND = 0xfff000;
    uint40 private constant BODY_BOX = 0x1e492780;
    uint40 private constant BODY_BRACES = 0x492492492;
    uint40 private constant BODY_DIAGONAL = 0x67398c673;
    uint40 private constant BODY_FIVE = 0x48030c012;
    uint40 private constant BODY_HOOPS = 0xfc0fc0fc0;
    uint40 private constant BODY_HORSESHOE = 0x312861861;
    uint40 private constant BODY_LOGO = 0x79e000;
    uint40 private constant BODY_PLAIN = 0x0;
    uint40 private constant BODY_RINGS = 0xfe186187f;
    uint40 private constant BODY_SASH = 0x4711c430;
    uint40 private constant BODY_STAR = 0x127bf300;
    uint40 private constant BODY_THREE = 0xc300cf3;

    // Sleeve patterns: 2 wide and 6 high, with the first column on the outside of the arm.
    uint16 private constant SLEEVE_ARMBAND = 0xc0;
    uint16 private constant SLEEVE_CHECKS = 0x666;
    uint16 private constant SLEEVE_HALVED = 0x3f;
    uint16 private constant SLEEVE_HOOPS = 0xccc;
    uint16 private constant SLEEVE_PLAIN = 0x0;
    uint16 private constant SLEEVE_SPOTS = 0x30c;
    uint16 private constant SLEEVE_STRIPE = 0x555;

    // Cap patterns: 6 wide and 3 high.
    uint24 private constant CAP_CHECKS = 0x2a56a;
    uint24 private constant CAP_PEAK = 0x3f000;
    uint24 private constant CAP_PLAIN = 0x0;
    uint24 private constant CAP_QUARTERED = 0x381c7;
    uint24 private constant CAP_STAR = 0x300;
    uint24 private constant CAP_STRIPES = 0x2aaaa;

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

    /// @dev The 2026 final field in saddlecloth order, from Racing Australia's form guide published
    ///      2 Nov 2026. Horse index = saddlecloth number - 1. Colours are its official text, and the
    ///      looks are that text and its silks images, simplified to fit the pixel art.
    function field() public pure returns (HorseArt.Runner[] memory h) {
        h = new HorseArt.Runner[](24);
        h[0] = HorseArt.Runner("Sons And Lovers", "White, Pink Star, Pink Cap, White Star", HorseArt.Look(HorseArt.BAY, WHITE, PINK, uint24(0), WHITE, WHITE, PINK, WHITE, BODY_STAR, SLEEVE_PLAIN, CAP_STAR));
        h[1] = HorseArt.Runner("Trustyourinstinct", "Green And Gold Hoops, White Cap", HorseArt.Look(HorseArt.CHESTNUT, GREEN, GOLD, uint24(0), GREEN, GOLD, WHITE, WHITE, BODY_HOOPS, SLEEVE_HOOPS, CAP_PLAIN));
        h[2] = HorseArt.Runner("Knight's Choice", "Cerise, Black Star, Lime And Black Stars Sleeves, Lime Cap, Black Peak", HorseArt.Look(HorseArt.BAY, CERISE, BLACK, uint24(0), LIME, BLACK, LIME, BLACK, BODY_STAR, SLEEVE_SPOTS, CAP_PEAK));
        h[3] = HorseArt.Runner("Middle Earth", "Royal Blue, Lime Green Stars, Multi Blue And Grey Checked Sleeves And Black And White Striped Cap", HorseArt.Look(HorseArt.BAY, ROYAL, LIME, uint24(0), MIDBLUE, GREY, BLACK, WHITE, BODY_FIVE, SLEEVE_CHECKS, CAP_STRIPES));
        h[4] = HorseArt.Runner("Vauban", "Royal Blue, White Horseshoe, Black And White Checked Sleeves And Cap", HorseArt.Look(HorseArt.CHESTNUT, ROYAL, WHITE, uint24(0), BLACK, WHITE, BLACK, WHITE, BODY_HORSESHOE, SLEEVE_CHECKS, CAP_CHECKS));
        h[5] = HorseArt.Runner("Enfjaar", "Purple, Green Stars And Sleeves, Quartered Cap", HorseArt.Look(HorseArt.BAY, PURPLE, GREEN, uint24(0), GREEN, GREEN, GREEN, PURPLE, BODY_FIVE, SLEEVE_PLAIN, CAP_QUARTERED));
        h[6] = HorseArt.Runner("Royal Supremacy", "Royal Blue, White Horseshoe, Black And White Checked Sleeves, Black Cap", HorseArt.Look(HorseArt.BAY, ROYAL, WHITE, uint24(0), BLACK, WHITE, BLACK, BLACK, BODY_HORSESHOE, SLEEVE_CHECKS, CAP_PLAIN));
        h[7] = HorseArt.Runner("Wine Dark Sea", "Green, Blue, Black, Purple And Yellow Recurring Pattern With Red Centre", HorseArt.Look(HorseArt.BAY, BLACK, GREEN, RED, BLACK, YELLOW, BLACK, PURPLE, BODY_RINGS, SLEEVE_HOOPS, CAP_CHECKS));
        h[8] = HorseArt.Runner("Asterix", "Emerald Green, Red Band And Armbands, Quartered Cap", HorseArt.Look(HorseArt.BAY, EMERALD, RED, uint24(0), EMERALD, RED, RED, EMERALD, BODY_BAND, SLEEVE_ARMBAND, CAP_QUARTERED));
        h[9] = HorseArt.Runner("Goodie Two Shoes", "Green And Gold Hoops, Green Cap, White Star", HorseArt.Look(HorseArt.BAY, GREEN, GOLD, uint24(0), GREEN, GOLD, GREEN, WHITE, BODY_HOOPS, SLEEVE_HOOPS, CAP_STAR));
        h[10] = HorseArt.Runner("Juja Kibo", "Royal Blue, Lime 5 Stars, Multi Blue And Grey Checked Sleeves And Cap", HorseArt.Look(HorseArt.BAY, ROYAL, LIME, uint24(0), MIDBLUE, GREY, MIDBLUE, GREY, BODY_FIVE, SLEEVE_CHECKS, CAP_CHECKS));
        h[11] = HorseArt.Runner("Hopewell Rock", "Royal Blue, Gold Sleeves, Red Cap", HorseArt.Look(HorseArt.BAY, ROYAL, ROYAL, uint24(0), KHAKI, KHAKI, RED, RED, BODY_PLAIN, SLEEVE_PLAIN, CAP_PLAIN));
        h[12] = HorseArt.Runner("Onesmoothoperator", "Light Blue, Dark Blue Hollow Box, Striped Sleeves And Cap", HorseArt.Look(HorseArt.BAY_OR_BROWN, ICE, INK, uint24(0), ICE, INK, ICE, INK, BODY_BOX, SLEEVE_STRIPE, CAP_STRIPES));
        h[13] = HorseArt.Runner("Soul Of Spain", "Navy Blue, White Band And Go Racing Logo, Armbands And Cap", HorseArt.Look(HorseArt.BROWN, MIDBLUE, WHITE, RED, MIDBLUE, WHITE, WHITE, WHITE, BODY_BAND, SLEEVE_ARMBAND, CAP_PLAIN));
        h[14] = HorseArt.Runner("Zahrann", "Navy Blue, Pale Yellow Spots, Halved Sleeves, Diamonds Cap", HorseArt.Look(HorseArt.BAY, TEAL, CREAM, uint24(0), TEAL, CREAM, TEAL, CREAM, BODY_FIVE, SLEEVE_HALVED, CAP_CHECKS));
        h[15] = HorseArt.Runner("So You Are", "Green, White Braces, Yellow Hooped Sleeves And Cap", HorseArt.Look(HorseArt.BAY_OR_BROWN, GREEN, WHITE, uint24(0), YELLOW, GREEN, YELLOW, YELLOW, BODY_BRACES, SLEEVE_HOOPS, CAP_PLAIN));
        h[16] = HorseArt.Runner("Future History", "Red And Yellow Diagonal Stripes, Dark Blue Sleeves", HorseArt.Look(HorseArt.BAY, RED, YELLOW, uint24(0), MIDBLUE, MIDBLUE, RED, RED, BODY_DIAGONAL, SLEEVE_PLAIN, CAP_PLAIN));
        h[17] = HorseArt.Runner("James J Braddock", "Navy Blue, Pale Yellow Spots, Halved Sleeves, Quartered Cap", HorseArt.Look(HorseArt.BAY, TEAL, CREAM, uint24(0), TEAL, CREAM, CREAM, TEAL, BODY_FIVE, SLEEVE_HALVED, CAP_QUARTERED));
        h[18] = HorseArt.Runner("Kizlyar", "White, Pink Star", HorseArt.Look(HorseArt.BAY, WHITE, PINK, uint24(0), WHITE, WHITE, WHITE, WHITE, BODY_STAR, SLEEVE_PLAIN, CAP_PLAIN));
        h[19] = HorseArt.Runner("Point Of Law", "Dark Blue, Pale Blue Diagonal Stripes, Quartered Cap", HorseArt.Look(HorseArt.BAY, ROYAL, SKY, uint24(0), ROYAL, ROYAL, SKY, ROYAL, BODY_DIAGONAL, SLEEVE_PLAIN, CAP_QUARTERED));
        h[20] = HorseArt.Runner("Strictly Business", "Navy Blue, Gold Crowns", HorseArt.Look(HorseArt.BROWN, DARKNAVY, CROWN, uint24(0), DARKNAVY, DARKNAVY, DARKNAVY, DARKNAVY, BODY_THREE, SLEEVE_PLAIN, CAP_PLAIN));
        h[21] = HorseArt.Runner("Mr Monaco", "Red, Blueblood Logo, Red Sleeves, Blueblood Logo, Red And White Star Cap", HorseArt.Look(HorseArt.BAY, RED, LOGO, uint24(0), RED, RED, RED, WHITE, BODY_LOGO, SLEEVE_PLAIN, CAP_STAR));
        h[22] = HorseArt.Runner("Zakouma", "Pale Blue, Green Hoops And Cap", HorseArt.Look(HorseArt.BAY, SKY, GREEN, uint24(0), SKY, SKY, GREEN, GREEN, BODY_HOOPS, SLEEVE_PLAIN, CAP_PLAIN));
        h[23] = HorseArt.Runner("Shockletz", "Black, Orange Checked Sash, Checked Cap", HorseArt.Look(HorseArt.BAY, BLACK, ORANGE, uint24(0), BLACK, BLACK, BLACK, ORANGE, BODY_SASH, SLEEVE_PLAIN, CAP_CHECKS));
    }
}
