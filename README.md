# SweepStake.nft

Onchain sweepstakes for horse races, paid in USDT on Ethereum mainnet. First up: the 2026 Melbourne Cup (Tuesday 3 November, Flemington).

One contract hosts any number of races, and any number of sweeps on each race at different ticket prices. The default deployment opens 5, 10 and 50 USDT sweeps on the Cup.

## How it works

1. **The owner creates a race.** This sets the field and the time entries close. Then the owner opens sweeps on it, each with its own ticket price.
2. **Enter.** Approve the sweep's entry fee, then call `enter(sweepId)`. Each call buys one ticket, and you can buy more than one.
3. **Fill and draw.** A sweep needs one ticket per horse, so 24 for the Cup. Once it's full, anyone calls `draw(sweepId)`, and one shuffle gives every ticket a different horse.
4. **Settle.** After the race, the owner calls `settle(raceId, horse)` once. Every drawn sweep on that race then pays out.
5. **Claim.** The ticket holding the winner calls `claim(sweepId, ticketId)` and takes that sweep's pool.

## Refunds

A sweep only runs if it fills. Every case where it doesn't ends in a full refund through the same `claim(sweepId, ticketId)` call:

| Situation | What happens |
|---|---|
| The sweep isn't full when entries close | Everyone in that sweep is refunded |
| The sweep is full but nobody called `draw` before the race was settled | Everyone in that sweep is refunded, so draw as soon as a sweep fills |
| A horse is scratched before the draw | The sweep needs one fewer ticket. If it was already full, the last ticket bought is refunded |
| A horse is scratched after the draw | That ticket is refunded and the pool shrinks by one fee |
| The owner cancels a sweep (`cancelSweep`) before its draw | Everyone in it is refunded |
| The owner cancels the race, or hasn't settled within 7 days of entries closing | Anyone can call `cancelRace`, and every sweep on the race is refunded |

Useful views: `sweepStatus(sweepId)` returns Open, Full, Drawn, Settled or Refunding. `ticketsRemaining(sweepId)` returns how many tickets are still needed, and `claimable(sweepId, ticketId)` returns what a ticket can collect right now.

## Randomness

Each draw uses `block.prevrandao`. That's fine for sweeps between mates, but a validator proposing the draw block could in principle bias it. For large pools, swap it for Chainlink VRF.

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
# Defaults: mainnet USDT; 5, 10 and 50 USDT sweeps; entries close 3 Nov 2026 2:00pm AEDT (1:00pm Brisbane)
forge script script/Deploy.s.sol --rpc-url $ETH_RPC_URL --account <keystore> --broadcast --verify

# Different prices (USDT has 6 decimals, so 20 USDT = 20000000)
SWEEP_FEES=20000000,100000000 forge script script/Deploy.s.sol ...
```

After deploying, the owner can add more sweeps with `createSweep(raceId, fee)` any time before entries close.

USDT requires an existing allowance to be reset to 0 before it can be changed to a new non-zero value.
