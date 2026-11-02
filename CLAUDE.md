# SweepStake.nft: handover

Onchain sweepstakes for horse races, paid in USDT. The first target is the **2026 Melbourne Cup, Tuesday 3 Nov 2026** (Flemington, traditionally 3:00pm AEDT, which is 2:00pm Brisbane). The owner is Lucas (GitHub `bitcoinbrisbane`).

## Status (2 Nov 2026)

- `src/Sweepstakes.sol` is written and passes 19 tests, including a fuzz test for solvency.
- It has **not been deployed** to any network yet.
- `script/Deploy.s.sol` dry-runs cleanly. It deploys the contract, creates the Melbourne Cup race and opens 5, 10 and 50 USDT sweeps, for about 2.7M gas in total.

## Decisions Lucas has made

- **Chain and token:** Ethereum mainnet, USDT (`0xdAC17F958D2ee523a2206206994597C13D831ec7`, 6 decimals, non-standard ERC-20 that returns no bool, so all transfers go through `SafeERC20`).
- **Entry model:** each sweep has an entry fee per ticket, and the winner takes that sweep's pool. Prices are set per sweep. `setEntryFee` works only until the first entry.
- **Multiple sweeps:** one contract holds many **races**, and each race holds many **sweeps** at different prices. The race is settled once and every sweep on it pays out.
- **Refunds when a sweep doesn't fill:** a sweep runs only if it sells exactly one ticket per active horse (24 for the Cup). Otherwise everyone in it is refunded. Lucas chose this over dealing out multiple horses per ticket or setting a minimum number of entries.
- **Randomness:** `block.prevrandao`, shuffled with Fisher-Yates in `draw()`. This was a deliberate choice for speed on a small sweep between mates. Chainlink VRF is the upgrade path if pools get large.

## How the contract works

- **Owner:**
  - `createRace(name, entriesClose, horses[])`
  - `createSweep(raceId, fee)`
  - `setEntryFee(sweepId, fee)` (only before the first entry)
  - `scratch(raceId, horse)`
  - `settle(raceId, horse)` (only after `entriesClose`)
  - `cancelSweep(sweepId)` (only before the draw)
  - `cancelRace(raceId)`. Anyone can call this once the owner is 7 days past `entriesClose` without settling.
- **Anyone:**
  - `enter(sweepId)` buys one ticket, and a person can buy several.
  - `draw(sweepId)` works once the sweep is full, up until the race is settled.
  - `claim(sweepId, ticketId)` pays out winnings and every kind of refund.
- **Views:** `claimable`, `prizePool`, `sweepStatus` (Open/Full/Drawn/Settled/Refunding), `ticketsRemaining`, `ticket`, `race`, `sweep`, `horseTicket`.
- **Horse index** = saddlecloth number − 1.
- **Prize pool** = entry fee × tickets whose horse is still running. The pool is tracked per sweep, never from `balanceOf`, because sweeps share the contract's balance.

Refund rules (all implemented in `claimable()`):

| Case | Result |
|---|---|
| Not full at `entriesClose` | Full refund for the sweep |
| Full but not drawn before `settle` | Full refund for the sweep |
| Horse scratched before the draw | Sweep needs one fewer ticket. If it was already full, the last ticket gets no horse and is refunded |
| Horse scratched after the draw | That ticket is refunded and the pool shrinks |
| Sweep or race cancelled | Full refund |

## Open items before deploying

1. **Verify the saddlecloth order.** bets.com.au and races.com.au disagreed. `Deploy.s.sol` uses the bets.com.au order (Sons And Lovers = 1, Trustyourinstinct = 2, ...). Races.com.au appears to number by barrier, which is probably wrong. Check against the official VRC field.
2. **Confirm the race start time.** Entries close by default at `1793674800` (3 Nov 2026 03:00 UTC = 2:00pm AEDT = 1:00pm Brisbane), which assumes the race jumps at 3:00pm AEDT. Override with `ENTRIES_CLOSE`.
3. **Pick sweep prices.** The defaults are `5,10,50` USDT. Each sweep needs 24 buyers, so 72 tickets across three sweeps is ambitious for a single day. Consider `SWEEP_FEES=10000000` alone.
4. **Gas.** Expect roughly 100k gas per entry on mainnet, which is significant against a 5 USDT ticket.

## Race-day runbook

1. Deploy (see below) and share the contract address and sweep ids.
2. Players reset their USDT allowance to 0 if it's non-zero, approve the fee, then call `enter(sweepId)`.
3. As each sweep fills, call `draw(sweepId)` straight away, **before settling**. An undrawn sweep gets refunded at settlement.
4. Mark any late scratchings with `scratch(0, horse)`.
5. After the official result, call `settle(0, winnerIndex)`.
6. Winners and refund holders call `claim(sweepId, ticketId)`.

## Commands

```sh
forge test
forge script script/Deploy.s.sol --rpc-url $ETH_RPC_URL --account <keystore> --broadcast --verify
# env overrides: USDT, SWEEP_FEES (comma-separated base units), ENTRIES_CLOSE (unix seconds)
```

- **Solidity version:** `foundry.toml` pins solc `0.8.28`, with EVM `cancun` and the optimizer at 200 runs.
- **Libraries:** `lib/forge-std` and `lib/openzeppelin-contracts` (v5.4.0) are git submodules, so clone with `--recurse-submodules` or run `git submodule update --init`.
- **Cloud session workaround:** the cloud session couldn't reach binaries.soliditylang.org, so it ran forge with `--offline --use <path to solc 0.8.28>`. A normal local machine doesn't need those flags.

## Ideas not yet built

- **NFT tickets:** make tickets ERC-721s with onchain art showing the horse drawn. The repo name hints at this. It would make tickets transferable, so people could trade a fancied horse before the race.
- **Chainlink VRF** in place of `prevrandao`.
- **A simple web front end** for approving, entering, drawing, checking status and claiming.

## Related

The same session also started `bitcoinbrisbane/digitaldogs`, an onchain dog NFT project forked from the Nouns playbook. It's unrelated to this repo apart from sharing a Nouns/CypherPunks influence.
