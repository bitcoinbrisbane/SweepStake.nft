// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

/// @title Onchain pixel art for the runners
/// @notice Each horse is a 24x24 image kept in the contract as indexed pixels and turned into SVG on
///         request, the way CryptoPunks does it. A horse's coat and silks come from a hash of its
///         name, so it looks the same in every sweep. They're generated, not its real racing colours.
library HorseArt {
    struct Look {
        uint8 coat;
        bool blaze; // a white stripe down the face
        uint8 primary; // silks colour
        uint8 secondary; // silks colour, never the same as primary
        uint8 pattern;
    }

    /// @dev What each sprite character is drawn in. A silhouette sets them all to one colour.
    struct Palette {
        uint256 outline;
        uint256 main;
        uint256 shade;
        uint256 mane;
        uint256 blaze;
        uint256 white;
        uint256 eye;
        uint256 primary;
        uint256 secondary;
        uint256 pattern;
    }

    uint256 private constant SIZE = 24;
    uint256 private constant NO_PIXEL = type(uint256).max;
    uint256 private constant OUTLINE = 0x1c1410;
    uint256 private constant WHITE = 0xf5f5f0;
    uint256 private constant EYE = 0x000000;
    uint256 private constant SILHOUETTE = 0x3f4f47;

    uint256 private constant COAT_COUNT = 4;
    uint256 private constant SILK_COUNT = 12;
    uint256 private constant PATTERN_COUNT = 6;
    uint256 private constant PLAIN = 0;

    // O outline, C coat, D coat shade, M mane, W blaze, H eye highlight, E eye, N nostril,
    // B bridle in the second silks colour, S silks.
    bytes private constant SPRITE =
        "........................"
        "..............OO..OO...."
        ".............OCCOOCCO..."
        ".............OCDCCCDO..."
        "...........OOCCCCCCCMO.."
        "..........OCCCCCCCCCMMO."
        ".........OCWCCHECCCCMMMO"
        "........OCWWCCEECCBCCMMO"
        ".......OCWWCCCCCCBCCCMMO"
        "......OCWWCCCCCCBCCCCMMO"
        ".....OCWWCCCCCBDCCCCCMMO"
        "....OCCWCCCCCBDDCCCCCMMO"
        "...OCCWCCCCCBOODCCCCCMMO"
        "..OBBBBBBBBOO..ODCCCCMMO"
        "..OCCCCCCDO.....ODCCCMMO"
        "..OCNCCDDO......OCCCCMMO"
        "...ODDDDO.......OCCCCMMO"
        "....OOOO........OCCCCMMO"
        "...............OOOOOOOOO"
        "...............OSSSSSSSS"
        "..............OSSSSSSSSS"
        ".............OSSSSSSSSSS"
        "............OSSSSSSSSSSS"
        "...........OSSSSSSSSSSSS";

    // Three colours per coat: main, shade and mane. Chestnut, bay, brown, grey.
    bytes private constant COATS =
        hex"a0522d" hex"7a3b1e" hex"6a2f14"
        hex"7b4a2a" hex"5a341c" hex"1d1410"
        hex"4f3424" hex"382417" hex"1d1410"
        hex"b4b4b4" hex"8f8f8f" hex"6f6f6f";

    // In the same order as the names in _silkName.
    bytes private constant SILKS =
        hex"d62828" hex"1d4fb8" hex"1f8a3b" hex"f7c900" hex"f8f8f8" hex"1b1b1b"
        hex"f26b1d" hex"6a2fa0" hex"ef5fa7" hex"57b7f0" hex"7b1e3a" hex"14264f";

    function lookOf(string memory name) internal pure returns (Look memory look) {
        uint256 seed = uint256(keccak256(bytes(name)));
        look.coat = uint8(seed % COAT_COUNT);
        look.blaze = (seed >> 8) % 2 == 0;
        look.primary = uint8((seed >> 16) % SILK_COUNT);
        // Stepping 1 to 11 places around the 12 colours can't land back on the primary.
        look.secondary = uint8((look.primary + 1 + (seed >> 24) % (SILK_COUNT - 1)) % SILK_COUNT);
        look.pattern = uint8((seed >> 32) % PATTERN_COUNT);
    }

    /// @notice The horse as SVG rects on a 24x24 grid, with no background.
    function pixels(string memory name) internal pure returns (string memory) {
        Look memory look = lookOf(name);
        bytes memory coats = COATS;
        bytes memory silks = SILKS;
        uint256 coat = uint256(look.coat) * 3;

        Palette memory p;
        p.outline = OUTLINE;
        p.main = _colour(coats, coat);
        p.shade = _colour(coats, coat + 1);
        p.mane = _colour(coats, coat + 2);
        p.blaze = look.blaze ? WHITE : p.main;
        p.white = WHITE;
        p.eye = EYE;
        p.primary = _colour(silks, look.primary);
        p.secondary = _colour(silks, look.secondary);
        p.pattern = look.pattern;
        return _rects(p);
    }

    /// @notice A dark outline of a horse, for a ticket that has no horse yet.
    function silhouette() internal pure returns (string memory) {
        return _rects(
            Palette({
                outline: SILHOUETTE,
                main: SILHOUETTE,
                shade: SILHOUETTE,
                mane: SILHOUETTE,
                blaze: SILHOUETTE,
                white: SILHOUETTE,
                eye: SILHOUETTE,
                primary: SILHOUETTE,
                secondary: SILHOUETTE,
                pattern: PLAIN
            })
        );
    }

    function coatName(string memory name) internal pure returns (string memory) {
        string[4] memory names = ["Chestnut", "Bay", "Brown", "Grey"];
        return names[lookOf(name).coat];
    }

    function silksName(string memory name) internal pure returns (string memory) {
        Look memory look = lookOf(name);
        if (look.pattern == PLAIN) return string.concat("Plain ", _silkName(look.primary));
        string[6] memory patterns = ["", "hoops", "stripes", "sash", "checks", "quarters"];
        return string.concat(_silkName(look.primary), " and ", _silkName(look.secondary), " ", patterns[look.pattern]);
    }

    function _silkName(uint256 index) private pure returns (string memory) {
        string[12] memory names =
            ["Red", "Blue", "Green", "Yellow", "White", "Black", "Orange", "Purple", "Pink", "Sky", "Maroon", "Navy"];
        return names[index];
    }

    /// @dev Merges runs of one colour in each row into a single rect, which keeps the SVG small.
    function _rects(Palette memory palette) private pure returns (string memory out) {
        bytes memory sprite = SPRITE;
        for (uint256 y; y < SIZE; ++y) {
            string memory row;
            uint256 x;
            while (x < SIZE) {
                uint256 colour = _colourAt(sprite, palette, x, y);
                uint256 start = x++;
                while (x < SIZE && _colourAt(sprite, palette, x, y) == colour) ++x;
                if (colour != NO_PIXEL) row = string.concat(row, _rect(start, y, x - start, colour));
            }
            out = string.concat(out, row);
        }
    }

    function _rect(uint256 x, uint256 y, uint256 width, uint256 colour) private pure returns (string memory) {
        return string.concat(
            '<rect x="', Strings.toString(x),
            '" y="', Strings.toString(y),
            '" width="', Strings.toString(width),
            '" height="1" fill="#', _hex(colour), '"/>'
        );
    }

    function _colourAt(bytes memory sprite, Palette memory p, uint256 x, uint256 y) private pure returns (uint256) {
        bytes1 code = sprite[y * SIZE + x];
        if (code == ".") return NO_PIXEL;
        if (code == "C") return p.main;
        if (code == "D") return p.shade;
        if (code == "M") return p.mane;
        if (code == "W") return p.blaze;
        if (code == "H") return p.white;
        if (code == "E") return p.eye;
        if (code == "B") return p.secondary;
        if (code == "S") return _isSecondary(p.pattern, x, y) ? p.secondary : p.primary;
        return p.outline; // O and N
    }

    /// @dev Plain, hoops, stripes, sash, checks and quarters, in that order.
    function _isSecondary(uint256 pattern, uint256 x, uint256 y) private pure returns (bool) {
        if (pattern == 1) return y % 2 == 1;
        if (pattern == 2) return x % 2 == 1;
        if (pattern == 3) return (x + y) % 6 < 2;
        if (pattern == 4) return (x + y) % 2 == 1;
        if (pattern == 5) return (x < 18) == (y < 21);
        return false;
    }

    function _colour(bytes memory table, uint256 index) private pure returns (uint256) {
        uint256 at = index * 3;
        return (uint256(uint8(table[at])) << 16) | (uint256(uint8(table[at + 1])) << 8) | uint256(uint8(table[at + 2]));
    }

    function _hex(uint256 colour) private pure returns (string memory) {
        bytes16 digits = "0123456789abcdef";
        bytes memory out = new bytes(6);
        for (uint256 i = 6; i > 0; --i) {
            out[i - 1] = digits[colour & 0xf];
            colour >>= 4;
        }
        return string(out);
    }
}
