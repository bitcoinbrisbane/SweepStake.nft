// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {MelbourneCupSweep} from "../src/MelbourneCupSweep.sol";
import {Deploy} from "../script/Deploy.s.sol";

/// @notice The full race day against real mainnet USDT with the real field. Skipped unless forked:
///
///   forge test --fork-url $ETH_RPC_URL --match-contract Fork
contract MelbourneCupSweepForkTest is Test {
    using SafeERC20 for IERC20;

    IERC20 constant USDT = IERC20(0xdAC17F958D2ee523a2206206994597C13D831ec7);
    uint256 constant USDT_BALANCES_SLOT = 2;

    MelbourneCupSweep sweep;
    Deploy deployer;
    uint64 close;

    function setUp() public {
        deployer = new Deploy();
        close = uint64(block.timestamp + 1 days);
        sweep = new MelbourneCupSweep(USDT, deployer.entryFees(), close, deployer.field());
    }

    function _enter(address who, uint256 id) internal returns (uint256 ticketId) {
        (uint256 fee,,,) = sweep.sweeps(id);
        vm.store(address(USDT), keccak256(abi.encode(who, USDT_BALANCES_SLOT)), bytes32(fee));
        assertEq(USDT.balanceOf(who), fee);
        vm.startPrank(who);
        USDT.forceApprove(address(sweep), fee);
        ticketId = sweep.enter(id);
        vm.stopPrank();
    }

    function _claim(uint256 ticketId) internal {
        vm.prank(sweep.ownerOf(ticketId));
        sweep.claim(ticketId);
    }

    function test_raceDay_realUSDT() public {
        if (block.chainid != 1) vm.skip(true);

        // $1 and $10 sell out, $2 sells five.
        for (uint160 i; i < 24; ++i) {
            _enter(address(i + 1000), 0);
            _enter(address(i + 2000), 2);
        }
        for (uint160 i; i < 5; ++i) _enter(address(i + 3000), 1);
        assertEq(USDT.balanceOf(address(sweep)), 24e6 + 240e6 + 10e6);

        vm.warp(close);
        sweep.draw(0);
        sweep.draw(1);
        sweep.draw(2);

        // A horse scratched after the draw refunds its ticket in each sweep that drew it.
        uint256 scratchedHorse = 4;
        sweep.scratch(scratchedHorse);
        uint256 refund1 = sweep.horseTicket(0, scratchedHorse);
        uint256 refund10 = sweep.horseTicket(2, scratchedHorse);
        _claim(refund1);
        _claim(refund10);
        assertEq(USDT.balanceOf(sweep.ownerOf(refund1)), 1e6);
        assertEq(USDT.balanceOf(sweep.ownerOf(refund10)), 10e6);

        // Pick a winner the $2 sweep's five tickets did not draw, so that sweep gets refunded.
        uint256 winningHorse = 24;
        for (uint256 h; h < 24; ++h) {
            if (h != scratchedHorse && sweep.horseTicket(1, h) == 0) { winningHorse = h; break; }
        }
        assertLt(winningHorse, 24);
        sweep.settle(winningHorse);

        uint256 win1 = sweep.horseTicket(0, winningHorse);
        uint256 win10 = sweep.horseTicket(2, winningHorse);
        _claim(win1);
        _claim(win10);
        assertEq(USDT.balanceOf(sweep.ownerOf(win1)), 23e6);
        assertEq(USDT.balanceOf(sweep.ownerOf(win10)), 230e6);
        for (uint256 t = 2001; t <= 2005; ++t) _claim(t);

        // Every cent is accounted for, and the $2 tickets got their fee back.
        assertEq(USDT.balanceOf(address(sweep)), 0);
        assertEq(USDT.balanceOf(sweep.ownerOf(2001)), 2e6);
    }
}
