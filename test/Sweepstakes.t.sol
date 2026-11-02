// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Sweepstakes} from "../src/Sweepstakes.sol";

/// @dev Mimics mainnet USDT: 6 decimals and transfer/transferFrom/approve return nothing.
contract MockUSDT {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint8 public constant decimals = 6;

    function mint(address to, uint256 amt) external { balanceOf[to] += amt; }
    function approve(address s, uint256 amt) external { allowance[msg.sender][s] = amt; }
    function transfer(address to, uint256 amt) external { balanceOf[msg.sender] -= amt; balanceOf[to] += amt; }
    function transferFrom(address f, address to, uint256 amt) external {
        allowance[f][msg.sender] -= amt; balanceOf[f] -= amt; balanceOf[to] += amt;
    }
}

contract SweepstakesTest is Test {
    MockUSDT usdt;
    Sweepstakes s;
    uint256 race;
    uint256 cheap; // 5 USDT sweep
    uint256 dear;  // 50 USDT sweep
    uint64 close;
    uint256 constant N = 4; // horses in the test race

    function setUp() public {
        usdt = new MockUSDT();
        s = new Sweepstakes(IERC20(address(usdt)));
        close = uint64(block.timestamp + 1 days);
        string[] memory horses = new string[](N);
        horses[0] = "Middle Earth"; horses[1] = "Vauban"; horses[2] = "Asterix"; horses[3] = "Zakouma";
        race = s.createRace("Melbourne Cup 2026", close, horses);
        cheap = s.createSweep(race, 5e6);
        dear = s.createSweep(race, 50e6);
    }

    // ------------------------------------------------------------ helpers

    function _enter(uint256 sweepId, address who) internal returns (uint256 id) {
        (, uint256 fee,,) = s.sweep(sweepId);
        usdt.mint(who, fee);
        vm.startPrank(who);
        usdt.approve(address(s), fee);
        id = s.enter(sweepId);
        vm.stopPrank();
    }

    function _fill(uint256 sweepId, uint160 firstAddr) internal {
        uint256 need = s.ticketsRemaining(sweepId);
        for (uint160 i; i < need; ++i) _enter(sweepId, address(firstAddr + i));
    }

    function _horseOf(uint256 sweepId, uint256 t) internal view returns (uint256 h) { (, h,,) = s.ticket(sweepId, t); }
    function _holder(uint256 sweepId, uint256 t) internal view returns (address a) { (a,,,) = s.ticket(sweepId, t); }

    function _claim(uint256 sweepId, uint256 t) internal returns (uint256 got) {
        address who = _holder(sweepId, t);
        uint256 before = usdt.balanceOf(who);
        vm.prank(who);
        s.claim(sweepId, t);
        got = usdt.balanceOf(who) - before;
    }

    // ------------------------------------------------------------ multiple sweeps, one race

    function test_twoSweepsDifferentPrices_settleOnce_bothPayOut() public {
        _fill(cheap, 0x100);
        _fill(dear, 0x200);
        assertEq(usdt.balanceOf(address(s)), N * 5e6 + N * 50e6);

        vm.prevrandao(bytes32(uint256(1)));
        s.draw(cheap);
        vm.prevrandao(bytes32(uint256(2)));
        s.draw(dear);

        vm.warp(close);
        s.settle(race, 2);

        uint256 wc = s.horseTicket(cheap, 2) - 1;
        uint256 wd = s.horseTicket(dear, 2) - 1;
        assertEq(_claim(cheap, wc), N * 5e6);
        assertEq(_claim(dear, wd), N * 50e6);
        assertEq(usdt.balanceOf(address(s)), 0);

        // Everyone else gets nothing.
        for (uint256 t; t < N; ++t) if (t != wc) assertEq(s.claimable(cheap, t), 0);
    }

    function test_drawGivesEveryTicketADifferentHorse() public {
        _fill(dear, 0x200);
        s.draw(dear);
        bool[N] memory seen;
        for (uint256 t; t < N; ++t) { uint256 h = _horseOf(dear, t); assertLt(h, N); assertFalse(seen[h]); seen[h] = true; }
    }

    // ------------------------------------------------------------ not full = refund everyone

    function test_notFullAtClose_everyoneRefunded() public {
        _enter(cheap, address(0xA));
        _enter(cheap, address(0xB));
        _enter(cheap, address(0xA)); // A buys two

        assertEq(s.claimable(cheap, 0), 0); // still filling
        assertEq(s.sweepStatus(cheap), "Open");

        vm.warp(close);
        assertEq(s.sweepStatus(cheap), "Refunding");
        assertEq(_claim(cheap, 0), 5e6);
        assertEq(_claim(cheap, 1), 5e6);
        assertEq(_claim(cheap, 2), 5e6);
        assertEq(usdt.balanceOf(address(s)), 0);
    }

    function test_cannotDrawUntilFull() public {
        _enter(cheap, address(0xA));
        vm.expectRevert(Sweepstakes.SweepNotFull.selector);
        s.draw(cheap);
        vm.warp(close);
        vm.expectRevert(Sweepstakes.SweepNotFull.selector);
        s.draw(cheap);
    }

    function test_fullButNeverDrawn_refundsOnceSettled() public {
        _fill(cheap, 0x100);
        vm.warp(close);
        s.settle(race, 0);
        assertEq(s.sweepStatus(cheap), "Refunding");
        assertEq(_claim(cheap, 0), 5e6);
        vm.expectRevert(Sweepstakes.SweepClosed.selector);
        s.draw(cheap);
    }

    function test_fullCanStillBeDrawnAfterClose_beforeSettle() public {
        _fill(cheap, 0x100);
        vm.warp(close);
        s.draw(cheap);
        s.settle(race, 1);
        assertEq(_claim(cheap, s.horseTicket(cheap, 1) - 1), N * 5e6);
    }

    function test_cannotOverfill_orEnterAfterClose() public {
        _fill(cheap, 0x100);
        usdt.mint(address(0xF), 5e6);
        vm.startPrank(address(0xF));
        usdt.approve(address(s), 5e6);
        vm.expectRevert(Sweepstakes.SweepFull.selector);
        s.enter(cheap);
        vm.warp(close);
        vm.expectRevert(Sweepstakes.EntriesClosed.selector);
        s.enter(dear);
        vm.stopPrank();
    }

    // ------------------------------------------------------------ scratchings

    function test_scratchBeforeDraw_needsOneFewerTicket() public {
        _enter(cheap, address(0xA)); _enter(cheap, address(0xB)); _enter(cheap, address(0xC));
        assertEq(s.ticketsRemaining(cheap), 1);
        s.scratch(race, 3);
        assertEq(s.ticketsRemaining(cheap), 0);
        s.draw(cheap);
        for (uint256 t; t < 3; ++t) assertTrue(_horseOf(cheap, t) != 3);
    }

    function test_scratchWhenAlreadyFull_lastTicketRefunded() public {
        _fill(cheap, 0x100);
        s.scratch(race, 0);
        s.draw(cheap);
        assertEq(_horseOf(cheap, N - 1), type(uint256).max);
        assertEq(s.claimable(cheap, N - 1), 5e6);
        assertEq(s.prizePool(cheap), (N - 1) * 5e6);
    }

    function test_scratchAfterDraw_refundsThatTicket_shrinksPool() public {
        _fill(dear, 0x200);
        s.draw(dear);
        uint256 t0 = s.horseTicket(dear, 0) - 1;
        s.scratch(race, 0);
        assertEq(_claim(dear, t0), 50e6);
        assertEq(s.prizePool(dear), (N - 1) * 50e6);

        vm.warp(close);
        s.settle(race, 1);
        assertEq(_claim(dear, s.horseTicket(dear, 1) - 1), (N - 1) * 50e6);
        assertEq(usdt.balanceOf(address(s)), 0);
    }

    function test_cannotSettleOnScratchedHorse() public {
        s.scratch(race, 2);
        vm.warp(close);
        vm.expectRevert(Sweepstakes.BadHorse.selector);
        s.settle(race, 2);
    }

    // ------------------------------------------------------------ admin and safety

    function test_feeChangeableOnlyBeforeFirstEntry() public {
        s.setEntryFee(cheap, 2e6);
        _enter(cheap, address(0xA));
        vm.expectRevert(Sweepstakes.FeeLocked.selector);
        s.setEntryFee(cheap, 1e6);
    }

    function test_cancelSweep_refunds() public {
        _enter(dear, address(0xA));
        s.cancelSweep(dear);
        assertEq(_claim(dear, 0), 50e6);
    }

    function test_anyoneCancelsRace_ifOwnerWeekLate() public {
        _fill(cheap, 0x100);
        s.draw(cheap);
        vm.warp(close);
        vm.prank(address(0xA));
        vm.expectRevert(Sweepstakes.TooEarly.selector);
        s.cancelRace(race);
        vm.warp(uint256(close) + 7 days);
        vm.prank(address(0xA));
        s.cancelRace(race);
        for (uint256 t; t < N; ++t) assertEq(_claim(cheap, t), 5e6);
    }

    function test_cannotSettleBeforeClose() public {
        vm.expectRevert(Sweepstakes.TooEarly.selector);
        s.settle(race, 0);
    }

    function test_onlyOwnerAdmin() public {
        vm.startPrank(address(0xBAD));
        vm.expectRevert(); s.createSweep(race, 1e6);
        vm.expectRevert(); s.scratch(race, 0);
        vm.expectRevert(); s.settle(race, 0);
        vm.expectRevert(); s.cancelSweep(cheap);
        vm.stopPrank();
    }

    function test_cannotClaimOthersTicket_orTwice() public {
        _enter(cheap, address(0xA));
        s.cancelSweep(cheap);
        vm.prank(address(0xB));
        vm.expectRevert(Sweepstakes.NotYourTicket.selector);
        s.claim(cheap, 0);
        _claim(cheap, 0);
        vm.prank(address(0xA));
        vm.expectRevert(Sweepstakes.NothingToClaim.selector);
        s.claim(cheap, 0);
    }

    function test_secondRace_isIndependent() public {
        string[] memory horses = new string[](2);
        horses[0] = "A"; horses[1] = "B";
        uint256 r2 = s.createRace("Cox Plate", close, horses);
        uint256 sw = s.createSweep(r2, 1e6);
        _fill(sw, 0x300);
        s.draw(sw);
        vm.warp(close);
        s.settle(r2, 1);
        assertEq(_claim(sw, s.horseTicket(sw, 1) - 1), 2e6);
        (,,,, bool settled,,) = s.race(race);
        assertFalse(settled);
    }

    // ------------------------------------------------------------ invariants

    /// Whatever happens, the contract can always pay every ticket what it's owed.
    function testFuzz_solvent(bytes32 rand, uint8 scratchMask, uint8 winnerSeed, bool drawIt) public {
        _fill(cheap, 0x100);
        _enter(dear, address(0x999)); // dear never fills
        for (uint256 h; h < N - 2; ++h) if (scratchMask & (1 << h) != 0) s.scratch(race, h);
        vm.prevrandao(rand);
        if (drawIt) s.draw(cheap);
        vm.warp(close);

        uint256 winner = winnerSeed % N;
        if (!s.scratched(race, winner)) s.settle(race, winner);
        else s.cancelRace(race);

        uint256 owed;
        for (uint256 t; t < s.ticketCount(cheap); ++t) owed += s.claimable(cheap, t);
        owed += s.claimable(dear, 0);
        assertLe(owed, usdt.balanceOf(address(s)));
        for (uint256 t; t < s.ticketCount(cheap); ++t) if (s.claimable(cheap, t) > 0) _claim(cheap, t);
        _claim(dear, 0);
        assertEq(usdt.balanceOf(address(s)), 0, "every cent paid out");
    }
}
