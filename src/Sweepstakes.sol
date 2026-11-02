// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title Sweepstakes for horse races
/// @notice The owner creates a race (its field and entry cut-off), then any number of sweeps on
///         that race, each at its own ticket price. A sweep only runs if it sells one ticket per
///         horse. A full sweep is shuffled so every ticket gets a different horse, and the ticket
///         holding the winner takes that sweep's pool. A sweep that hasn't filled by the cut-off
///         refunds everyone.
/// @dev    The draw uses block.prevrandao, which a block proposer can bias slightly. That is fine
///         for sweeps between mates, not for large pools.
contract Sweepstakes is Ownable {
    using SafeERC20 for IERC20;

    struct Race {
        uint64 entriesClose;
        bool settled;
        bool cancelled;
        uint16 winner; // horse index, valid once settled
        uint16 scratchedCount;
        string name;
        string[] horses;
    }

    struct Ticket {
        address holder;
        uint16 horse; // horse index + 1; 0 = no horse
        bool claimed;
    }

    struct Sweep {
        uint256 raceId;
        uint256 entryFee;
        bool drawn;
        bool cancelled;
    }

    uint16 private constant NONE = 0;
    uint256 public constant SETTLE_GRACE = 7 days;

    IERC20 public immutable token;

    Race[] private _races;
    mapping(uint256 => mapping(uint256 => bool)) public scratched; // raceId => horse => scratched

    Sweep[] private _sweeps;
    mapping(uint256 => Ticket[]) private _tickets; // sweepId => tickets
    mapping(uint256 => mapping(uint256 => uint256)) public horseTicket; // sweepId => horse => ticketId + 1

    event RaceCreated(uint256 indexed raceId, string name, uint64 entriesClose, uint256 horses);
    event SweepCreated(uint256 indexed sweepId, uint256 indexed raceId, uint256 entryFee);
    event Entered(uint256 indexed sweepId, uint256 indexed ticketId, address indexed holder);
    event Drawn(uint256 indexed sweepId, uint256 seed);
    event HorseAssigned(uint256 indexed sweepId, uint256 indexed ticketId, uint256 horse, string name);
    event Scratched(uint256 indexed raceId, uint256 indexed horse);
    event RaceSettled(uint256 indexed raceId, uint256 indexed horse, string name);
    event RaceCancelled(uint256 indexed raceId);
    event SweepCancelled(uint256 indexed sweepId);
    event EntryFeeChanged(uint256 indexed sweepId, uint256 fee);
    event Claimed(uint256 indexed sweepId, uint256 indexed ticketId, address indexed to, uint256 amount);

    error BadRace();
    error BadSweep();
    error BadHorse();
    error RaceOver();
    error EntriesClosed();
    error SweepFull();
    error SweepNotFull();
    error SweepClosed();
    error FeeLocked();
    error NotYourTicket();
    error NothingToClaim();
    error TooEarly();

    constructor(IERC20 token_) Ownable(msg.sender) {
        token = token_;
    }

    // ================================================================ owner: races and sweeps

    function createRace(string calldata name, uint64 entriesClose, string[] calldata horses)
        external
        onlyOwner
        returns (uint256 raceId)
    {
        if (horses.length < 2 || horses.length >= type(uint16).max) revert BadHorse();
        if (entriesClose <= block.timestamp) revert EntriesClosed();
        raceId = _races.length;
        Race storage r = _races.push();
        r.name = name;
        r.entriesClose = entriesClose;
        for (uint256 i; i < horses.length; ++i) r.horses.push(horses[i]);
        emit RaceCreated(raceId, name, entriesClose, horses.length);
    }

    /// @notice Open a new sweep on `raceId` with its own ticket price (in token base units).
    function createSweep(uint256 raceId, uint256 entryFee) external onlyOwner returns (uint256 sweepId) {
        Race storage r = _race(raceId);
        if (r.settled || r.cancelled) revert RaceOver();
        if (block.timestamp >= r.entriesClose) revert EntriesClosed();
        sweepId = _sweeps.length;
        _sweeps.push(Sweep({raceId: raceId, entryFee: entryFee, drawn: false, cancelled: false}));
        emit SweepCreated(sweepId, raceId, entryFee);
    }

    /// @notice Change a sweep's price. Only allowed before anyone has entered it.
    function setEntryFee(uint256 sweepId, uint256 fee) external onlyOwner {
        Sweep storage s = _sweep(sweepId);
        if (_tickets[sweepId].length != 0) revert FeeLocked();
        s.entryFee = fee;
        emit EntryFeeChanged(sweepId, fee);
    }

    /// @notice Call off one sweep that hasn't been drawn yet. Everyone in it gets a refund.
    function cancelSweep(uint256 sweepId) external onlyOwner {
        Sweep storage s = _sweep(sweepId);
        if (s.drawn || s.cancelled) revert SweepClosed();
        s.cancelled = true;
        emit SweepCancelled(sweepId);
    }

    /// @notice Mark a horse as scratched. In sweeps already drawn, its ticket holder gets a refund.
    ///         In sweeps not yet drawn, one fewer ticket is needed to fill.
    function scratch(uint256 raceId, uint256 horse) external onlyOwner {
        Race storage r = _race(raceId);
        if (r.settled || r.cancelled) revert RaceOver();
        if (horse >= r.horses.length || scratched[raceId][horse]) revert BadHorse();
        if (r.horses.length - r.scratchedCount <= 2) revert BadHorse();
        scratched[raceId][horse] = true;
        ++r.scratchedCount;
        emit Scratched(raceId, horse);
    }

    /// @notice Record the official winner. Every drawn sweep on this race can then pay out.
    function settle(uint256 raceId, uint256 horse) external onlyOwner {
        Race storage r = _race(raceId);
        if (r.settled || r.cancelled) revert RaceOver();
        if (block.timestamp < r.entriesClose) revert TooEarly();
        if (horse >= r.horses.length || scratched[raceId][horse]) revert BadHorse();
        r.settled = true;
        r.winner = uint16(horse);
        emit RaceSettled(raceId, horse, r.horses[horse]);
    }

    /// @notice Call off a race and refund every sweep on it. The owner can do this any time before
    ///         settling. Anyone can do it once the owner is a week late settling.
    function cancelRace(uint256 raceId) external {
        Race storage r = _race(raceId);
        if (r.settled || r.cancelled) revert RaceOver();
        if (msg.sender != owner() && block.timestamp < uint256(r.entriesClose) + SETTLE_GRACE) revert TooEarly();
        r.cancelled = true;
        emit RaceCancelled(raceId);
    }

    // ================================================================ players

    /// @notice Buy a ticket in `sweepId`. Approve its entry fee first. You can buy several.
    function enter(uint256 sweepId) external returns (uint256 ticketId) {
        Sweep storage s = _sweep(sweepId);
        Race storage r = _races[s.raceId];
        if (s.cancelled || s.drawn || r.settled || r.cancelled) revert SweepClosed();
        if (block.timestamp >= r.entriesClose) revert EntriesClosed();
        if (_tickets[sweepId].length >= _activeCount(r)) revert SweepFull();

        token.safeTransferFrom(msg.sender, address(this), s.entryFee);
        ticketId = _tickets[sweepId].length;
        _tickets[sweepId].push(Ticket({holder: msg.sender, horse: NONE, claimed: false}));
        emit Entered(sweepId, ticketId, msg.sender);
    }

    /// @notice Shuffle the field and give each ticket a horse. Anyone can call it once the sweep is
    ///         full, any time before the race is settled. A sweep that isn't drawn by then is refunded.
    function draw(uint256 sweepId) external {
        Sweep storage s = _sweep(sweepId);
        Race storage r = _races[s.raceId];
        if (s.cancelled || s.drawn || r.settled || r.cancelled) revert SweepClosed();
        Ticket[] storage tickets = _tickets[sweepId];
        uint256 n = tickets.length;
        uint256[] memory pool = _activeHorses(s.raceId, r);
        if (n < pool.length) revert SweepNotFull();

        uint256 seed = uint256(keccak256(abi.encode(block.prevrandao, block.timestamp, address(this), sweepId)));
        for (uint256 i = pool.length; i > 1; --i) {
            uint256 j = uint256(keccak256(abi.encode(seed, i))) % i;
            (pool[i - 1], pool[j]) = (pool[j], pool[i - 1]);
        }

        // A horse scratched while the sweep was full leaves the last tickets without a horse;
        // they get refunds.
        for (uint256 t; t < pool.length; ++t) {
            uint256 h = pool[t];
            tickets[t].horse = uint16(h + 1);
            horseTicket[sweepId][h] = t + 1;
            emit HorseAssigned(sweepId, t, h, r.horses[h]);
        }
        s.drawn = true;
        emit Drawn(sweepId, seed);
    }

    /// @notice Collect what a ticket is owed: the pool if it holds the winner, or the entry fee back
    ///         if the sweep didn't run or the ticket's horse was scratched.
    function claim(uint256 sweepId, uint256 ticketId) external {
        Ticket storage tk = _tickets[sweepId][ticketId];
        if (tk.holder != msg.sender) revert NotYourTicket();
        uint256 amount = claimable(sweepId, ticketId);
        if (amount == 0) revert NothingToClaim();
        tk.claimed = true;
        token.safeTransfer(msg.sender, amount);
        emit Claimed(sweepId, ticketId, msg.sender, amount);
    }

    // ================================================================ views

    /// @notice What ticket `ticketId` in `sweepId` can claim right now.
    function claimable(uint256 sweepId, uint256 ticketId) public view returns (uint256) {
        Sweep storage s = _sweep(sweepId);
        Race storage r = _races[s.raceId];
        Ticket storage tk = _tickets[sweepId][ticketId];
        if (tk.claimed) return 0;
        if (_refundsEveryone(sweepId, s, r)) return s.entryFee;
        if (!s.drawn) return 0; // still filling
        if (!_isLive(s.raceId, tk)) return s.entryFee; // scratched or no horse
        if (r.settled && tk.horse == r.winner + 1) return prizePool(sweepId);
        return 0;
    }

    /// @notice The pot for a drawn sweep: one entry fee for every ticket whose horse is still running.
    function prizePool(uint256 sweepId) public view returns (uint256) {
        Sweep storage s = _sweep(sweepId);
        if (!s.drawn) return _tickets[sweepId].length * s.entryFee;
        Ticket[] storage tickets = _tickets[sweepId];
        uint256 live;
        for (uint256 t; t < tickets.length; ++t) if (_isLive(s.raceId, tickets[t])) ++live;
        return live * s.entryFee;
    }

    /// @notice Open, Full, Drawn, Settled or Refunding.
    function sweepStatus(uint256 sweepId) external view returns (string memory) {
        Sweep storage s = _sweep(sweepId);
        Race storage r = _races[s.raceId];
        if (_refundsEveryone(sweepId, s, r)) return "Refunding";
        if (s.drawn) return r.settled ? "Settled" : "Drawn";
        return _tickets[sweepId].length >= _activeCount(r) ? "Full" : "Open";
    }

    /// @notice Tickets still needed for `sweepId` to fill.
    function ticketsRemaining(uint256 sweepId) external view returns (uint256) {
        Sweep storage s = _sweep(sweepId);
        uint256 need = _activeCount(_races[s.raceId]);
        uint256 have = _tickets[sweepId].length;
        return have >= need ? 0 : need - have;
    }

    function raceCount() external view returns (uint256) { return _races.length; }
    function sweepCount() external view returns (uint256) { return _sweeps.length; }
    function ticketCount(uint256 sweepId) external view returns (uint256) { return _tickets[sweepId].length; }

    function race(uint256 raceId)
        external
        view
        returns (string memory name, uint64 entriesClose, uint256 horses, uint256 active, bool settled, bool cancelled, uint256 winner)
    {
        Race storage r = _race(raceId);
        return (r.name, r.entriesClose, r.horses.length, _activeCount(r), r.settled, r.cancelled, r.winner);
    }

    function horseName(uint256 raceId, uint256 horse) external view returns (string memory) {
        return _race(raceId).horses[horse];
    }

    function sweep(uint256 sweepId) external view returns (uint256 raceId, uint256 entryFee, bool drawn, bool cancelled) {
        Sweep storage s = _sweep(sweepId);
        return (s.raceId, s.entryFee, s.drawn, s.cancelled);
    }

    /// @return holder owner of the ticket
    /// @return horse  horse index, or type(uint256).max before the draw / if it got no horse
    /// @return name   horse name ("" if none)
    /// @return claimed whether the ticket has been paid out
    function ticket(uint256 sweepId, uint256 ticketId)
        external
        view
        returns (address holder, uint256 horse, string memory name, bool claimed)
    {
        Ticket storage tk = _tickets[sweepId][ticketId];
        holder = tk.holder;
        claimed = tk.claimed;
        if (tk.horse == NONE) {
            horse = type(uint256).max;
        } else {
            horse = tk.horse - 1;
            name = _races[_sweeps[sweepId].raceId].horses[horse];
        }
    }

    // ================================================================ internals

    /// A sweep refunds every ticket if it was cancelled, its race was cancelled, or it never got
    /// drawn (didn't fill) before entries closed or the race was settled.
    function _refundsEveryone(uint256 sweepId, Sweep storage s, Race storage r) private view returns (bool) {
        if (s.cancelled || r.cancelled) return true;
        if (s.drawn) return false;
        return r.settled || block.timestamp >= r.entriesClose && _tickets[sweepId].length < _activeCount(r);
    }

    function _isLive(uint256 raceId, Ticket storage tk) private view returns (bool) {
        return tk.horse != NONE && !scratched[raceId][tk.horse - 1];
    }

    function _activeCount(Race storage r) private view returns (uint256) {
        return r.horses.length - r.scratchedCount;
    }

    function _activeHorses(uint256 raceId, Race storage r) private view returns (uint256[] memory idx) {
        idx = new uint256[](_activeCount(r));
        uint256 k;
        for (uint256 i; i < r.horses.length; ++i) if (!scratched[raceId][i]) idx[k++] = i;
    }

    function _race(uint256 raceId) private view returns (Race storage) {
        if (raceId >= _races.length) revert BadRace();
        return _races[raceId];
    }

    function _sweep(uint256 sweepId) private view returns (Sweep storage) {
        if (sweepId >= _sweeps.length) revert BadSweep();
        return _sweeps[sweepId];
    }
}
