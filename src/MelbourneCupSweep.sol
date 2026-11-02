// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title Melbourne Cup sweepstake
/// @notice Pay the entry fee for a ticket. When entries close, one shuffle randomly gives every
///         ticket a different horse. The ticket holding the winner takes the whole pool.
/// @dev    Lifecycle: Open -> Drawn -> Settled (or Cancelled at any point before Settled).
///         Randomness is block.prevrandao, which a block proposer can bias slightly. That is
///         fine for a sweep between mates, not for large pools.
contract MelbourneCupSweep is Ownable {
    using SafeERC20 for IERC20;

    enum State { Open, Drawn, Settled, Cancelled }

    struct Ticket {
        address holder;
        uint16 horse;     // horse index + 1; 0 = no horse (field ran out)
        bool claimed;
    }

    uint16 private constant NONE = 0;
    uint256 public constant SETTLE_GRACE = 7 days;

    IERC20 public immutable token;
    uint64 public immutable entriesClose;

    uint256 public entryFee;
    State public state;

    string[] private _horses;
    mapping(uint256 => bool) public scratched;     // horse index => scratched
    mapping(uint256 => uint256) public horseTicket; // horse index => ticket id + 1 (0 = unowned)

    Ticket[] private _tickets;
    uint256 public winningHorse;  // horse index, valid once Settled
    uint256 public winningTicket; // ticket id + 1 (0 = nobody held the winner)

    event Entered(uint256 indexed ticketId, address indexed holder);
    event Drawn(uint256 seed);
    event HorseAssigned(uint256 indexed ticketId, uint256 indexed horse, string name);
    event Scratched(uint256 indexed horse);
    event Settled(uint256 indexed horse, uint256 indexed ticketId, address winner, uint256 prize);
    event Cancelled();
    event Claimed(uint256 indexed ticketId, address indexed to, uint256 amount);
    event EntryFeeChanged(uint256 fee);

    error WrongState();
    error EntriesClosed();
    error EntriesStillOpen();
    error SweepFull();
    error NoTickets();
    error BadHorse();
    error FeeLocked();
    error NotYourTicket();
    error NothingToClaim();
    error TooEarly();

    constructor(IERC20 token_, uint256 entryFee_, uint64 entriesClose_, string[] memory horses_) Ownable(msg.sender) {
        if (horses_.length == 0 || horses_.length > type(uint16).max - 1) revert BadHorse();
        token = token_;
        entryFee = entryFee_;
        entriesClose = entriesClose_;
        for (uint256 i; i < horses_.length; ++i) _horses.push(horses_[i]);
    }

    // ---------------------------------------------------------------- entering

    /// @notice Buy one ticket. Approve `entryFee` of the token first. You can buy several.
    function enter() external returns (uint256 ticketId) {
        if (state != State.Open) revert WrongState();
        if (block.timestamp >= entriesClose) revert EntriesClosed();
        if (_tickets.length >= activeHorses()) revert SweepFull();

        token.safeTransferFrom(msg.sender, address(this), entryFee);
        ticketId = _tickets.length;
        _tickets.push(Ticket({holder: msg.sender, horse: NONE, claimed: false}));
        emit Entered(ticketId, msg.sender);
    }

    /// @notice Change the entry fee. Only allowed before anyone has entered.
    function setEntryFee(uint256 fee) external onlyOwner {
        if (state != State.Open) revert WrongState();
        if (_tickets.length != 0) revert FeeLocked();
        entryFee = fee;
        emit EntryFeeChanged(fee);
    }

    // ---------------------------------------------------------------- the draw

    /// @notice Shuffle the field and give each ticket a horse. Anyone can call it once
    ///         entries close, or as soon as every horse has a ticket.
    function draw() external {
        if (state != State.Open) revert WrongState();
        uint256 n = _tickets.length;
        if (n == 0) revert NoTickets();
        if (block.timestamp < entriesClose && n < activeHorses()) revert EntriesStillOpen();

        // Fisher-Yates shuffle of the horses still running.
        uint256[] memory pool = _activeHorseIndexes();
        uint256 seed = uint256(keccak256(abi.encode(block.prevrandao, block.timestamp, address(this), n)));
        for (uint256 i = pool.length; i > 1; --i) {
            uint256 j = uint256(keccak256(abi.encode(seed, i))) % i;
            (pool[i - 1], pool[j]) = (pool[j], pool[i - 1]);
        }

        // If horses were scratched after people entered, the last tickets miss out and get refunds.
        uint256 assigned = n < pool.length ? n : pool.length;
        for (uint256 t; t < assigned; ++t) {
            uint256 h = pool[t];
            _tickets[t].horse = uint16(h + 1);
            horseTicket[h] = t + 1;
            emit HorseAssigned(t, h, _horses[h]);
        }

        state = State.Drawn;
        emit Drawn(seed);
    }

    // ---------------------------------------------------------------- race day admin

    /// @notice Mark a horse as scratched. If it already belongs to a ticket, that ticket is refunded.
    function scratch(uint256 horse) external onlyOwner {
        if (state != State.Open && state != State.Drawn) revert WrongState();
        if (horse >= _horses.length || scratched[horse]) revert BadHorse();
        scratched[horse] = true;
        emit Scratched(horse);
    }

    /// @notice Record the official winner (horse index). The holder of that horse takes the pool.
    ///         If nobody holds the winner, the sweep is cancelled and everyone gets their fee back.
    function settle(uint256 horse) external onlyOwner {
        if (state != State.Drawn) revert WrongState();
        if (horse >= _horses.length || scratched[horse]) revert BadHorse();

        winningHorse = horse;
        uint256 t = horseTicket[horse];
        if (t == 0) {
            _cancel();
            return;
        }
        winningTicket = t;
        state = State.Settled;
        emit Settled(horse, t - 1, _tickets[t - 1].holder, prizePool());
    }

    /// @notice Call the sweep off and refund everyone. The owner can do this at any time before
    ///         settling. Anyone can do it once the owner is a week late settling.
    function cancel() external {
        if (state != State.Open && state != State.Drawn) revert WrongState();
        if (msg.sender != owner() && block.timestamp < uint256(entriesClose) + SETTLE_GRACE) revert TooEarly();
        _cancel();
    }

    function _cancel() private {
        state = State.Cancelled;
        emit Cancelled();
    }

    // ---------------------------------------------------------------- claiming

    /// @notice Collect what a ticket is owed: the prize for the winning ticket, or the entry fee back
    ///         if the sweep was cancelled, the ticket's horse was scratched, or it never got a horse.
    function claim(uint256 ticketId) external {
        Ticket storage tk = _tickets[ticketId];
        if (tk.holder != msg.sender) revert NotYourTicket();
        uint256 amount = claimable(ticketId);
        if (amount == 0) revert NothingToClaim();
        tk.claimed = true;
        token.safeTransfer(msg.sender, amount);
        emit Claimed(ticketId, msg.sender, amount);
    }

    /// @notice Amount ticket `ticketId` can claim right now.
    function claimable(uint256 ticketId) public view returns (uint256) {
        Ticket storage tk = _tickets[ticketId];
        if (tk.claimed) return 0;
        if (state == State.Cancelled) return entryFee;
        if (state == State.Open) return 0;
        if (_isRefundable(tk)) return entryFee;
        if (state == State.Settled && winningTicket == ticketId + 1) return prizePool();
        return 0;
    }

    /// @notice The pot: every entry fee except those owed back to scratched or horseless tickets.
    function prizePool() public view returns (uint256 pool) {
        pool = token.balanceOf(address(this));
        if (state == State.Drawn || state == State.Settled) {
            for (uint256 t; t < _tickets.length; ++t) {
                Ticket storage tk = _tickets[t];
                if (!tk.claimed && _isRefundable(tk)) pool -= entryFee;
            }
            if (state == State.Settled && _tickets[winningTicket - 1].claimed) pool = 0;
        }
    }

    function _isRefundable(Ticket storage tk) private view returns (bool) {
        return tk.horse == NONE || scratched[tk.horse - 1];
    }

    // ---------------------------------------------------------------- views

    function horseCount() external view returns (uint256) { return _horses.length; }
    function horseName(uint256 horse) external view returns (string memory) { return _horses[horse]; }
    function ticketCount() external view returns (uint256) { return _tickets.length; }

    /// @return holder ticket owner, horse horse index (type(uint256).max if none), name horse name ("" if none)
    function ticket(uint256 ticketId) external view returns (address holder, uint256 horse, string memory name, bool claimed) {
        Ticket storage tk = _tickets[ticketId];
        holder = tk.holder;
        claimed = tk.claimed;
        if (tk.horse == NONE) {
            horse = type(uint256).max;
        } else {
            horse = tk.horse - 1;
            name = _horses[horse];
        }
    }

    function activeHorses() public view returns (uint256 count) {
        for (uint256 i; i < _horses.length; ++i) if (!scratched[i]) ++count;
    }

    function _activeHorseIndexes() private view returns (uint256[] memory idx) {
        idx = new uint256[](activeHorses());
        uint256 k;
        for (uint256 i; i < _horses.length; ++i) if (!scratched[i]) idx[k++] = i;
    }
}
