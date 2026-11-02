# SweepStake.nft

**Melbourne Cup sweep**

An onchain sweepstake for the 2026 Melbourne Cup (Tuesday 3 November, Flemington), paid in a USD stablecoin chosen at deployment. By default that's USDT on Ethereum mainnet.

## Live

| | |
|---|---|
| Entry page | https://sweepstake-6wo88.ondigitalocean.app |
| Contract, on Ethereum mainnet | [`0x5a5f04760A99F0792C0a3ff0B5A14890c7292f07`](https://etherscan.io/address/0x5a5f04760A99F0792C0a3ff0B5A14890c7292f07#code) |
| Owner | [`0x077Be890F8e395987732605BE1A71D72FD0e9882`](https://etherscan.io/address/0x077Be890F8e395987732605BE1A71D72FD0e9882) |
| Test version, on Sepolia | Add `?testnet=true` to the entry page. The contract is [`0x7c054427A4f0264Db51E9B8eAbfd2221B995dC20`](https://sepolia.etherscan.io/address/0x7c054427A4f0264Db51E9B8eAbfd2221B995dC20#code) |

Entries close at 2:50pm AEDT (1:50pm Brisbane) on 3 November 2026, and results can go in from 3:20pm AEDT (2:20pm Brisbane).

An earlier version at [`0x8Dd82896fb5a4B05C8Fe99A7bE223a44DF987fA3`](https://etherscan.io/address/0x8Dd82896fb5a4B05C8Fe99A7bE223a44DF987fA3#writeContract) drew horses at the close. Its sweeps are cancelled, and its ticket holder can get their fee back by calling `claim` on Etherscan.

## How it works

There are three sweeps on the one contract, so you can pick your stake. They all run on the same race, and each has its own pool and its own 24 tickets.

| Sweep | `sweepId` | Ticket ids | Biggest pool |
|---|--:|---|--:|
| $1 | 0 | 1001–1024 | $24 |
| $2 | 1 | 2001–2024 | $48 |
| $10 | 2 | 3001–3024 | $240 |

1. **Enter.** Approve the sweep's fee, then call `enter(sweepId)`. Each call mints one NFT ticket and pulls a random horse from that sweep's hat on the spot. Each horse only comes out once per sweep. You can buy more than one, in any sweep.
2. **Race.** After the race, the owner calls `settle(horse)` once. That one result covers every sweep, and the contract won't accept it before 3:20pm AEDT (2:20pm Brisbane), 20 minutes after the start.
3. **Claim.** In each sweep, whoever holds the NFT with the winning horse calls `claim(ticketId)` and takes that sweep's pool.

Gas use depends on which horse comes out, so a purchase needs a margin over its estimate or it can run out of gas and fail. The entry page asks for half as much again, and unused gas is refunded.

### The NFT

Tickets are transferable ERC-721s, with their metadata and image stored onchain. The image shows just the horse, the fee and the token id, and fades if the horse is scratched. Where a ticket stands is in its metadata, and `ticketStatus(ticketId)` gives it in words.

The art works like CryptoPunks: each horse is a 24x24 sprite kept in the contract (`src/HorseArt.sol`) and drawn as SVG on request. A horse's coat and silks come from a hash of its name, so it looks the same in every sweep. **The silks are generated, not the horse's real racing colours.** `horseImage(horse)` returns a horse's art on its own.

Whoever holds a ticket when claiming gets paid, so tickets can be sold or given away. If you're buying one, check `claimable(ticketId)` first, because a claimed ticket has nothing left to pay. The NFT stays with its holder after claiming, as a keepsake.

### Edge cases

| Situation | What happens |
|---|---|
| Nobody in a sweep holds the winning horse | That sweep is cancelled and its tickets claim their fee back. Other sweeps aren't affected |
| A horse is scratched | The owner calls `scratch(horse)`, which applies to every sweep. It goes straight out of every hat, and anyone holding it is sent their entry fee back in the same transaction |
| A scratching can't pay a holder, say the token has blocked their address | The scratching still stands, and that holder can call `claim(ticketId)` instead |
| All of a sweep's horses are taken | `enter` reverts with `SweepFull` |
| A sweep has no tickets | It's ignored, and marked cancelled at settlement |
| A smart contract wallet tries to enter | `enter` reverts with `WalletsOnly`. See [Randomness](#randomness) |
| The owner never settles | Anyone can call `cancel(sweepId)` a week after entries close, and that sweep's tickets get refunds |
| Tokens are sent straight to the contract | They join no pool and can't be recovered |

`claimable(ticketId)` shows what a ticket is owed, `ticketStatus(ticketId)` says where it stands, and `availableHorses(sweepId)` says how many more tickets a sweep can sell.

## Randomness

The horse is picked at purchase from `block.prevrandao`, the block's timestamp and the buyer's address. Only wallets can enter, which stops a contract from buying and reverting until it gets the horse it wants.

That doesn't make it unbeatable. `block.prevrandao` is known a block ahead, so someone determined could work out which horse they'd get and time their purchase, and a validator could bias it. That's fine for a sweep between mates, but for a large pool, use Chainlink VRF.

## The field

Horse index = saddlecloth number − 1. This matches Racing Australia's form guide, published 2 November 2026.

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
| 21 | Strictly Business | 4 | Dean Yendall |
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
# Defaults: mainnet USDT, entries close 3 Nov 2026 2:50pm AEDT (1:50pm Brisbane), results open 3:20pm AEDT (2:20pm Brisbane)
forge script script/Deploy.s.sol --rpc-url $ETH_RPC_URL --account <keystore> --broadcast --verify

# Override any of them
TOKEN=<address> ENTRIES_CLOSE=1793677800 RESULTS_OPEN=1793679600 forge script script/Deploy.s.sol ...
```

The betting currency is passed to the constructor. Use a USD stablecoin, because tickets are labelled in dollars. `TOKEN` defaults to USDT on Ethereum mainnet and is required on any other chain. The script works out the fees from the token's decimals, and deploying fails if that address has no contract on that chain. The token, fees and both times can't be changed after deploying.

USDT requires an existing allowance to be reset to 0 before it can be changed to a new non-zero value. The entry page handles that.

If `--verify` fails on an older Foundry build, it's because Etherscan's current API needs a `chainid` that those builds drop. Run `foundryup`, or submit the source to `https://api.etherscan.io/v2/api?chainid=1` yourself. The contract is deployed either way.

### Testing on Sepolia

Real USDT isn't on Sepolia, so deploy the free test token first. Anyone can mint it, and the entry page has a button for that on test chains.

```sh
forge create test/mocks/TestUSDT.sol:TestUSDT --rpc-url <sepolia-rpc> --account <keystore> --broadcast

# Sepolia currently charges far more gas for this deploy than Foundry simulates, about 33M against 5M,
# so the multiplier is needed or it runs out of gas. Short times let you run the whole sweep.
TOKEN=<test-token> ENTRIES_CLOSE=$(($(date +%s) + 1800)) RESULTS_OPEN=$(($(date +%s) + 2100)) \\
forge script script/Deploy.s.sol --rpc-url <sepolia-rpc> --account <keystore> --broadcast --gas-estimate-multiplier 850
```

Set `VITE_TESTNET_SWEEP_ADDRESS` to the result, and `?testnet=true` on the page's URL switches to it. This tests how it behaves, but not what gas costs on mainnet.

### Testing on Base

```sh
# USDC on Base. USDT there is 0xfde4C96c8593536E31F229EA8f37b2ADa2699bb2.
# Short times, so you can run the draw and the result straight away.
TOKEN=0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913 \
ENTRIES_CLOSE=$(($(date +%s) + 600)) RESULTS_OPEN=$(($(date +%s) + 900)) \
forge script script/Deploy.s.sol --rpc-url https://mainnet.base.org --account <keystore> --broadcast --verify

# Point the page at it. On Base Sepolia, use base-sepolia and USDC 0x036CbD53842c5426634e7929541eC2318f3dCF7e.
cd web && VITE_CHAIN=base VITE_SWEEP_ADDRESS=<address> yarn dev
```

Etherscan's free API plan doesn't cover Base, so `--verify` needs a paid key there. On Base, `block.prevrandao` comes from Ethereum and stays the same across several blocks, so the draw's randomness is weaker. That's fine for a test.

## Entry page

`web/` is a React and Vite page where people pick a sweep, buy an NFT ticket and see which horse comes out of the hat, watch the runners table fill up, and claim prizes or refunds. Owner actions aren't on it, so use the commands under [Race day](#race-day) for those.

```sh
cd web
cp .env.example .env.local   # then set VITE_SWEEP_ADDRESS to the deployed contract
yarn install
yarn dev
```

`yarn build` writes a static site to `web/dist`, which can be hosted anywhere. The address is built into the page, so rebuild if it changes. Anyone with the link can enter, because the contract has no allowlist.

It works with browser wallets, and with phone wallets such as Trust through WalletConnect when `VITE_WALLETCONNECT_PROJECT_ID` is set. That's a free project id from [Reown](https://dashboard.reown.com), and the site's domain has to be on the project's allowlist. If the contract's ABI changes, run `forge build` and then `yarn sync-abi` in `web/`.

### Hosting

The page is on DigitalOcean App Platform, in the SweepStake project on the Block 52 team: https://sweepstake-6wo88.ondigitalocean.app

It builds from the branch named in `.do/app.yaml`, and pushing doesn't redeploy it. To point it at the contract, set `VITE_SWEEP_ADDRESS` in that file, and `VITE_CHAIN` if it isn't on mainnet, then apply it. `VITE_TESTNET_SWEEP_ADDRESS` is the test contract behind `?testnet=true`:

```sh
doctl --context block52 apps update bca3bf67-c831-47a1-b3be-4cac0e29100f --spec .do/app.yaml
```

To redeploy after pushing changes, run `doctl --context block52 apps create-deployment bca3bf67-c831-47a1-b3be-4cac0e29100f --force-rebuild`. Applying the spec alone can rebuild an older commit, so run this afterwards too if the code has changed. Always pass `--context block52`, because `doctl`'s default context may be a different team.

## Race day

These are all owner calls. Add `--rpc-url $ETH_RPC_URL --account <keystore>` to each `cast send`.

```sh
# Scratchings close at 7:30am AEDT. Scratch any withdrawn horses. This sends their holders' money back
# straight away and can't be undone, so check the name first.
cast call $SWEEP "horseName(uint256)(string)" <index> --rpc-url $ETH_RPC_URL
cast send $SWEEP "scratch(uint256)" <index>

# From 3:20pm AEDT (2:20pm Brisbane), once the official result is in: check the name again.
# This can't be undone either, and it reverts if you're early.
cast call $SWEEP "horseName(uint256)(string)" <index> --rpc-url $ETH_RPC_URL
cast send $SWEEP "settle(uint256)" <index>
```
