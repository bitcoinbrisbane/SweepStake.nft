# SweepStake.nft

**Melbourne Cup sweep**

An onchain sweepstake for the 2026 Melbourne Cup (Tuesday 3 November, Flemington), paid in USDT on Ethereum mainnet.

## How it works

1. **Enter.** Approve the entry fee (10 USDT by default), then call `enter()`. Each call buys one ticket, and you can buy more than one. There are as many tickets as there are horses, so 24 at most.
2. **Draw.** When entries close, anyone calls `draw()`. One shuffle gives every ticket a different horse. If all 24 tickets sell, the draw can happen early.
3. **Race.** After the race, the owner calls `settle(horse)` with the winner.
4. **Claim.** The holder of the winning horse calls `claim(ticketId)` and takes the whole pool.

### Edge cases

| Situation | What happens |
|---|---|
| Nobody holds the winning horse (fewer than 24 entries) | The sweep is cancelled and everyone claims their fee back |
| A horse is scratched after the draw | The owner calls `scratch(horse)`. That ticket gets a refund and the pool shrinks |
| A horse is scratched before the draw, and the sweep was full | The last ticket bought misses out and gets a refund |
| The owner never settles | Anyone can call `cancel()` a week after entries close, and everyone gets a refund |
| You want a different fee | The owner calls `setEntryFee()`, which works only before the first entry |

## Randomness

The draw uses `block.prevrandao`. That's fine for a sweep between mates, but a validator proposing the draw block could in principle bias it. For a large pool, swap it for Chainlink VRF.

## The field

Horse index = saddlecloth number − 1. Sources disagree on numbering, so check against the official VRC field before deploying.

| # | Horse | Barrier | Jockey |
|--:|---|--:|---|
| 1 | Sons And Lovers | 3 | Dylan Browne McMonagle |
| 2 | Trustyourinstinct | 18 | James McDonald |
| 3 | Knight's Choice | 2 | Robbie Dolan |
| 4 | Middle Earth | 1 | Mark Zahra |
| 5 | Vauban | 22 | Jordan Childs |
| 6 | Enfjaar | 8 | Ray Dawson |
| 7 | Royal Supremacy | 21 | Ben Allen |
| 8 | Wine Dark Sea | 23 | Damian Lane |
| 9 | Asterix | 6 | Jye McNeil |
| 10 | Goodie Two Shoes | 19 | Wayne Lordan |
| 11 | Juja Kibo | 14 | Sam Clipperton |
| 12 | Hopewell Rock | 15 | Zac Lloyd |
| 13 | Onesmoothoperator | 13 | Declan Bates |
| 14 | Soul Of Spain | 5 | Tommy Berry |
| 15 | Zahrann | 11 | Ben Melham |
| 16 | So You Are | 7 | Rachel King |
| 17 | Future History | 12 | Jamie Melham |
| 18 | James J Braddock | 24 | Craig Williams |
| 19 | Kizlyar | 20 | Beau Mertens |
| 20 | Point Of Law | 9 | Ethan Brown |
| 21 | Strictly Business | 4 | Michael Dee |
| 22 | Mr Monaco | 16 | Jabez Johnstone |
| 23 | Zakouma | 10 | William Pike |
| 24 | Shockletz | 17 | Harry Coffey |

## Develop

```sh
forge test
```

## Deploy

```sh
# Defaults: mainnet USDT, 10 USDT entry, entries close 3 Nov 2026 2:00pm AEDT (1:00pm Brisbane)
forge script script/Deploy.s.sol --rpc-url $ETH_RPC_URL --account <keystore> --broadcast --verify

# Override any of them
ENTRY_FEE=5000000 ENTRIES_CLOSE=1793674800 forge script script/Deploy.s.sol ...
```

USDT has 6 decimals, so 10 USDT = `10000000`. USDT also requires an existing allowance to be reset to 0 before it can be changed to a new non-zero value.
