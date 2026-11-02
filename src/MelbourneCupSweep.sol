// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IERC165} from "@openzeppelin/contracts/interfaces/IERC165.sol";
import {IERC4906} from "@openzeppelin/contracts/interfaces/IERC4906.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {HorseArt} from "./HorseArt.sol";

/// @title Melbourne Cup sweepstake
/// @notice Several sweeps run on the same race, one per entry fee. Pick a sweep and pay its fee to
///         mint an NFT ticket, which pulls a random horse from that sweep's hat on the spot. Each
///         horse only comes out once. The NFT holding the winner takes that sweep's pool.
/// @dev    Each sweep goes Open -> Settled, or Cancelled at any point before Settled. Horses and
///         the race result are shared, so one scratch or settle applies to every sweep.
///         The randomness uses block.prevrandao, which is known a block ahead. Only wallets can
///         enter, which stops a contract buying and reverting until it gets the horse it wants, but
///         someone determined could still time a purchase to pick their horse. That's fine for a
///         sweep between mates, not for large pools.
contract MelbourneCupSweep is IERC4906, ERC721, Ownable {
    using SafeERC20 for IERC20;

    enum State { Open, Settled, Cancelled }

    struct Sweep {
        uint256 entryFee;
        State state;
        uint16 ticketCount;
        uint256 winningTicket; // ticket id, 0 = none
    }

    struct Ticket {
        uint16 horse; // horse index + 1
        bool claimed;
    }

    uint256 private constant ID_BASE = 1000; // ticket id = (sweep + 1) * 1000 + ticket number
    uint256 public constant SETTLE_GRACE = 7 days;

    IERC20 public immutable token;
    uint64 public immutable entriesClose;
    uint64 public immutable resultsOpen; // settle() reverts before this, to give the official result time to come in
    address private immutable _self;
    uint256 private immutable _oneToken; // one whole token in base units, for labelling fees

    Sweep[] public sweeps;
    string[] private _horses;
    mapping(uint256 => bool) public scratched; // horse index => scratched
    mapping(uint256 => mapping(uint256 => uint256)) public horseTicket; // sweep => horse index => ticket id
    mapping(uint256 => Ticket) private _tickets; // ticket id => ticket
    mapping(uint256 => uint256) private _hatSize; // sweep => horses still in its hat
    mapping(uint256 => mapping(uint256 => uint256)) private _hat; // sweep => position => horse index + 1, 0 = untouched

    bool public raceSettled;
    uint256 public winningHorse; // horse index, valid once raceSettled

    event Entered(uint256 indexed sweepId, uint256 indexed ticketId, address indexed holder);
    event HorseAssigned(uint256 indexed ticketId, uint256 indexed horse, string name);
    event Scratched(uint256 indexed horse);
    event Settled(uint256 indexed sweepId, uint256 indexed horse, uint256 indexed ticketId, address winner, uint256 prize);
    event Cancelled(uint256 indexed sweepId);
    event Claimed(uint256 indexed ticketId, address indexed to, uint256 amount);

    error WrongState();
    error EntriesClosed();
    error SweepFull();
    error WalletsOnly();
    error BadHorse();
    error BadSweep();
    error BadFee();
    error BadTimes();
    error NotYourTicket();
    error NothingToClaim();
    error TooEarly();

    /// @param token_ The betting currency. Use a USD stablecoin, because tickets are labelled in dollars.
    ///        Reverts if this address has no token on the chain being deployed to.
    constructor(
        IERC20 token_,
        uint256[] memory entryFees,
        uint64 entriesClose_,
        uint64 resultsOpen_,
        string[] memory horses_
    )
        ERC721("Melbourne Cup Sweep 2026", "CUP26")
        Ownable(msg.sender)
    {
        uint256 horseTotal = horses_.length;
        uint256 sweepTotal = entryFees.length;
        if (horseTotal == 0 || horseTotal >= ID_BASE) revert BadHorse();
        if (sweepTotal == 0) revert BadSweep();
        if (resultsOpen_ < entriesClose_) revert BadTimes();
        token = token_;
        entriesClose = entriesClose_;
        resultsOpen = resultsOpen_;
        _self = address(this);
        _oneToken = uint256(10) ** IERC20Metadata(address(token_)).decimals();
        for (uint256 i; i < horseTotal; ++i) _horses.push(horses_[i]);
        for (uint256 i; i < sweepTotal; ++i) {
            if (entryFees[i] == 0) revert BadFee();
            sweeps.push(Sweep({entryFee: entryFees[i], state: State.Open, ticketCount: 0, winningTicket: 0}));
            _hatSize[i] = horseTotal;
        }
    }

    // ---------------------------------------------------------------- entering

    /// @notice Buy one ticket in a sweep, and pull a random horse from its hat. Approve that sweep's
    ///         fee first. You can buy several.
    function enter(uint256 sweepId) external returns (uint256 ticketId) {
        Sweep storage s = _sweep(sweepId);
        if (s.state != State.Open) revert WrongState();
        if (block.timestamp >= entriesClose) revert EntriesClosed();
        if (msg.sender != tx.origin) revert WalletsOnly();

        uint256 horse = _pullFromHat(sweepId);
        ticketId = _ticketId(sweepId, s.ticketCount);
        ++s.ticketCount;
        _tickets[ticketId].horse = uint16(horse + 1);
        horseTicket[sweepId][horse] = ticketId;
        _mint(msg.sender, ticketId);
        token.safeTransferFrom(msg.sender, _self, s.entryFee);
        emit Entered(sweepId, ticketId, msg.sender);
        emit HorseAssigned(ticketId, horse, _horses[horse]);
    }

    /// @dev A Fisher-Yates shuffle done one pull at a time. Each position starts out holding the
    ///      horse with that index, and the last horse in the hat moves into the gap a pull leaves.
    ///      A scratched horse that comes out is dropped, and the buyer pulls again.
    function _pullFromHat(uint256 sweepId) private returns (uint256 horse) {
        mapping(uint256 => uint256) storage hat = _hat[sweepId];
        uint256 size = _hatSize[sweepId];
        while (size != 0) {
            uint256 seed = uint256(keccak256(abi.encode(block.prevrandao, block.timestamp, _self, msg.sender, sweepId, size)));
            uint256 position = seed % size;
            --size;
            horse = _horseAt(hat, position);
            hat[position] = _horseAt(hat, size) + 1;
            if (!scratched[horse]) {
                _hatSize[sweepId] = size;
                return horse;
            }
        }
        revert SweepFull();
    }

    function _horseAt(mapping(uint256 => uint256) storage hat, uint256 position) private view returns (uint256) {
        uint256 stored = hat[position];
        return stored == 0 ? position : stored - 1;
    }

    // ---------------------------------------------------------------- race day admin

    /// @notice Mark a horse as scratched in every sweep, and send the entry fee back to whoever holds
    ///         it. If a payment can't go through, say the token has blocked the holder's address, the
    ///         scratching still stands and that holder can claim the refund instead.
    function scratch(uint256 horse) external onlyOwner {
        if (raceSettled) revert WrongState();
        if (horse >= _horses.length || scratched[horse]) revert BadHorse();
        scratched[horse] = true;
        emit Scratched(horse);
        uint256 sweepTotal = sweeps.length;
        for (uint256 id; id < sweepTotal; ++id) {
            uint256 t = horseTicket[id][horse];
            if (t != 0) _refund(t, sweeps[id].entryFee);
        }
        emit BatchMetadataUpdate(0, type(uint256).max);
    }

    function _refund(uint256 ticketId, uint256 fee) private {
        Ticket storage tk = _tickets[ticketId];
        if (tk.claimed) return;
        tk.claimed = true;
        address holder = ownerOf(ticketId);
        if (token.trySafeTransfer(holder, fee)) emit Claimed(ticketId, holder, fee);
        else tk.claimed = false;
    }

    /// @notice Record the official winner (horse index) for every sweep at once. In each sweep the
    ///         holder of that horse takes the pool. A sweep where nobody holds it is cancelled and
    ///         refunded. Reverts before resultsOpen.
    function settle(uint256 horse) external onlyOwner {
        if (raceSettled) revert WrongState();
        if (block.timestamp < resultsOpen) revert TooEarly();
        if (horse >= _horses.length || scratched[horse]) revert BadHorse();

        raceSettled = true;
        winningHorse = horse;
        uint256 sweepTotal = sweeps.length;
        for (uint256 id; id < sweepTotal; ++id) {
            Sweep storage s = sweeps[id];
            if (s.state == State.Cancelled) continue;

            uint256 t = horseTicket[id][horse];
            if (t == 0) {
                _cancel(id);
                continue;
            }
            s.winningTicket = t;
            s.state = State.Settled;
            emit Settled(id, horse, t, ownerOf(t), prizePool(id));
        }
        emit BatchMetadataUpdate(0, type(uint256).max);
    }

    /// @notice Call a sweep off and refund its tickets. The owner can do this at any time before
    ///         settling. Anyone can do it once the owner is a week late settling.
    function cancel(uint256 sweepId) external {
        Sweep storage s = _sweep(sweepId);
        if (s.state != State.Open) revert WrongState();
        if (msg.sender != owner() && block.timestamp < uint256(entriesClose) + SETTLE_GRACE) revert TooEarly();
        _cancel(sweepId);
        emit BatchMetadataUpdate(0, type(uint256).max);
    }

    function _cancel(uint256 sweepId) private {
        sweeps[sweepId].state = State.Cancelled;
        emit Cancelled(sweepId);
    }

    // ---------------------------------------------------------------- claiming

    /// @notice Collect what a ticket is owed: the prize for the winning ticket, or the entry fee back
    ///         if its sweep was cancelled or its horse was scratched.
    ///         Whoever holds the NFT when claiming gets paid. The NFT stays with them as a keepsake.
    function claim(uint256 ticketId) external {
        if (ownerOf(ticketId) != msg.sender) revert NotYourTicket();
        uint256 amount = claimable(ticketId);
        if (amount == 0) revert NothingToClaim();
        _tickets[ticketId].claimed = true;
        token.safeTransfer(msg.sender, amount);
        emit Claimed(ticketId, msg.sender, amount);
        emit MetadataUpdate(ticketId);
    }

    /// @notice Amount ticket `ticketId` can claim right now.
    function claimable(uint256 ticketId) public view returns (uint256) {
        _requireOwned(ticketId);
        Ticket storage tk = _tickets[ticketId];
        if (tk.claimed) return 0;
        uint256 sweepId = _sweepOf(ticketId);
        Sweep storage s = sweeps[sweepId];
        if (s.state == State.Cancelled || scratched[tk.horse - 1]) return s.entryFee;
        if (s.state == State.Settled && s.winningTicket == ticketId) return prizePool(sweepId);
        return 0;
    }

    /// @notice A sweep's pot: its entry fees, except those owed back to tickets with scratched horses.
    ///         Tracked per sweep because all sweeps share the contract's balance, so tokens sent
    ///         straight to the contract joins no pool and can't be recovered.
    function prizePool(uint256 sweepId) public view returns (uint256) {
        Sweep storage s = _sweep(sweepId);
        if (s.state == State.Cancelled) return 0;
        uint256 ticketTotal = s.ticketCount;
        uint256 inPlay = ticketTotal;
        for (uint256 i; i < ticketTotal; ++i) {
            if (scratched[_tickets[_ticketId(sweepId, i)].horse - 1]) --inPlay;
        }
        return inPlay * s.entryFee;
    }

    // ---------------------------------------------------------------- views

    function sweepCount() external view returns (uint256) { return sweeps.length; }
    function horseCount() external view returns (uint256) { return _horses.length; }
    function horseName(uint256 horse) external view returns (string memory) { return _horses[horse]; }

    /// @return sweepId the ticket's sweep
    /// @return holder current NFT owner
    /// @return horse horse index
    /// @return name horse name
    /// @return claimed whether the ticket has been paid out
    function ticket(uint256 ticketId)
        external
        view
        returns (uint256 sweepId, address holder, uint256 horse, string memory name, bool claimed)
    {
        holder = _requireOwned(ticketId);
        sweepId = _sweepOf(ticketId);
        Ticket storage tk = _tickets[ticketId];
        claimed = tk.claimed;
        horse = tk.horse - 1;
        name = _horses[horse];
    }

    /// @notice Where a ticket stands, in words. Also shown on the NFT.
    function ticketStatus(uint256 ticketId) public view returns (string memory) {
        _requireOwned(ticketId);
        Ticket storage tk = _tickets[ticketId];
        Sweep storage s = sweeps[_sweepOf(ticketId)];
        bool won = s.state == State.Settled && s.winningTicket == ticketId;
        if (tk.claimed) return won ? "Winner - paid" : "Refunded";
        if (s.state == State.Cancelled) return "Cancelled - refund available";
        if (scratched[tk.horse - 1]) return "Scratched - refund available";
        if (won) return "Winner - prize to claim";
        return s.state == State.Settled ? "Did not win" : "In the race";
    }

    function activeHorses() public view returns (uint256 count) {
        uint256 horseTotal = _horses.length;
        for (uint256 i; i < horseTotal; ++i) if (!scratched[i]) ++count;
    }

    /// @notice How many more tickets a sweep can sell: the horses still running that nobody holds.
    function availableHorses(uint256 sweepId) external view returns (uint256 count) {
        _sweep(sweepId);
        uint256 horseTotal = _horses.length;
        for (uint256 i; i < horseTotal; ++i) if (!scratched[i] && horseTicket[sweepId][i] == 0) ++count;
    }

    function _sweep(uint256 sweepId) private view returns (Sweep storage) {
        if (sweepId >= sweeps.length) revert BadSweep();
        return sweeps[sweepId];
    }

    /// @dev Ids read as sweep then ticket number: 1001-1024, 2001-2024, 3001-3024. Never 0.
    function _ticketId(uint256 sweepId, uint256 index) private pure returns (uint256) {
        return (sweepId + 1) * ID_BASE + index + 1;
    }

    function _sweepOf(uint256 ticketId) private pure returns (uint256) {
        return ticketId / ID_BASE - 1;
    }

    // ---------------------------------------------------------------- NFT metadata

    /// @dev What a ticket's image and metadata show.
    struct Card {
        uint256 sweepId;
        string fee; // such as $10
        string number; // the ticket's number within its sweep
        string horse;
        string cloth;
        string status;
    }

    function supportsInterface(bytes4 interfaceId) public view override(ERC721, IERC165) returns (bool) {
        return interfaceId == bytes4(0x49064906) || super.supportsInterface(interfaceId);
    }

    /// @notice A horse's pixel art on its own, as a data URI. The art itself lives in this contract.
    function horseImage(uint256 horse) external view returns (string memory) {
        if (horse >= _horses.length) revert BadHorse();
        return _svgDataUri(
            string.concat(
                '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" shape-rendering="crispEdges">',
                HorseArt.pixels(_horses[horse]),
                "</svg>"
            )
        );
    }

    /// @notice Fully onchain metadata and image. They change as the ticket's fortunes do.
    /// @dev    Horse names and the token's symbol come from the deployer's choices, and are assumed
    ///         free of quotes and XML characters.
    function tokenURI(uint256 ticketId) public view override returns (string memory) {
        _requireOwned(ticketId);
        uint256 sweepId = _sweepOf(ticketId);
        Card memory card;
        card.sweepId = sweepId;
        card.fee = string.concat("$", Strings.toString(sweeps[sweepId].entryFee / _oneToken));
        card.number = Strings.toString(ticketId % ID_BASE);
        card.status = ticketStatus(ticketId);
        uint16 h = _tickets[ticketId].horse;
        card.horse = _horses[h - 1];
        card.cloth = string.concat("Saddlecloth ", Strings.toString(h));

        return string.concat(
            "data:application/json;base64,",
            Base64.encode(bytes(string.concat(_summary(card), _svgDataUri(_svg(card, _art(ticketId))), _attributes(card, ticketId))))
        );
    }

    function _summary(Card memory card) private view returns (string memory) {
        return string.concat(
            '{"name":"Melbourne Cup 2026 ', card.fee, " Sweep #", card.number,
            '","description":"An NFT ticket in the ', card.fee, " Melbourne Cup 2026 sweep, paid in ",
            IERC20Metadata(address(token)).symbol(),
            '. Hold the winning horse to take the pool.","image":"'
        );
    }

    function _attributes(Card memory card, uint256 ticketId) private view returns (string memory) {
        return string.concat(
            '","attributes":[{"trait_type":"Sweep","value":"', card.fee,
            '"},{"trait_type":"Horse","value":"', card.horse,
            '"},{"trait_type":"Status","value":"', card.status, '"}',
            _traits(ticketId), "]}"
        );
    }

    function _svgDataUri(string memory svg) private pure returns (string memory) {
        return string.concat("data:image/svg+xml;base64,", Base64.encode(bytes(svg)));
    }

    /// @dev The ticket's horse, faded if it was scratched.
    function _art(uint256 ticketId) private view returns (string memory) {
        uint16 h = _tickets[ticketId].horse;
        string memory pixels = HorseArt.pixels(_horses[h - 1]);
        return scratched[h - 1] ? string.concat('<g opacity=".35">', pixels, "</g>") : pixels;
    }

    function _traits(uint256 ticketId) private view returns (string memory) {
        string memory name = _horses[_tickets[ticketId].horse - 1];
        return string.concat(
            ',{"trait_type":"Coat","value":"', HorseArt.coatName(name),
            '"},{"trait_type":"Silks","value":"', HorseArt.silksName(name), '"}'
        );
    }

    function _svg(Card memory card, string memory art) private pure returns (string memory) {
        string memory colour = card.sweepId == 0 ? "#cd8f55" : card.sweepId == 1 ? "#c3ccd6" : "#e6bd4f";
        string memory tint = card.sweepId == 0 ? "#e8cdb0" : card.sweepId == 1 ? "#dfe5ec" : "#f3e2a8";
        return string.concat(_svgArt(colour, tint, art), _svgText(card, colour));
    }

    function _svgArt(string memory colour, string memory tint, string memory art) private pure returns (string memory) {
        return string.concat(
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 400 400"><rect width="400" height="400" fill="#123326"/>'
            '<rect x="16" y="16" width="368" height="368" rx="18" fill="none" stroke-width="3" stroke="', colour,
            '"/><rect x="116" y="60" width="168" height="168" fill="', tint,
            '"/><g transform="translate(116 60) scale(7)" shape-rendering="crispEdges">', art, "</g>"
        );
    }

    function _svgText(Card memory card, string memory colour) private pure returns (string memory) {
        string memory names = string.concat(
            '<g font-family="Georgia,serif" text-anchor="middle" fill="#f5f0e1">'
            '<text x="200" y="47" font-size="18" letter-spacing="1">Melbourne Cup 2026</text>'
            '<text x="200" y="264" font-size="28" font-weight="bold">', card.horse,
            '</text><text x="200" y="286" font-size="14">', card.cloth, "</text>"
        );
        return string.concat(
            names,
            '<text x="200" y="326" font-size="17"><tspan font-size="30" font-weight="bold" fill="', colour, '">', card.fee,
            "</tspan> NFT ticket #", card.number,
            '</text><text x="200" y="358" font-size="16" fill="', colour, '">', card.status, "</text></g></svg>"
        );
    }
}
