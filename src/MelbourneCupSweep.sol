// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IERC165} from "@openzeppelin/contracts/interfaces/IERC165.sol";
import {IERC4906} from "@openzeppelin/contracts/interfaces/IERC4906.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

/// @title Melbourne Cup sweepstake
/// @notice Several sweeps run on the same race, one per entry fee. Pick a sweep and pay its fee to
///         mint an NFT ticket. When entries close, the owner draws each sweep: one shuffle gives
///         every ticket in it a different horse. The NFT holding the winner takes that sweep's pool.
/// @dev    Each sweep goes Open -> Drawn -> Settled, or Cancelled at any point before Settled.
///         Horses and the race result are shared, so one scratch or settle applies to every sweep.
///         Only the owner can draw, because the seed is known a block ahead: anyone able to call
///         draw() could revert until they got the horse they wanted. A block proposer can still
///         bias block.prevrandao slightly, which is fine for a sweep between mates.
contract MelbourneCupSweep is IERC4906, ERC721, Ownable {
    using SafeERC20 for IERC20;

    enum State { Open, Drawn, Settled, Cancelled }

    struct Sweep {
        uint256 entryFee;
        State state;
        uint16 ticketCount;
        uint256 winningTicket; // ticket id, 0 = none
    }

    struct Ticket {
        uint16 horse; // horse index + 1; 0 = no horse (not drawn yet, or the field ran out)
        bool claimed;
    }

    uint16 private constant NONE = 0;
    uint256 private constant ID_BASE = 1000; // ticket id = (sweep + 1) * 1000 + ticket number
    uint256 private constant ONE_USDT = 1e6;
    uint256 public constant SETTLE_GRACE = 7 days;

    IERC20 public immutable token;
    uint64 public immutable entriesClose;

    Sweep[] public sweeps;
    string[] private _horses;
    mapping(uint256 => bool) public scratched; // horse index => scratched
    uint256 private _scratchedCount; // saves every entry reading each horse's flag
    mapping(uint256 => mapping(uint256 => uint256)) public horseTicket; // sweep => horse index => ticket id
    mapping(uint256 => Ticket) private _tickets; // ticket id => ticket

    bool public raceSettled;
    uint256 public winningHorse; // horse index, valid once raceSettled

    event Entered(uint256 indexed sweepId, uint256 indexed ticketId, address indexed holder);
    event Drawn(uint256 indexed sweepId, uint256 seed);
    event HorseAssigned(uint256 indexed ticketId, uint256 indexed horse, string name);
    event Scratched(uint256 indexed horse);
    event Settled(uint256 indexed sweepId, uint256 indexed horse, uint256 indexed ticketId, address winner, uint256 prize);
    event Cancelled(uint256 indexed sweepId);
    event Claimed(uint256 indexed ticketId, address indexed to, uint256 amount);

    error WrongState();
    error EntriesClosed();
    error EntriesStillOpen();
    error SweepFull();
    error NoTickets();
    error BadHorse();
    error BadSweep();
    error BadFee();
    error NotYourTicket();
    error NothingToClaim();
    error TooEarly();

    constructor(IERC20 token_, uint256[] memory entryFees, uint64 entriesClose_, string[] memory horses_)
        ERC721("Melbourne Cup Sweep 2026", "CUP26")
        Ownable(msg.sender)
    {
        uint256 horseTotal = horses_.length;
        uint256 sweepTotal = entryFees.length;
        if (horseTotal == 0 || horseTotal >= ID_BASE) revert BadHorse();
        if (sweepTotal == 0) revert BadSweep();
        token = token_;
        entriesClose = entriesClose_;
        for (uint256 i; i < horseTotal; ++i) _horses.push(horses_[i]);
        for (uint256 i; i < sweepTotal; ++i) {
            if (entryFees[i] == 0) revert BadFee();
            sweeps.push(Sweep({entryFee: entryFees[i], state: State.Open, ticketCount: 0, winningTicket: 0}));
        }
    }

    // ---------------------------------------------------------------- entering

    /// @notice Buy one ticket in a sweep. Approve that sweep's fee first. You can buy several.
    function enter(uint256 sweepId) external returns (uint256 ticketId) {
        Sweep storage s = _sweep(sweepId);
        if (s.state != State.Open) revert WrongState();
        if (block.timestamp >= entriesClose) revert EntriesClosed();
        if (s.ticketCount >= activeHorses()) revert SweepFull();

        ticketId = _ticketId(sweepId, s.ticketCount);
        ++s.ticketCount;
        _mint(msg.sender, ticketId);
        token.safeTransferFrom(msg.sender, address(this), s.entryFee);
        emit Entered(sweepId, ticketId, msg.sender);
    }

    // ---------------------------------------------------------------- the draw

    /// @notice Shuffle the field and give each ticket in a sweep a horse. Owner only. Allowed once
    ///         entries close, or as soon as every horse in the sweep has a ticket.
    function draw(uint256 sweepId) external onlyOwner {
        Sweep storage s = _sweep(sweepId);
        if (s.state != State.Open) revert WrongState();
        uint256 n = s.ticketCount;
        if (n == 0) revert NoTickets();
        if (block.timestamp < entriesClose && n < activeHorses()) revert EntriesStillOpen();

        (uint256[] memory pool, uint256 seed) = _shuffle(sweepId, n);

        // If horses were scratched after people entered, the last tickets miss out and get refunds.
        uint256 assigned = n < pool.length ? n : pool.length;
        for (uint256 i; i < assigned; ++i) {
            uint256 t = _ticketId(sweepId, i);
            _tickets[t].horse = uint16(pool[i] + 1);
            horseTicket[sweepId][pool[i]] = t;
            emit HorseAssigned(t, pool[i], _horses[pool[i]]);
        }

        s.state = State.Drawn;
        emit Drawn(sweepId, seed);
        emit BatchMetadataUpdate(0, type(uint256).max);
    }

    /// @dev Fisher-Yates shuffle of the horses still running.
    function _shuffle(uint256 sweepId, uint256 n) private view returns (uint256[] memory pool, uint256 seed) {
        pool = _activeHorseIndexes();
        seed = uint256(keccak256(abi.encode(block.prevrandao, block.timestamp, address(this), sweepId, n)));
        for (uint256 i = pool.length; i > 1; --i) {
            uint256 j = uint256(keccak256(abi.encode(seed, i))) % i;
            (pool[i - 1], pool[j]) = (pool[j], pool[i - 1]);
        }
    }

    // ---------------------------------------------------------------- race day admin

    /// @notice Mark a horse as scratched in every sweep. Tickets already holding it can claim a refund.
    function scratch(uint256 horse) external onlyOwner {
        if (raceSettled) revert WrongState();
        if (horse >= _horses.length || scratched[horse]) revert BadHorse();
        scratched[horse] = true;
        ++_scratchedCount;
        emit Scratched(horse);
        emit BatchMetadataUpdate(0, type(uint256).max);
    }

    /// @notice Record the official winner (horse index) for every sweep at once. In each sweep the
    ///         holder of that horse takes the pool. A sweep where nobody holds it is cancelled and
    ///         refunded. Reverts if a sweep with tickets hasn't been drawn: draw or cancel it first.
    function settle(uint256 horse) external onlyOwner {
        if (raceSettled) revert WrongState();
        if (block.timestamp < entriesClose) revert EntriesStillOpen();
        if (horse >= _horses.length || scratched[horse]) revert BadHorse();

        raceSettled = true;
        winningHorse = horse;
        uint256 sweepTotal = sweeps.length;
        for (uint256 id; id < sweepTotal; ++id) {
            Sweep storage s = sweeps[id];
            if (s.state == State.Cancelled) continue;
            if (s.state == State.Open && s.ticketCount != 0) revert WrongState();

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
        if (s.state != State.Open && s.state != State.Drawn) revert WrongState();
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
    ///         if its sweep was cancelled, its horse was scratched, or it never got a horse.
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
        if (s.state == State.Cancelled) return s.entryFee;
        if (s.state == State.Open) return 0;
        if (_isRefundable(tk)) return s.entryFee;
        if (s.state == State.Settled && s.winningTicket == ticketId) return prizePool(sweepId);
        return 0;
    }

    /// @notice A sweep's pot: its entry fees, except those owed back to scratched or horseless tickets.
    ///         Tracked per sweep because all sweeps share the contract's balance, so USDT sent
    ///         straight to the contract joins no pool and can't be recovered.
    function prizePool(uint256 sweepId) public view returns (uint256) {
        Sweep storage s = _sweep(sweepId);
        if (s.state == State.Cancelled) return 0;
        uint256 ticketTotal = s.ticketCount;
        uint256 inPlay = ticketTotal;
        if (s.state != State.Open) {
            for (uint256 i; i < ticketTotal; ++i) {
                if (_isRefundable(_tickets[_ticketId(sweepId, i)])) --inPlay;
            }
        }
        return inPlay * s.entryFee;
    }

    function _isRefundable(Ticket storage tk) private view returns (bool) {
        return tk.horse == NONE || scratched[tk.horse - 1];
    }

    // ---------------------------------------------------------------- views

    function sweepCount() external view returns (uint256) { return sweeps.length; }
    function horseCount() external view returns (uint256) { return _horses.length; }
    function horseName(uint256 horse) external view returns (string memory) { return _horses[horse]; }

    /// @return sweepId the ticket's sweep
    /// @return holder current NFT owner
    /// @return horse horse index (type(uint256).max if none)
    /// @return name horse name ("" if none)
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
        if (tk.horse == NONE) {
            horse = type(uint256).max;
        } else {
            horse = tk.horse - 1;
            name = _horses[horse];
        }
    }

    /// @notice Where a ticket stands, in words. Also shown on the NFT.
    function ticketStatus(uint256 ticketId) public view returns (string memory) {
        _requireOwned(ticketId);
        Ticket storage tk = _tickets[ticketId];
        Sweep storage s = sweeps[_sweepOf(ticketId)];
        bool won = s.state == State.Settled && s.winningTicket == ticketId;
        if (tk.claimed) return won ? "Winner - paid" : "Refunded";
        if (s.state == State.Open) return "Awaiting the draw";
        if (s.state == State.Cancelled) return "Cancelled - refund available";
        if (tk.horse == NONE) return "No horse - refund available";
        if (scratched[tk.horse - 1]) return "Scratched - refund available";
        if (won) return "Winner - prize to claim";
        return s.state == State.Settled ? "Did not win" : "In the race";
    }

    function activeHorses() public view returns (uint256) {
        return _horses.length - _scratchedCount;
    }

    function _activeHorseIndexes() private view returns (uint256[] memory idx) {
        idx = new uint256[](activeHorses());
        uint256 k;
        uint256 horseTotal = _horses.length;
        for (uint256 i; i < horseTotal; ++i) if (!scratched[i]) idx[k++] = i;
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

    function supportsInterface(bytes4 interfaceId) public view override(ERC721, IERC165) returns (bool) {
        return interfaceId == bytes4(0x49064906) || super.supportsInterface(interfaceId);
    }

    /// @notice Fully onchain metadata and image. They change as the ticket's fortunes do.
    /// @dev    Horse names come from the deployer and are assumed free of quotes and XML characters.
    function tokenURI(uint256 ticketId) public view override returns (string memory) {
        _requireOwned(ticketId);
        uint256 sweepId = _sweepOf(ticketId);
        string memory fee = string.concat("$", Strings.toString(sweeps[sweepId].entryFee / ONE_USDT));
        string memory number = Strings.toString(ticketId % ID_BASE);
        string memory status = ticketStatus(ticketId);
        (string memory horse, string memory cloth) = _horseLabels(ticketId, sweepId);

        string memory image = Base64.encode(bytes(_svg(sweepId, fee, number, horse, cloth, status)));
        return string.concat(
            "data:application/json;base64,",
            Base64.encode(bytes(string.concat(
                '{"name":"Melbourne Cup 2026 ', fee, ' Sweep #', number,
                '","description":"A ticket in the ', fee, ' Melbourne Cup 2026 sweep, paid in USDT. Hold the winning horse to take the pool.",',
                '"image":"data:image/svg+xml;base64,', image,
                '","attributes":[{"trait_type":"Sweep","value":"', fee,
                '"},{"trait_type":"Horse","value":"', horse,
                '"},{"trait_type":"Status","value":"', status, '"}]}'
            )))
        );
    }

    function _horseLabels(uint256 ticketId, uint256 sweepId) private view returns (string memory horse, string memory cloth) {
        uint16 h = _tickets[ticketId].horse;
        if (h != NONE) return (_horses[h - 1], string.concat("Saddlecloth ", Strings.toString(h)));
        return (sweeps[sweepId].state == State.Open ? "Horse to be drawn" : "No horse", "");
    }

    function _svg(
        uint256 sweepId,
        string memory fee,
        string memory number,
        string memory horse,
        string memory cloth,
        string memory status
    ) private pure returns (string memory) {
        string memory colour = sweepId == 0 ? "#cd8f55" : sweepId == 1 ? "#c3ccd6" : "#e6bd4f";
        return string.concat(
            string.concat(
                '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 400 400">',
                '<rect width="400" height="400" fill="#123326"/>',
                '<rect x="16" y="16" width="368" height="368" rx="18" fill="none" stroke-width="3" stroke="', colour, '"/>',
                '<g font-family="Georgia,serif" text-anchor="middle" fill="#f5f0e1">',
                '<text x="200" y="66" font-size="20" letter-spacing="1">Melbourne Cup 2026</text>'
            ),
            string.concat(
                '<text x="200" y="142" font-size="68" font-weight="bold" fill="', colour, '">', fee, '</text>',
                '<text x="200" y="176" font-size="16">Sweep ticket #', number, '</text>'
            ),
            string.concat(
                '<text x="200" y="250" font-size="30" font-weight="bold">', horse, '</text>',
                '<text x="200" y="280" font-size="15">', cloth, '</text>',
                '<text x="200" y="346" font-size="17" fill="', colour, '">', status, '</text></g></svg>'
            )
        );
    }
}
