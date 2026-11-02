// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

/// @title Onchain pixel art for the runners
/// @notice Each runner is a 24x24 image of its horse and a jockey in its silks, kept in the contract
///         as indexed pixels and turned into SVG on request, the way CryptoPunks does it. The coats and
///         silks are the real ones, simplified to fit: a jacket is only 6 pixels square.
library HorseArt {
    /// @dev A runner's coat and silks, in one storage slot. Each mask says which pixels of that part
    ///      use its accent colour, one bit per pixel, row by row from the top left.
    struct Look {
        uint8 coat;
        uint24 body;
        uint24 bodyAccent;
        uint24 centre; // a third jacket colour in the middle 2x2 pixels, or 0 for none
        uint24 sleeve;
        uint24 sleeveAccent;
        uint24 cap;
        uint24 capAccent;
        uint40 bodyMask; // 6 wide, 6 high
        uint16 sleeveMask; // 2 wide, 6 high, with the first column on the outside of the arm
        uint24 capMask; // 6 wide, 3 high
    }

    struct Runner {
        string name;
        string colours; // the official description of the silks
        Look look;
    }

    /// @dev What the art needs while drawing. A silhouette ignores the colours.
    struct Palette {
        bool blank;
        uint256 main;
        uint256 shade;
        uint256 mane;
        Look look;
    }

    uint8 internal constant CHESTNUT = 0;
    uint8 internal constant BAY = 1;
    uint8 internal constant BROWN = 2;
    uint8 internal constant BAY_OR_BROWN = 3;

    uint256 private constant SIZE = 24;
    uint256 private constant NO_PIXEL = type(uint256).max;
    uint256 private constant OUTLINE = 0x1c1410;
    uint256 private constant WHITE = 0xf5f5f0;
    uint256 private constant EYE = 0x000000;
    uint256 private constant FACE = 0xf0cdb0;
    uint256 private constant SILHOUETTE = 0x3f4f47;

    // Where the jockey's parts sit in the sprite.
    uint256 private constant CAP_X = 15;
    uint256 private constant CAP_Y = 11;
    uint256 private constant JACKET_X = 15;
    uint256 private constant JACKET_Y = 18;
    uint256 private constant LEFT_SLEEVE_X = 13;
    uint256 private constant RIGHT_SLEEVE_X = 22;

    // Horse: O outline, C coat, D coat shade, M mane, H eye highlight, E eye, N nostril, G bridle.
    // Jockey: k cap, f face, b jacket, l and r sleeves.
    bytes private constant SPRITE =
        "........................"
        "..............OO..OO...."
        ".............OCCOOCCO..."
        ".............OCDCCCDO..."
        "...........OOCCCCCCCMO.."
        "..........OCCCCCCCCCMMO."
        ".........OCCCCHECCCCMMMO"
        "........OCCCCCEECCGCCMMO"
        ".......OCCCCCCCCCGCCCMMO"
        "......OCCCCCCCCCGCCCCMMO"
        ".....OCCCCCCCCGDOOOOCMMO"
        "....OCCCCCCCCGDOkkkkOMMO"
        "...OCCCCCCCCGOOkkkkkkOMO"
        "..OGGGGGGGGOO.OkkkkkkOMO"
        "..OCCCCCCDO...OOffffOOMO"
        "..OCNCCDDO.....OffffOMMO"
        "...ODDDDO.......OffOCMMO"
        "....OOOO.....OOOOffOOOOO"
        "............OllbbbbbbrrO"
        "............OllbbbbbbrrO"
        "............OllbbbbbbrrO"
        "............OllbbbbbbrrO"
        "............OllbbbbbbrrO"
        "............OllbbbbbbrrO";

    // Three colours per coat: main, shade and mane. In the order of the constants above.
    bytes private constant COATS =
        hex"a0522d" hex"7a3b1e" hex"6a2f14"
        hex"7b4a2a" hex"5a341c" hex"1d1410"
        hex"4f3424" hex"382417" hex"1d1410"
        hex"644030" hex"47291b" hex"1d1410";

    /// @notice The runner as SVG rects on a 24x24 grid, with no background.
    function pixels(Look memory look) internal pure returns (string memory) {
        bytes memory coats = COATS;
        uint256 coat = uint256(look.coat) * 3;
        return _rects(
            Palette({
                blank: false,
                main: _colour(coats, coat),
                shade: _colour(coats, coat + 1),
                mane: _colour(coats, coat + 2),
                look: look
            })
        );
    }

    /// @notice A dark outline of a horse and jockey, for a ticket that has no horse yet.
    function silhouette() internal pure returns (string memory) {
        Palette memory palette;
        palette.blank = true;
        return _rects(palette);
    }

    function coatName(Look memory look) internal pure returns (string memory) {
        string[4] memory names = ["Chestnut", "Bay", "Brown", "Bay or brown"];
        return names[look.coat];
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
        if (p.blank) return SILHOUETTE;
        if (code == "C") return p.main;
        if (code == "D") return p.shade;
        if (code == "M") return p.mane;
        if (code == "H") return WHITE;
        if (code == "E") return EYE;
        if (code == "f") return FACE;
        if (code == "G") return p.look.sleeve;
        if (code == "b") return _jacket(p.look, x - JACKET_X, y - JACKET_Y);
        if (code == "l") return _sleeve(p.look, x - LEFT_SLEEVE_X, y - JACKET_Y);
        if (code == "r") return _sleeve(p.look, RIGHT_SLEEVE_X - x, y - JACKET_Y);
        if (code == "k") return _cap(p.look, x - CAP_X, y - CAP_Y);
        return OUTLINE; // O and N
    }

    function _jacket(Look memory look, uint256 x, uint256 y) private pure returns (uint256) {
        if (look.centre != 0 && (x == 2 || x == 3) && (y == 2 || y == 3)) return look.centre;
        return _isSet(look.bodyMask, y * 6 + x) ? look.bodyAccent : look.body;
    }

    function _sleeve(Look memory look, uint256 column, uint256 y) private pure returns (uint256) {
        return _isSet(look.sleeveMask, y * 2 + column) ? look.sleeveAccent : look.sleeve;
    }

    function _cap(Look memory look, uint256 x, uint256 y) private pure returns (uint256) {
        return _isSet(look.capMask, y * 6 + x) ? look.capAccent : look.cap;
    }

    function _isSet(uint256 mask, uint256 bit) private pure returns (bool) {
        return (mask >> bit) & 1 == 1;
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
