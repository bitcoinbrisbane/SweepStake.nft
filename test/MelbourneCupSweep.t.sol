// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MelbourneCupSweep} from "../src/MelbourneCupSweep.sol";

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

contract MelbourneCupSweepTest is Test {
    MockUSDT usdt;
    MelbourneCupSweep sweep;
    uint256 constant FEE = 10e6; // 10 USDT
    uint64 close;

    function setUp() public {
        usdt = new MockUSDT();
        close = uint64(block.timestamp + 1 days);
        string[] memory horses = new string[](4);
        horses[0] = "Middle Earth"; horses[1] = "Vauban"; horses[2] = "Asterix"; horses[3] = "Zakouma";
        sweep = new MelbourneCupSweep(IERC20(address(usdt)), FEE, close, horses);
    }

    function _enter(address who) internal returns (uint256 id) {
        usdt.mint(who, FEE);
        vm.startPrank(who);
        usdt.approve(address(sweep), FEE);
        id = sweep.enter();
        vm.stopPrank();
    }

    function _horseOf(uint256 id) internal view returns (uint256 h) { (, h,,) = sweep.ticket(id); }

    function test_fullFlow_winnerTakesPool() public {
        address[3] memory p = [address(0xA), address(0xB), address(0xC)];
        for (uint256 i; i < 3; ++i) _enter(p[i]);
        assertEq(usdt.balanceOf(address(sweep)), 30e6);

        vm.warp(close);
        vm.prevrandao(bytes32(uint256(42)));
        sweep.draw();

        // Every ticket got a different, valid horse.
        bool[4] memory seen;
        for (uint256 i; i < 3; ++i) { uint256 h = _horseOf(i); assertLt(h, 4); assertFalse(seen[h]); seen[h] = true; }

        uint256 winHorse = _horseOf(1);
        sweep.settle(winHorse);
        assertEq(sweep.claimable(1), 30e6);
        assertEq(sweep.claimable(0), 0);

        vm.prank(p[1]);
        sweep.claim(1);
        assertEq(usdt.balanceOf(p[1]), 30e6);
        assertEq(sweep.claimable(1), 0);
    }

    function test_unownedWinner_refundsEveryone() public {
        _enter(address(0xA)); _enter(address(0xB));
        vm.warp(close);
        sweep.draw();
        uint256 unowned;
        for (uint256 h; h < 4; ++h) if (sweep.horseTicket(h) == 0) { unowned = h; break; }
        sweep.settle(unowned);
        assertEq(uint256(sweep.state()), uint256(MelbourneCupSweep.State.Cancelled));
        vm.prank(address(0xA)); sweep.claim(0);
        assertEq(usdt.balanceOf(address(0xA)), FEE);
    }

    function test_scratchAfterDraw_refundsThatTicket_andShrinksPool() public {
        _enter(address(0xA)); _enter(address(0xB)); _enter(address(0xC));
        vm.warp(close);
        sweep.draw();
        sweep.scratch(_horseOf(0));
        assertEq(sweep.claimable(0), FEE);
        assertEq(sweep.prizePool(), 20e6);

        vm.prank(address(0xA)); sweep.claim(0);
        sweep.settle(_horseOf(2));
        assertEq(sweep.claimable(2), 20e6);
        vm.prank(address(0xC)); sweep.claim(2);
        assertEq(usdt.balanceOf(address(sweep)), 0);
    }

    function test_scratchBeforeDraw_extraTicketRefunded() public {
        for (uint160 i = 1; i <= 4; ++i) _enter(address(i));
        sweep.scratch(3);
        vm.warp(close);
        sweep.draw();
        uint256 horseless;
        for (uint256 t; t < 4; ++t) if (_horseOf(t) == type(uint256).max) ++horseless;
        assertEq(horseless, 1);
        assertEq(sweep.prizePool(), 30e6);
    }

    function test_fullSweep_canDrawEarly_andRejectsMore() public {
        for (uint160 i = 1; i <= 4; ++i) _enter(address(i));
        usdt.mint(address(5), FEE);
        vm.startPrank(address(5));
        usdt.approve(address(sweep), FEE);
        vm.expectRevert(MelbourneCupSweep.SweepFull.selector);
        sweep.enter();
        vm.stopPrank();
        sweep.draw(); // before close, allowed because full
    }

    function test_cannotDrawEarlyUnlessFull() public {
        _enter(address(0xA));
        vm.expectRevert(MelbourneCupSweep.EntriesStillOpen.selector);
        sweep.draw();
    }

    function test_cannotEnterAfterClose() public {
        vm.warp(close);
        usdt.mint(address(0xA), FEE);
        vm.startPrank(address(0xA));
        usdt.approve(address(sweep), FEE);
        vm.expectRevert(MelbourneCupSweep.EntriesClosed.selector);
        sweep.enter();
        vm.stopPrank();
    }

    function test_entryFee_changeableOnlyBeforeEntries() public {
        sweep.setEntryFee(5e6);
        assertEq(sweep.entryFee(), 5e6);
        usdt.mint(address(0xA), 5e6);
        vm.startPrank(address(0xA)); usdt.approve(address(sweep), 5e6); sweep.enter(); vm.stopPrank();
        vm.expectRevert(MelbourneCupSweep.FeeLocked.selector);
        sweep.setEntryFee(1e6);
    }

    function test_onlyOwnerSettlesAndScratches() public {
        _enter(address(0xA));
        vm.warp(close);
        sweep.draw();
        vm.startPrank(address(0xBAD));
        vm.expectRevert();
        sweep.settle(0);
        vm.expectRevert();
        sweep.scratch(0);
        vm.stopPrank();
    }

    function test_anyoneCanCancel_ifOwnerLate() public {
        _enter(address(0xA));
        vm.warp(close);
        sweep.draw();
        vm.prank(address(0xA));
        vm.expectRevert(MelbourneCupSweep.TooEarly.selector);
        sweep.cancel();
        vm.warp(uint256(close) + 7 days);
        vm.prank(address(0xA));
        sweep.cancel();
        vm.prank(address(0xA)); sweep.claim(0);
        assertEq(usdt.balanceOf(address(0xA)), FEE);
    }

    function test_cannotClaimSomeoneElsesTicket() public {
        _enter(address(0xA));
        sweep.cancel();
        vm.prank(address(0xB));
        vm.expectRevert(MelbourneCupSweep.NotYourTicket.selector);
        sweep.claim(0);
    }

    function testFuzz_drawAssignsUniqueHorses(bytes32 rand, uint8 entrants) public {
        uint256 n = bound(entrants, 1, 4);
        for (uint160 i = 1; i <= n; ++i) _enter(address(i));
        vm.warp(close);
        vm.prevrandao(rand);
        sweep.draw();
        bool[4] memory seen;
        for (uint256 t; t < n; ++t) { uint256 h = _horseOf(t); assertFalse(seen[h]); seen[h] = true; }
    }
}
