// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, Vm} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC4906} from "@openzeppelin/contracts/interfaces/IERC4906.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {MelbourneCupSweep} from "../src/MelbourneCupSweep.sol";
import {HorseArt} from "../src/HorseArt.sol";
import {Deploy} from "../script/Deploy.s.sol";

/// @dev Mimics mainnet USDT: 6 decimals and transfer/transferFrom/approve return nothing.
contract MockUSDT {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    mapping(address => bool) public blocked; // USDT can blacklist addresses
    uint8 public constant decimals = 6;
    string public constant symbol = "USDT";

    function mint(address to, uint256 amt) external { balanceOf[to] += amt; }
    function approve(address s, uint256 amt) external { allowance[msg.sender][s] = amt; }
    function setBlocked(address who, bool isBlocked) external { blocked[who] = isBlocked; }
    function transfer(address to, uint256 amt) external {
        require(!blocked[to], "blocked");
        balanceOf[msg.sender] -= amt; balanceOf[to] += amt;
    }
    function transferFrom(address f, address to, uint256 amt) external {
        allowance[f][msg.sender] -= amt; balanceOf[f] -= amt; balanceOf[to] += amt;
    }
}

/// @dev A different kind of stablecoin: 18 decimals, and transfers return true.
contract MockDAI {
    uint8 public constant decimals = 18;
    string public constant symbol = "DAI";

    function transfer(address, uint256) external pure returns (bool) { return true; }
    function transferFrom(address, address, uint256) external pure returns (bool) { return true; }
}

/// @dev The attack that wallets-only entry closes: buy, then revert unless you got the horse you want.
contract Grinder {
    function grind(MelbourneCupSweep s, uint256 sweepId, uint256 want) external {
        uint256 ticketId = s.enter(sweepId);
        (,, uint256 horse,,) = s.ticket(ticketId);
        require(horse == want, "not my horse");
    }
}

contract MelbourneCupSweepTest is Test {
    uint256 constant ONE = 0; // sweep ids
    uint256 constant TWO = 1;
    uint256 constant TEN = 2;

    MockUSDT usdt;
    MelbourneCupSweep sweep;
    uint64 close;
    uint64 results;

    function setUp() public {
        usdt = new MockUSDT();
        close = uint64(block.timestamp + 1 days);
        results = close + 30 minutes;
        sweep = _deploy(_fourHorses());
    }

    function _deploy(string[] memory horses) internal returns (MelbourneCupSweep) {
        return new MelbourneCupSweep(IERC20(address(usdt)), new Deploy().entryFees(6), close, results, horses);
    }

    function _fourHorses() internal pure returns (string[] memory h) {
        h = new string[](4);
        h[0] = "Middle Earth"; h[1] = "Vauban"; h[2] = "Knight's Choice"; h[3] = "Zakouma";
    }

    function _fee(uint256 id) internal view returns (uint256 fee) { (fee,,,) = sweep.sweeps(id); }
    function _state(uint256 id) internal view returns (MelbourneCupSweep.State st) { (, st,,) = sweep.sweeps(id); }
    function _horseOf(uint256 ticketId) internal view returns (uint256 h) { (,, h,,) = sweep.ticket(ticketId); }

    function _enter(address who, uint256 id) internal returns (uint256 ticketId) {
        uint256 fee = _fee(id);
        usdt.mint(who, fee);
        vm.startPrank(who, who);
        usdt.approve(address(sweep), fee);
        ticketId = sweep.enter(id);
        vm.stopPrank();
    }

    /// @dev Each sweep gets its own set of wallets, so balances are easy to check.
    function _fill(uint256 id, uint256 n) internal {
        for (uint256 i; i < n; ++i) _enter(address(uint160((id + 1) * 100 + i)), id);
    }

    /// @dev Warping is a cheatcode, so this still works straight after vm.expectRevert or vm.expectEmit.
    function _settle(uint256 horse) internal {
        vm.warp(results);
        sweep.settle(horse);
    }

    function _claim(uint256 ticketId) internal {
        vm.prank(sweep.ownerOf(ticketId));
        sweep.claim(ticketId);
    }

    function _balanceOfHolder(uint256 ticketId) internal view returns (uint256) {
        return usdt.balanceOf(sweep.ownerOf(ticketId));
    }

    // ---------------------------------------------------------------- picking a sweep

    function test_threeSweeps_chargeTheirOwnFee() public {
        assertEq(sweep.sweepCount(), 3);
        address buyer = address(0xA);
        assertEq(_enter(buyer, ONE), 1001);
        assertEq(usdt.balanceOf(address(sweep)), 1e6);
        assertEq(_enter(buyer, TWO), 2001);
        assertEq(usdt.balanceOf(address(sweep)), 3e6);
        assertEq(_enter(buyer, TEN), 3001);
        assertEq(usdt.balanceOf(address(sweep)), 13e6);

        assertEq(usdt.balanceOf(buyer), 0);
        assertEq(sweep.prizePool(ONE), 1e6);
        assertEq(sweep.prizePool(TWO), 2e6);
        assertEq(sweep.prizePool(TEN), 10e6);
    }

    function test_anyStablecoinWorks_whateverItsDecimals() public {
        MockDAI dai = new MockDAI();
        uint256[] memory fees = new Deploy().entryFees(18);
        assertEq(fees[2], 10e18);

        sweep = new MelbourneCupSweep(IERC20(address(dai)), fees, close, results, _fourHorses());
        assertEq(address(sweep.token()), address(dai));
        vm.prank(address(0xA), address(0xA));
        assertEq(sweep.enter(TEN), 3001);
        assertEq(sweep.prizePool(TEN), 10e18);

        string memory json = _json(3001);
        assertEq(vm.parseJsonString(json, ".name"), "Melbourne Cup 2026 $10 Sweep #1");
        assertEq(vm.parseJsonString(json, ".attributes[0].value"), "$10");
        assertTrue(_contains(vm.parseJsonString(json, ".description"), "paid in DAI"));
    }

    /// @dev Mainnet USDT's address has no code on Base, for example, so this stops a wrong-chain deploy.
    function test_constructor_rejectsAddressWithNoToken() public {
        uint256[] memory fees = new Deploy().entryFees(6);
        string[] memory horses = _fourHorses();
        vm.expectRevert();
        new MelbourneCupSweep(IERC20(address(0xDEAD)), fees, close, results, horses);
    }

    function test_enter_rejectsUnknownSweep() public {
        vm.expectRevert(MelbourneCupSweep.BadSweep.selector);
        sweep.enter(3);
    }

    function test_constructor_rejectsBadFees() public {
        uint256[] memory none = new uint256[](0);
        vm.expectRevert(MelbourneCupSweep.BadSweep.selector);
        new MelbourneCupSweep(IERC20(address(usdt)), none, close, results, _fourHorses());

        uint256[] memory zero = new uint256[](1);
        vm.expectRevert(MelbourneCupSweep.BadFee.selector);
        new MelbourneCupSweep(IERC20(address(usdt)), zero, close, results, _fourHorses());
    }

    function test_sweepsFillIndependently() public {
        _fill(ONE, 4);
        usdt.mint(address(5), 1e6);
        vm.startPrank(address(5), address(5));
        usdt.approve(address(sweep), 1e6);
        vm.expectRevert(MelbourneCupSweep.SweepFull.selector);
        sweep.enter(ONE);
        vm.stopPrank();
        assertEq(_enter(address(5), TWO), 2001);
    }

    function test_oneWalletCanBuySeveral() public {
        address buyer = address(0xA);
        _enter(buyer, TEN); _enter(buyer, TEN); _enter(buyer, ONE);
        assertEq(sweep.balanceOf(buyer), 3);
        assertEq(sweep.ownerOf(3002), buyer);
    }

    function test_cannotEnterAfterClose() public {
        vm.warp(close);
        usdt.mint(address(0xA), 1e6);
        vm.startPrank(address(0xA), address(0xA));
        usdt.approve(address(sweep), 1e6);
        vm.expectRevert(MelbourneCupSweep.EntriesClosed.selector);
        sweep.enter(ONE);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- settling

    function test_oneRaceResult_paysEachSweepItsOwnPool() public {
        _fill(ONE, 4); _fill(TWO, 4); _fill(TEN, 4);
        assertEq(usdt.balanceOf(address(sweep)), 52e6);
        _settle(1);
        assertTrue(sweep.raceSettled());
        assertEq(sweep.winningHorse(), 1);

        uint256[3] memory pools = [uint256(4e6), 8e6, 40e6];
        for (uint256 id; id < 3; ++id) {
            uint256 winner = sweep.horseTicket(id, 1);
            assertEq(uint256(_state(id)), uint256(MelbourneCupSweep.State.Settled));
            assertEq(sweep.claimable(winner), pools[id]);
            _claim(winner);
            assertEq(_balanceOfHolder(winner), pools[id]);
            assertEq(sweep.claimable(winner), 0);
        }
        assertEq(usdt.balanceOf(address(sweep)), 0);
    }

    function test_losingTicketsGetNothing() public {
        _fill(TEN, 4);
        _settle(0);
        uint256 winner = sweep.horseTicket(TEN, 0);
        for (uint256 t = 3001; t <= 3004; ++t) {
            if (t == winner) continue;
            assertEq(sweep.claimable(t), 0);
            vm.prank(sweep.ownerOf(t));
            vm.expectRevert(MelbourneCupSweep.NothingToClaim.selector);
            sweep.claim(t);
        }
    }

    function test_nobodyHoldsWinner_refundsOnlyThatSweep() public {
        _fill(ONE, 1); _fill(TEN, 4);

        uint256 unowned;
        for (uint256 h; h < 4; ++h) if (sweep.horseTicket(ONE, h) == 0) { unowned = h; break; }
        _settle(unowned);

        assertEq(uint256(_state(ONE)), uint256(MelbourneCupSweep.State.Cancelled));
        assertEq(uint256(_state(TWO)), uint256(MelbourneCupSweep.State.Cancelled)); // empty
        assertEq(uint256(_state(TEN)), uint256(MelbourneCupSweep.State.Settled));

        _claim(1001);
        assertEq(_balanceOfHolder(1001), 1e6);
        uint256 winner = sweep.horseTicket(TEN, unowned);
        _claim(winner);
        assertEq(_balanceOfHolder(winner), 40e6);
        assertEq(usdt.balanceOf(address(sweep)), 0);
    }

    /// @dev The test field has few enough horses to hide a bad bounds check, so use the real one.
    function test_everyHorseInTheFieldCanWin() public {
        sweep = _deploy(new Deploy().field());
        _fill(TEN, 1);
        for (uint256 h; h < 24; ++h) {
            uint256 snapshot = vm.snapshotState();
            _settle(h);
            assertEq(sweep.winningHorse(), h);
            vm.revertToState(snapshot);
        }
        vm.expectRevert(MelbourneCupSweep.BadHorse.selector);
        _settle(24);
    }

    function test_settle_onlyOnce() public {
        _fill(ONE, 4);
        _settle(0);
        vm.expectRevert(MelbourneCupSweep.WrongState.selector);
        _settle(1);
        assertEq(sweep.winningHorse(), 0);
    }

    function test_settle_notBeforeResultsOpen() public {
        _fill(ONE, 4);
        vm.expectRevert(MelbourneCupSweep.TooEarly.selector);
        sweep.settle(0); // before entries close

        vm.warp(results - 1);
        vm.expectRevert(MelbourneCupSweep.TooEarly.selector);
        sweep.settle(0); // entries closed, but one second short

        vm.warp(results);
        sweep.settle(0);
        assertTrue(sweep.raceSettled());
    }

    function test_constructor_rejectsResultsBeforeClose() public {
        uint256[] memory fees = new Deploy().entryFees(6);
        vm.expectRevert(MelbourneCupSweep.BadTimes.selector);
        new MelbourneCupSweep(IERC20(address(usdt)), fees, close, close - 1, _fourHorses());
    }

    /// @dev The real times: entries close, then the 3:00pm AEDT race (1793678400), then results open.
    function test_deployScript_usesTheRaceDayTimes() public {
        vm.setEnv("TOKEN", vm.toString(address(usdt)));
        MelbourneCupSweep deployed = new Deploy().run();
        assertEq(address(deployed.token()), address(usdt));
        (uint256 tenDollars,,,) = deployed.sweeps(TEN);
        assertEq(tenDollars, 10e6);
        assertEq(deployed.entriesClose(), 1793677800); // 2:50pm AEDT
        assertEq(deployed.resultsOpen(), 1793679600); // 3:20pm AEDT
        assertLt(deployed.entriesClose(), 1793678400);
        assertGt(deployed.resultsOpen(), 1793678400);
    }

    function test_onlyOwnerSettlesAndScratches() public {
        _fill(ONE, 1);
        vm.startPrank(address(0xBAD));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(0xBAD)));
        _settle(0);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(0xBAD)));
        sweep.scratch(0);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- the hat

    function test_buyingPullsAHorseStraightAway() public {
        assertEq(sweep.availableHorses(TEN), 4);
        uint256 t = _enter(address(0xA), TEN);
        uint256 horse = _horseOf(t);
        assertLt(horse, 4);
        assertEq(sweep.horseTicket(TEN, horse), t);
        assertEq(sweep.ticketStatus(t), "In the race");
        assertEq(sweep.availableHorses(TEN), 3);
        assertEq(sweep.availableHorses(ONE), 4);
    }

    function test_buyingAnnouncesTheHorse() public {
        usdt.mint(address(0xA), 10e6);
        vm.startPrank(address(0xA), address(0xA));
        usdt.approve(address(sweep), 10e6);
        vm.recordLogs();
        uint256 t = sweep.enter(TEN);
        vm.stopPrank();
        (,, uint256 horse, string memory name,) = sweep.ticket(t);
        bytes32 topic = keccak256("HorseAssigned(uint256,uint256,string)");
        bool seen;
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] != topic) continue;
            seen = true;
            assertEq(uint256(logs[i].topics[1]), t);
            assertEq(uint256(logs[i].topics[2]), horse);
            assertEq(abi.decode(logs[i].data, (string)), name);
        }
        assertTrue(seen);
    }

    function test_theWholeFieldComesOutOnce_thenTheSweepIsFull() public {
        sweep = _deploy(new Deploy().field());
        _fill(TEN, 24);
        bool[24] memory seen;
        for (uint256 t = 3001; t <= 3024; ++t) {
            uint256 h = _horseOf(t);
            assertFalse(seen[h]);
            seen[h] = true;
            assertEq(sweep.horseTicket(TEN, h), t);
        }
        assertEq(sweep.availableHorses(TEN), 0);
        usdt.mint(address(5), 10e6);
        vm.startPrank(address(5), address(5));
        usdt.approve(address(sweep), 10e6);
        vm.expectRevert(MelbourneCupSweep.SweepFull.selector);
        sweep.enter(TEN);
        vm.stopPrank();
    }

    function test_eachSweepHasItsOwnHat() public {
        sweep = _deploy(new Deploy().field());
        _fill(ONE, 24); _fill(TEN, 24);
        bool differ;
        for (uint256 i = 1; i <= 24; ++i) {
            if (_horseOf(1000 + i) != _horseOf(3000 + i)) differ = true;
        }
        assertTrue(differ);
    }

    function test_contractsCantBuyAndRevertUntilTheyGetAFavourite() public {
        Grinder g = new Grinder();
        usdt.mint(address(g), 10e6);
        vm.expectRevert(MelbourneCupSweep.WalletsOnly.selector);
        g.grind(sweep, TEN, 0);
        assertEq(sweep.availableHorses(TEN), 4);
    }

    function testFuzz_hatNeverRepeatsAHorse(bytes32 rand, uint8 entrants, uint8 id) public {
        uint256 sweepId = bound(id, 0, 2);
        uint256 n = bound(entrants, 1, 4);
        vm.prevrandao(rand);
        _fill(sweepId, n);
        bool[4] memory seen;
        for (uint256 i = 1; i <= n; ++i) {
            uint256 h = _horseOf((sweepId + 1) * 1000 + i);
            assertFalse(seen[h]);
            seen[h] = true;
        }
        assertEq(sweep.availableHorses(sweepId), 4 - n);
    }

    function testFuzz_aScratchedHorseNeverComesOut(bytes32 rand, uint8 horse) public {
        uint256 gone = bound(horse, 0, 3);
        sweep.scratch(gone);
        vm.prevrandao(rand);
        assertEq(sweep.availableHorses(TEN), 3);
        _fill(TEN, 3);
        assertEq(sweep.horseTicket(TEN, gone), 0);
        assertEq(sweep.availableHorses(TEN), 0);

        usdt.mint(address(5), 10e6);
        vm.startPrank(address(5), address(5));
        usdt.approve(address(sweep), 10e6);
        vm.expectRevert(MelbourneCupSweep.SweepFull.selector);
        sweep.enter(TEN);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- scratchings and refunds

    function test_scratch_sendsTheMoneyBackInEverySweep() public {
        _fill(ONE, 4); _fill(TEN, 4);

        sweep.scratch(1);
        uint256 r1 = sweep.horseTicket(ONE, 1);
        uint256 r10 = sweep.horseTicket(TEN, 1);
        assertEq(_balanceOfHolder(r1), 1e6);
        assertEq(_balanceOfHolder(r10), 10e6);
        assertEq(sweep.claimable(r1), 0);
        assertEq(sweep.ticketStatus(r1), "Refunded");
        assertEq(sweep.prizePool(ONE), 3e6);
        assertEq(sweep.prizePool(TEN), 30e6);

        vm.prank(sweep.ownerOf(r1));
        vm.expectRevert(MelbourneCupSweep.NothingToClaim.selector);
        sweep.claim(r1); // no double refund

        _settle(0);
        uint256 w1 = sweep.horseTicket(ONE, 0);
        uint256 w10 = sweep.horseTicket(TEN, 0);
        _claim(w1); _claim(w10);
        assertEq(_balanceOfHolder(w1), 3e6);
        assertEq(_balanceOfHolder(w10), 30e6);
        assertEq(usdt.balanceOf(address(sweep)), 0);
    }

    function test_scratch_blockedHolderCantStopIt_andCanClaimLater() public {
        _fill(ONE, 4); _fill(TEN, 4);
        uint256 stuck = sweep.horseTicket(TEN, 1);
        uint256 fine = sweep.horseTicket(ONE, 1);
        address holder = sweep.ownerOf(stuck);
        usdt.setBlocked(holder, true);

        sweep.scratch(1);
        assertTrue(sweep.scratched(1));
        assertEq(_balanceOfHolder(fine), 1e6); // the other sweep's holder is still paid
        assertEq(usdt.balanceOf(holder), 0);
        assertEq(sweep.claimable(stuck), 10e6);
        assertEq(sweep.ticketStatus(stuck), "Scratched - refund available");
        assertEq(sweep.prizePool(TEN), 30e6);

        usdt.setBlocked(holder, false);
        _claim(stuck);
        assertEq(usdt.balanceOf(holder), 10e6);
        assertEq(sweep.claimable(stuck), 0);
    }

    function test_scratch_paysWhoeverHoldsTheNFTNow() public {
        _fill(TEN, 4);
        uint256 t = sweep.horseTicket(TEN, 0);
        address seller = sweep.ownerOf(t);
        address buyer = address(0xB0B);
        vm.prank(seller);
        sweep.transferFrom(seller, buyer, t);
        sweep.scratch(0);
        assertEq(usdt.balanceOf(buyer), 10e6);
        assertEq(usdt.balanceOf(seller), 0);
    }

    function test_scratch_inACancelledSweep_paysOnlyOnce() public {
        _fill(TEN, 2);
        uint256 t = 3001;
        uint256 h = _horseOf(t);
        sweep.cancel(TEN);
        _claim(t);
        assertEq(_balanceOfHolder(t), 10e6);
        sweep.scratch(h);
        assertEq(_balanceOfHolder(t), 10e6);

        uint256 other = _horseOf(3002);
        sweep.scratch(other);
        assertEq(_balanceOfHolder(3002), 10e6);
        assertEq(usdt.balanceOf(address(sweep)), 0);
    }

    function test_scratch_ofAHorseNobodyHolds_paysNobody() public {
        _fill(TEN, 1);
        uint256 free = _horseOf(3001) == 0 ? 1 : 0;
        sweep.scratch(free);
        assertEq(usdt.balanceOf(address(sweep)), 10e6);
        assertEq(sweep.prizePool(TEN), 10e6);
    }

    function test_twoScratchings_thenTheWinnerTakesWhatsLeft() public {
        _fill(TEN, 4);
        sweep.scratch(1); sweep.scratch(2);
        uint256 r1 = sweep.horseTicket(TEN, 1);
        assertEq(_balanceOfHolder(r1), 10e6);
        _settle(0);

        uint256 winner = sweep.horseTicket(TEN, 0);
        _claim(winner);
        assertEq(_balanceOfHolder(winner), 20e6);
        assertEq(usdt.balanceOf(address(sweep)), 0);
    }

    /// @dev A refunded ticket's horse is gone, but the rest of the hat can still sell.
    function test_scratchHoldingTicket_leavesTheRestOfTheHatForSale() public {
        _fill(TEN, 3);
        uint256 h = _horseOf(3001);
        sweep.scratch(h);
        assertEq(sweep.availableHorses(TEN), 1);
        uint256 t = _enter(address(0xA), TEN);
        assertTrue(_horseOf(t) != h);
        assertEq(sweep.availableHorses(TEN), 0);
        assertEq(sweep.prizePool(TEN), 30e6);
    }

    function test_activeHorses_countsEachScratchOnce() public {
        assertEq(sweep.activeHorses(), 4);
        sweep.scratch(2);
        assertEq(sweep.activeHorses(), 3);
        vm.expectRevert(MelbourneCupSweep.BadHorse.selector);
        sweep.scratch(2);
        assertEq(sweep.activeHorses(), 3);
        sweep.scratch(0); sweep.scratch(1); sweep.scratch(3);
        assertEq(sweep.activeHorses(), 0);
    }

    function test_cancelAfterRefund_everyoneWhole() public {
        _fill(TEN, 4);
        sweep.scratch(0);
        uint256 refunded = sweep.horseTicket(TEN, 0);
        sweep.cancel(TEN);
        assertEq(sweep.claimable(refunded), 0);
        for (uint256 t = 3001; t <= 3004; ++t) if (t != refunded) _claim(t);
        assertEq(usdt.balanceOf(address(sweep)), 0);
    }

    function test_scratchGuards() public {
        _fill(TEN, 4);
        sweep.scratch(0);
        uint256 refunded = sweep.horseTicket(TEN, 0);
        uint256 other = sweep.horseTicket(TEN, 1);
        address holder = sweep.ownerOf(refunded);
        address stranger = sweep.ownerOf(other);

        vm.expectRevert(MelbourneCupSweep.BadHorse.selector);
        sweep.scratch(0); // already scratched
        vm.expectRevert(MelbourneCupSweep.BadHorse.selector);
        sweep.scratch(4); // no such horse

        vm.prank(stranger);
        vm.expectRevert(MelbourneCupSweep.NotYourTicket.selector);
        sweep.claim(refunded);

        vm.prank(holder);
        vm.expectRevert(MelbourneCupSweep.NothingToClaim.selector);
        sweep.claim(refunded); // already refunded

        vm.expectRevert(MelbourneCupSweep.BadHorse.selector);
        _settle(0); // a scratched horse can't win

        _settle(1);
        vm.expectRevert(MelbourneCupSweep.WrongState.selector);
        sweep.scratch(2); // nothing after settling
    }

    /// @dev Whatever happens, what tickets can claim equals what the contract holds, and paying
    ///      them all empties it. The sweeps share one balance, so a slip here takes another's money.
    function testFuzz_moneyAlwaysAddsUp(bytes32 rand, uint8 a, uint8 b, uint8 c, uint8 scratches, uint8 winner) public {
        uint256[3] memory n = [bound(a, 0, 4), bound(b, 0, 4), bound(c, 0, 4)];
        vm.prevrandao(rand);

        for (uint256 h; h < 4; ++h) if (uint256(scratches) >> h & 1 == 1) sweep.scratch(h); // before anyone buys
        for (uint256 id; id < 3; ++id) {
            uint256 left = sweep.availableHorses(id);
            if (n[id] > left) n[id] = left;
            _fill(id, n[id]);
        }
        for (uint256 h; h < 4; ++h) {
            if (uint256(scratches) >> (h + 4) & 1 == 1 && !sweep.scratched(h)) sweep.scratch(h); // after they do
        }

        uint256 running;
        for (uint256 h; h < 4; ++h) if (!sweep.scratched(h)) ++running;
        assertEq(sweep.activeHorses(), running);

        // Settle on the first horse still running, if any are.
        for (uint256 i; i < 4; ++i) {
            uint256 h = (uint256(winner) + i) % 4;
            if (!sweep.scratched(h)) { _settle(h); break; }
        }

        uint256 owed;
        for (uint256 id; id < 3; ++id) {
            for (uint256 i = 1; i <= n[id]; ++i) owed += sweep.claimable((id + 1) * 1000 + i);
        }
        assertEq(owed, usdt.balanceOf(address(sweep)));

        for (uint256 id; id < 3; ++id) {
            for (uint256 i = 1; i <= n[id]; ++i) {
                uint256 t = (id + 1) * 1000 + i;
                if (sweep.claimable(t) != 0) _claim(t);
            }
        }
        assertEq(usdt.balanceOf(address(sweep)), 0);
    }

    // ---------------------------------------------------------------- cancelling

    function test_ownerCancelsOneSweepOnly() public {
        _fill(ONE, 1); _fill(TEN, 1);
        sweep.cancel(ONE);
        assertEq(uint256(_state(ONE)), uint256(MelbourneCupSweep.State.Cancelled));
        assertEq(uint256(_state(TEN)), uint256(MelbourneCupSweep.State.Open));
        assertEq(sweep.claimable(1001), 1e6);
        assertEq(sweep.claimable(3001), 0);
    }

    function test_anyoneCanCancel_ifOwnerLate() public {
        _fill(TEN, 1);
        address holder = sweep.ownerOf(3001);

        vm.prank(holder);
        vm.expectRevert(MelbourneCupSweep.TooEarly.selector);
        sweep.cancel(TEN);

        vm.warp(uint256(close) + 7 days);
        vm.prank(holder);
        sweep.cancel(TEN);
        _claim(3001);
        assertEq(usdt.balanceOf(holder), 10e6);
    }

    // ---------------------------------------------------------------- the NFT

    function test_isAnERC721WithMetadataUpdates() public view {
        assertEq(sweep.name(), "Melbourne Cup Sweep 2026");
        assertEq(sweep.symbol(), "CUP26");
        assertTrue(sweep.supportsInterface(0x80ac58cd)); // ERC-721
        assertTrue(sweep.supportsInterface(0x5b5e139f)); // ERC-721 metadata
        assertTrue(sweep.supportsInterface(0x49064906)); // ERC-4906
        assertFalse(sweep.supportsInterface(0xffffffff));
    }

    /// @dev Wallets and marketplaces find NFTs through this event, so a ticket has to emit it on mint.
    function test_ticketsAreRealNFTs_mintEventBalanceAndTransfers() public {
        address buyer = address(0xA);
        address friend = address(0xB);
        usdt.mint(buyer, 10e6);
        vm.startPrank(buyer, buyer);
        usdt.approve(address(sweep), 10e6);
        vm.expectEmit();
        emit IERC721.Transfer(address(0), buyer, 3001);
        sweep.enter(TEN);
        assertEq(sweep.ownerOf(3001), buyer);
        assertEq(sweep.balanceOf(buyer), 1);

        sweep.safeTransferFrom(buyer, friend, 3001);
        vm.stopPrank();
        assertEq(sweep.ownerOf(3001), friend);
        assertEq(sweep.balanceOf(buyer), 0);

        vm.prank(friend);
        sweep.approve(buyer, 3001);
        vm.prank(buyer);
        sweep.transferFrom(friend, buyer, 3001);
        assertEq(sweep.ownerOf(3001), buyer);
    }

    function test_art_isStoredOnchain_andEveryRunnerLooksDifferent() public {
        string[] memory field = new Deploy().field();
        sweep = _deploy(field);
        for (uint256 h; h < field.length; ++h) {
            string memory svg = _decode(sweep.horseImage(h), bytes("data:image/svg+xml;base64,").length);
            assertTrue(_contains(svg, "<rect "));
            assertTrue(_contains(svg, 'viewBox="0 0 24 24"'));
            for (uint256 other; other < h; ++other) {
                assertNotEq(
                    string.concat(HorseArt.coatName(field[h]), HorseArt.silksName(field[h])),
                    string.concat(HorseArt.coatName(field[other]), HorseArt.silksName(field[other]))
                );
            }
        }
        vm.expectRevert(MelbourneCupSweep.BadHorse.selector);
        sweep.horseImage(24);
    }

    function test_art_sameHorseLooksTheSameInEverySweep() public {
        _fill(ONE, 4); _fill(TEN, 4);
        string memory one = _json(sweep.horseTicket(ONE, 2));
        string memory ten = _json(sweep.horseTicket(TEN, 2));
        assertEq(vm.parseJsonString(one, ".attributes[3].trait_type"), "Coat");
        assertEq(vm.parseJsonString(one, ".attributes[4].trait_type"), "Silks");
        assertEq(vm.parseJsonString(one, ".attributes[3].value"), vm.parseJsonString(ten, ".attributes[3].value"));
        assertEq(vm.parseJsonString(one, ".attributes[4].value"), vm.parseJsonString(ten, ".attributes[4].value"));
    }

    function test_art_showsTheHorseStraightAway_andFadesIfScratched() public {
        _fill(TEN, 4);
        string memory svg = _decode(vm.parseJsonString(_json(3001), ".image"), bytes("data:image/svg+xml;base64,").length);
        (,,, string memory name,) = sweep.ticket(3001);
        assertTrue(_contains(svg, name));
        assertTrue(_contains(svg, "$10"));
        assertTrue(_contains(svg, "#3001"));
        assertFalse(_contains(svg, "Melbourne Cup"));
        assertFalse(_contains(svg, "Saddlecloth"));
        assertFalse(_contains(svg, "In the race"));
        assertFalse(_contains(svg, "NFT ticket"));
        assertTrue(_contains(svg, "<rect x="));
        assertFalse(_contains(svg, 'opacity=".35"'));

        (,, uint256 horse,,) = sweep.ticket(3001);
        sweep.scratch(horse);
        string memory faded = _decode(vm.parseJsonString(_json(3001), ".image"), bytes("data:image/svg+xml;base64,").length);
        assertTrue(_contains(faded, 'opacity=".35"'));
    }

    /// @dev Public RPCs cap the gas of a read, so the art has to stay well under the usual limits.
    function test_art_tokenURI_isCheapEnoughForPublicRPCs() public {
        sweep = _deploy(new Deploy().field());
        _fill(TEN, 24);
        uint256 before = gasleft();
        string memory uri = sweep.tokenURI(3001);
        uint256 used = before - gasleft();
        emit log_named_uint("tokenURI gas", used);
        emit log_named_uint("tokenURI bytes", bytes(uri).length);
        assertLt(used, 10_000_000);
    }

    function test_soldTicket_newHolderClaimsPrize() public {
        _fill(TEN, 4);
        _settle(0);
        uint256 winner = sweep.horseTicket(TEN, 0);
        address seller = sweep.ownerOf(winner);
        address buyer = address(0xB0B);
        vm.prank(seller);
        sweep.transferFrom(seller, buyer, winner);

        vm.prank(seller);
        vm.expectRevert(MelbourneCupSweep.NotYourTicket.selector);
        sweep.claim(winner);

        vm.prank(buyer);
        sweep.claim(winner);
        assertEq(usdt.balanceOf(buyer), 40e6);
        assertEq(usdt.balanceOf(seller), 0);
    }

    function test_nftStaysAfterClaim() public {
        _fill(TEN, 1);
        address holder = sweep.ownerOf(3001);
        sweep.cancel(TEN);
        _claim(3001);
        assertEq(sweep.ownerOf(3001), holder);
    }

    function test_unknownTicketsRevert() public {
        bytes memory err = abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, uint256(1001));
        vm.expectRevert(err);
        sweep.claim(1001);
        vm.expectRevert(err);
        sweep.claimable(1001);
        vm.expectRevert(err);
        sweep.tokenURI(1001);
        vm.expectRevert(err);
        sweep.ticket(1001);
    }

    function test_cannotClaimSomeoneElsesTicket() public {
        _fill(TEN, 1);
        sweep.cancel(TEN);
        vm.prank(address(0xB));
        vm.expectRevert(MelbourneCupSweep.NotYourTicket.selector);
        sweep.claim(3001);
    }

    function test_metadataRefreshIsSignalled() public {
        _fill(TEN, 4);
        vm.expectEmit();
        emit IERC4906.BatchMetadataUpdate(0, type(uint256).max);
        sweep.scratch(0);

        vm.expectEmit();
        emit IERC4906.BatchMetadataUpdate(0, type(uint256).max);
        _settle(1);

        uint256 winner = sweep.horseTicket(TEN, 1);
        address holder = sweep.ownerOf(winner);
        vm.expectEmit();
        emit IERC4906.MetadataUpdate(winner);
        vm.prank(holder);
        sweep.claim(winner);
    }

    function test_statusFollowsTheTicket() public {
        _fill(TEN, 4);
        assertEq(sweep.ticketStatus(3001), "In the race");

        sweep.scratch(0);
        uint256 scratchedTicket = sweep.horseTicket(TEN, 0);
        assertEq(sweep.ticketStatus(scratchedTicket), "Refunded");

        _settle(1);
        uint256 winner = sweep.horseTicket(TEN, 1);
        uint256 loser = sweep.horseTicket(TEN, 2);
        assertEq(sweep.ticketStatus(winner), "Winner - prize to claim");
        assertEq(sweep.ticketStatus(loser), "Did not win");
        _claim(winner);
        assertEq(sweep.ticketStatus(winner), "Winner - paid");
    }

    function test_statusForCancelled() public {
        _fill(ONE, 1);
        sweep.cancel(ONE);
        assertEq(sweep.ticketStatus(1001), "Cancelled - refund available");
    }

    function test_tokenURI_showsHorseAndStatus_forEveryHorse() public {
        _fill(TEN, 4); // the field includes an apostrophe, in Knight's Choice
        for (uint256 t = 3001; t <= 3004; ++t) {
            string memory json = _json(t);
            (,,, string memory horse,) = sweep.ticket(t);
            assertEq(vm.parseJsonString(json, ".attributes[0].value"), "$10");
            assertEq(vm.parseJsonString(json, ".attributes[1].value"), horse);
            assertEq(vm.parseJsonString(json, ".attributes[2].value"), "In the race");

            string memory svg = _decode(vm.parseJsonString(json, ".image"), bytes("data:image/svg+xml;base64,").length);
            assertTrue(_contains(svg, horse));
            assertTrue(_contains(svg, "$10"));
            assertTrue(_contains(svg, string.concat("#", vm.toString(t))));
        }
    }

    function _json(uint256 ticketId) internal view returns (string memory) {
        return _decode(sweep.tokenURI(ticketId), bytes("data:application/json;base64,").length);
    }

    function _contains(string memory haystack, string memory needle) internal pure returns (bool) {
        return vm.indexOf(haystack, needle) != type(uint256).max;
    }

    /// @dev Base64 decoder, to read the data URIs back.
    function _decode(string memory uri, uint256 skip) internal pure returns (string memory) {
        bytes memory b = bytes(uri);
        bytes memory out = new bytes((b.length - skip) / 4 * 3);
        uint256 o; uint256 buf; uint256 bits;
        for (uint256 i = skip; i < b.length; ++i) {
            bytes1 c = b[i];
            if (c == "=") break;
            uint256 v = c >= "A" && c <= "Z" ? uint8(c) - 65
                : c >= "a" && c <= "z" ? uint8(c) - 71
                : c >= "0" && c <= "9" ? uint8(c) + 4
                : c == "+" ? 62 : 63;
            buf = (buf << 6) | v;
            bits += 6;
            if (bits >= 8) {
                bits -= 8;
                out[o++] = bytes1(uint8(buf >> bits));
                buf &= (1 << bits) - 1;
            }
        }
        assembly { mstore(out, o) }
        return string(out);
    }
}
