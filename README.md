# SweepStake.nft

**Melbourne Cup sweep**

An onchain sweepstake for the 2026 Melbourne Cup (Tuesday 3 November, Flemington), paid in USDT on Ethereum mainnet.

## How it works

There are three sweeps on the one contract, so you can pick your stake. They all run on the same race, and each has its own pool and its own 24 tickets.

| Sweep | `sweepId` | Entry | Ticket ids | Biggest pool |
|---|--:|--:|---|--:|
| $1 | 0 | 1 USDT | 1001–1024 | 24 USDT |
| $2 | 1 | 2 USDT | 2001–2024 | 48 USDT |
| $10 | 2 | 10 USDT | 3001–3024 | 240 USDT |

1. **Enter.** Approve the sweep's fee, then call `enter(sweepId)`. Each call mints one NFT ticket, and you can buy more than one, in any sweep.
2. **Draw.** When entries close, the owner calls `draw(sweepId)` for each sweep that has tickets. One shuffle gives every ticket in that sweep a different horse. If a sweep sells out, its draw can happen early.
3. **Race.** After the race, the owner calls `settle(horse)` once. That one result covers every sweep.
4. **Claim.** In each sweep, whoever holds the NFT with the winning horse calls `claim(ticketId)` and takes that sweep's pool.

### The NFT

Tickets are transferable ERC-721s, with their metadata and image stored onchain. The image shows the sweep, the horse and where the ticket stands, and it changes as the ticket's fortunes do.

Whoever holds a ticket when claiming gets paid, so tickets can be sold or given away. If you're buying one, check `claimable(ticketId)` first, because a claimed ticket has nothing left to pay. The NFT stays with its holder after claiming, as a keepsake.

### Edge cases

| Situation | What happens |
|---|---|
| Nobody in a sweep holds the winning horse | That sweep is cancelled and its tickets claim their fee back. Other sweeps aren't affected |
| A horse is scratched after the draw | The owner calls `scratch(horse)`, which applies to every sweep. Tickets holding that horse claim a refund and their pools shrink |
| A horse is scratched before the draw, and the sweep was full | The last ticket bought misses out, and can claim a refund once the draw has happened |
| A horse is scratched before the draw, and the sweep wasn't full | Nobody gets a refund. That horse just isn't drawn |
| A sweep has tickets but hasn't been drawn | `settle` reverts until the owner draws or cancels that sweep |
| A sweep has no tickets | It's ignored, and marked cancelled at settlement |
| The owner never settles | Anyone can call `cancel(sweepId)` a week after entries close, and that sweep's tickets get refunds |
| USDT is sent straight to the contract | It joins no pool and can't be recovered |

Refunds and prizes are both collected with `claim(ticketId)`. `claimable(ticketId)` shows what a ticket is owed, and `ticketStatus(ticketId)` says where it stands.

## Randomness

The draw uses `block.prevrandao`, which is known a block ahead. That's why only the owner can draw: if anyone could, an entrant could draw from a contract that reverts unless they get the horse they want.

So you're trusting the owner not to do that, just as you're trusting them to settle the right winner. A validator proposing the draw block could also bias it. That's fine for a sweep between mates, but for a large pool, swap it for Chainlink VRF.

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

# Also run the full race day against real USDT and the real field
forge test --fork-url $ETH_RPC_URL --match-contract Fork
```

## Deploy

```sh
# Defaults: mainnet USDT, entries close 3 Nov 2026 2:00pm AEDT (1:00pm Brisbane)
forge script script/Deploy.s.sol --rpc-url $ETH_RPC_URL --account <keystore> --broadcast --verify

# Override either of them
USDT=<address> ENTRIES_CLOSE=1793674800 forge script script/Deploy.s.sol ...
```

The fees are set in `entryFees()` in the deploy script and can't be changed after deploying. USDT has 6 decimals, so 10 USDT = `10000000`. USDT also requires an existing allowance to be reset to 0 before it can be changed to a new non-zero value.

## Entry page

`web/` is a React and Vite page where people pick a sweep, buy a ticket, see their NFTs and claim prizes or refunds. Owner actions aren't on it, so use the commands under [Race day](#race-day) for those.

```sh
cd web
cp .env.example .env.local   # then set VITE_SWEEP_ADDRESS to the deployed contract
yarn install
yarn dev
```

`yarn build` writes a static site to `web/dist`, which can be hosted anywhere. The address is built into the page, so rebuild if it changes. Anyone with the link can enter, because the contract has no allowlist.

It works with browser wallets only, so on a phone, open the page in your wallet app's browser. If the contract's ABI changes, run `forge build` and then `yarn sync-abi` in `web/`.

### Hosting

The page is on DigitalOcean App Platform, in the SweepStake project on the Block 52 team: https://sweepstake-6wo88.ondigitalocean.app

It builds from the branch named in `.do/app.yaml`, and pushing doesn't redeploy it. To point it at the contract, set `VITE_SWEEP_ADDRESS` in that file, then apply it:

```sh
doctl --context block52 apps update bca3bf67-c831-47a1-b3be-4cac0e29100f --spec .do/app.yaml
```

To redeploy after pushing changes, run `doctl --context block52 apps create-deployment bca3bf67-c831-47a1-b3be-4cac0e29100f`. Always pass `--context block52`, because `doctl`'s default context may be a different team.

## Race day

These are all owner calls. Add `--rpc-url $ETH_RPC_URL --account <keystore>` to each `cast send`.

```sh
# Morning: scratch any withdrawn horses. This can't be undone, so check the name first.
cast call $SWEEP "horseName(uint256)(string)" <index> --rpc-url $ETH_RPC_URL
cast send $SWEEP "scratch(uint256)" <index>

# 2:00pm AEDT, entries close: draw each sweep that has tickets, before the 3:00pm race
cast send $SWEEP "draw(uint256)" 0
cast send $SWEEP "draw(uint256)" 1
cast send $SWEEP "draw(uint256)" 2

# After the official result: check the name again. This can't be undone either.
cast call $SWEEP "horseName(uint256)(string)" <index> --rpc-url $ETH_RPC_URL
cast send $SWEEP "settle(uint256)" <index>
```
