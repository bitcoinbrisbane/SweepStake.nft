import { encodeFunctionData, formatUnits, parseAbi, parseEventLogs, type Account, type Address, type Chain, type Hash, type Transport, type WalletClient } from "viem";
import { sweepAbi } from "./abi/sweep";
import { tokenAbi } from "./abi/token";
import { artClient, publicClient, SWEEP_ADDRESS } from "./config";
import { isSweepRevert } from "./errors";

const sweep = { address: SWEEP_ADDRESS, abi: sweepAbi } as const;

export const SweepState = { Open: 0, Settled: 1, Cancelled: 2 } as const;

export type Token = { address: Address; symbol: string; decimals: number };

export type Sweep = {
  id: number;
  fee: bigint;
  state: number;
  ticketCount: number;
  winningTicket: bigint;
  pool: bigint;
  /** How many more tickets it can sell: the horses still in its hat that are running. */
  available: number;
  /** Every ticket sold in this sweep, and who owns that NFT right now. */
  tickets: { id: bigint; owner: Address }[];
};

export type Runner = {
  index: number;
  number: number;
  name: string;
  image: string;
  scratched: boolean;
  /** The ticket holding this horse in each sweep, by sweep id. 0n if none. */
  tickets: bigint[];
};

export type Overview = {
  token: Token;
  entriesClose: number;
  resultsOpen: number;
  winningHorse: number | null;
  sweeps: Sweep[];
  runners: Runner[];
};

export type Ticket = {
  id: bigint;
  sweepId: number;
  number: number;
  image: string;
  horse: string;
  status: string;
  claimable: bigint;
  claimableLabel: string;
};

export type Mine = { token: Token; tickets: Ticket[]; balance: bigint; eth: bigint };

export type Wallet = WalletClient<Transport, Chain, Account>;

export type Progress = {
  step: number;
  of: number;
  title: string;
  phase: "wallet" | "network";
  hash?: Hash;
};

export const amountLabel = (amount: bigint, token: Token) => `${formatUnits(amount, token.decimals)} ${token.symbol}`;
export const feeLabel = (fee: bigint, token: Token) => `$${formatUnits(fee, token.decimals)}`;

/** Mirrors the contract's ticket ids: sweep 0's tickets are 1001-1024, sweep 1's 2001-2024, and so on. */
const ID_BASE = 1000;
const ticketId = (sweepId: number, number: number) => BigInt((sweepId + 1) * ID_BASE + number);
export const ticketNumber = (id: bigint) => Number(id) % ID_BASE;
export const shortAddress = (address: Address) => `${address.slice(0, 6)}…${address.slice(-4)}`;

/** Remembers something that never changes onchain, but tries again next time if loading it failed. */
function once<T>(load: () => Promise<T>) {
  let loaded: Promise<T> | null = null;
  return () => {
    loaded ??= load().catch((err: unknown) => {
      loaded = null;
      throw err;
    });
    return loaded;
  };
}

// ---------------------------------------------------------------- reads

const loadToken = once(async (): Promise<Token> => {
  const address = await publicClient.readContract({ ...sweep, functionName: "token" });
  const [symbol, decimals] = await Promise.all([
    publicClient.readContract({ address, abi: tokenAbi, functionName: "symbol" }),
    publicClient.readContract({ address, abi: tokenAbi, functionName: "decimals" }),
  ]);
  return { address, symbol, decimals };
});

const loadField = once(async () => {
  const count = await publicClient.readContract({ ...sweep, functionName: "horseCount" });
  return Promise.all(
    Array.from({ length: Number(count) }, async (_, index) => {
      const args = [BigInt(index)] as const;
      const [name, image] = await Promise.all([
        publicClient.readContract({ ...sweep, functionName: "horseName", args }),
        publicClient.readContract({ ...sweep, functionName: "horseImage", args }),
      ]);
      return { index, number: index + 1, name, image };
    }),
  );
});

/** The contract isn't enumerable, but there are at most 72 tickets, so this asks who owns each one. */
async function loadSweeps(): Promise<Sweep[]> {
  const count = await publicClient.readContract({ ...sweep, functionName: "sweepCount" });
  return Promise.all(
    Array.from({ length: Number(count) }, async (_, id) => {
      const args = [BigInt(id)] as const;
      const [[fee, state, ticketCount, winningTicket], pool, available] = await Promise.all([
        publicClient.readContract({ ...sweep, functionName: "sweeps", args }),
        publicClient.readContract({ ...sweep, functionName: "prizePool", args }),
        publicClient.readContract({ ...sweep, functionName: "availableHorses", args }),
      ]);
      const tickets = await Promise.all(
        Array.from({ length: ticketCount }, async (_, i) => {
          const ticket = ticketId(id, i + 1);
          const owner = await publicClient.readContract({ ...sweep, functionName: "ownerOf", args: [ticket] });
          return { id: ticket, owner };
        }),
      );
      return { id, fee, state, ticketCount, winningTicket, pool, available: Number(available), tickets };
    }),
  );
}

async function loadRunners(sweeps: Sweep[]): Promise<Runner[]> {
  const field = await loadField();
  return Promise.all(
    field.map(async (horse) => {
      const index = BigInt(horse.index);
      const [scratched, tickets] = await Promise.all([
        publicClient.readContract({ ...sweep, functionName: "scratched", args: [index] }),
        Promise.all(
          sweeps.map((s) =>
            publicClient.readContract({ ...sweep, functionName: "horseTicket", args: [BigInt(s.id), index] }),
          ),
        ),
      ]);
      return { ...horse, scratched, tickets };
    }),
  );
}

export async function loadOverview(): Promise<Overview> {
  const [token, entriesClose, resultsOpen, raceSettled, winningHorse, sweeps] = await Promise.all([
    loadToken(),
    publicClient.readContract({ ...sweep, functionName: "entriesClose" }),
    publicClient.readContract({ ...sweep, functionName: "resultsOpen" }),
    publicClient.readContract({ ...sweep, functionName: "raceSettled" }),
    publicClient.readContract({ ...sweep, functionName: "winningHorse" }),
    loadSweeps(),
  ]);
  return {
    token,
    entriesClose: Number(entriesClose),
    resultsOpen: Number(resultsOpen),
    winningHorse: raceSettled ? Number(winningHorse) : null,
    sweeps,
    runners: await loadRunners(sweeps),
  };
}

type Metadata = { image: string; attributes: { trait_type: string; value: string }[] };

/** A ticket's image only changes when its status does, so don't redraw it on every refresh. */
const metadataByStatus = new Map<string, Metadata>();

async function loadMetadata(id: bigint, status: string): Promise<Metadata> {
  const key = `${id}:${status}`;
  const known = metadataByStatus.get(key);
  if (known) return known;
  const uri = await artClient.readContract({ ...sweep, functionName: "tokenURI", args: [id] });
  const metadata = JSON.parse(atob(uri.split(",")[1])) as Metadata;
  metadataByStatus.set(key, metadata);
  return metadata;
}

async function loadTicket(id: bigint, sweepId: number, token: Token): Promise<Ticket> {
  const args = [id] as const;
  const [claimable, status] = await Promise.all([
    publicClient.readContract({ ...sweep, functionName: "claimable", args }),
    publicClient.readContract({ ...sweep, functionName: "ticketStatus", args }),
  ]);
  const metadata = await loadMetadata(id, status);
  const horse = metadata.attributes.find((a) => a.trait_type === "Horse")?.value ?? "";
  return {
    id,
    sweepId,
    number: ticketNumber(id),
    image: metadata.image,
    horse,
    status,
    claimable,
    claimableLabel: amountLabel(claimable, token),
  };
}

export async function loadMine(account: Address): Promise<Mine> {
  const token = await loadToken();
  const [sweeps, balance, eth] = await Promise.all([
    loadSweeps(),
    publicClient.readContract({ address: token.address, abi: tokenAbi, functionName: "balanceOf", args: [account] }),
    publicClient.getBalance({ address: account }),
  ]);
  const mine = sweeps.flatMap((s) =>
    s.tickets.filter((t) => t.owner === account).map((t) => ({ id: t.id, sweepId: s.id })),
  );
  const tickets = await Promise.all(mine.map(({ id, sweepId }) => loadTicket(id, sweepId, token)));
  return { token, tickets, balance, eth };
}

// ---------------------------------------------------------------- local test chain

const LOCAL_DEV_ACCOUNT = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"; // anvil's first unlocked account
const localFunded = new Set<Address>();

/** Local chain only: gives a wallet test ETH and test tokens the first time it connects, so it can try buying. */
export async function fundLocalWallet(account: Address) {
  if (localFunded.has(account)) return;
  localFunded.add(account);
  const request = publicClient.request as unknown as (args: { method: string; params: unknown[] }) => Promise<unknown>;
  const token = await loadToken();
  if ((await publicClient.getBalance({ address: account })) === 0n) {
    await request({ method: "anvil_setBalance", params: [account, "0x8ac7230489e80000"] }); // 10 ETH
  }
  const balance = await publicClient.readContract({
    address: token.address,
    abi: tokenAbi,
    functionName: "balanceOf",
    args: [account],
  });
  if (balance > 0n) return;
  const data = encodeFunctionData({
    abi: parseAbi(["function mint(address to, uint256 amount)"]),
    args: [account, 100n * 10n ** BigInt(token.decimals)],
  });
  await request({ method: "eth_sendTransaction", params: [{ from: LOCAL_DEV_ACCOUNT, to: token.address, data }] });
}

// ---------------------------------------------------------------- writes

const readAllowance = (token: Token, owner: Address) =>
  publicClient.readContract({
    address: token.address,
    abi: tokenAbi,
    functionName: "allowance",
    args: [owner, SWEEP_ADDRESS],
  });

async function confirmed(hash: Hash) {
  const receipt = await publicClient.waitForTransactionReceipt({ hash });
  if (receipt.status !== "success") throw new Error("That transaction failed on the network.");
  return receipt;
}

/** Public RPCs can lag behind the block we just saw, and the next step's simulation needs this to be visible. */
async function waitForAllowance(token: Token, owner: Address, amount: bigint) {
  for (let tries = 0; tries < 15; tries++) {
    if ((await readAllowance(token, owner)) === amount) return;
    await new Promise((resolve) => setTimeout(resolve, 2000));
  }
}

async function approve(
  wallet: Wallet,
  token: Token,
  amount: bigint,
  report: (phase: Progress["phase"], hash?: Hash) => void,
) {
  report("wallet");
  const { request } = await publicClient.simulateContract({
    address: token.address,
    abi: tokenAbi,
    functionName: "approve",
    args: [SWEEP_ADDRESS, amount],
    account: wallet.account,
  });
  const hash = await wallet.writeContract(request);
  report("network", hash);
  await confirmed(hash);
  await waitForAllowance(token, wallet.account.address, amount);
}

const simulateEnter = (wallet: Wallet, target: Sweep) =>
  publicClient.simulateContract({
    ...sweep,
    functionName: "enter",
    args: [BigInt(target.id)],
    account: wallet.account,
  });

/**
 * Buys one ticket, returning the horse it pulled from the hat. Approves the token first if needed. USDT refuses to change one non-zero allowance
 * straight to another, so a smaller leftover approval has to be cleared first. An approval that's
 * already big enough, such as from an attempt abandoned part way, is reused.
 */
export async function buyTicket(wallet: Wallet, target: Sweep, onProgress: (p: Progress) => void) {
  const token = await loadToken();

  // If the sweep has closed or sold out since the page last looked, say so before anyone pays gas to
  // approve. Any other failure here is just the allowance that the steps below are about to set.
  await simulateEnter(wallet, target).catch((err: unknown) => {
    if (isSweepRevert(err)) throw err;
  });

  const allowance = await readAllowance(token, wallet.account.address);
  const needsApproval = allowance < target.fee;
  const needsReset = needsApproval && allowance > 0n;
  const of = 1 + (needsApproval ? 1 : 0) + (needsReset ? 1 : 0);
  let step = 0;

  const reporter = (title: string) => {
    step += 1;
    const current = step;
    return (phase: Progress["phase"], hash?: Hash) => onProgress({ step: current, of, title, phase, hash });
  };

  if (needsReset) await approve(wallet, token, 0n, reporter(`Clear your old ${token.symbol} approval`));
  if (needsApproval) await approve(wallet, token, target.fee, reporter(`Allow ${amountLabel(target.fee, token)}`));

  const report = reporter("Buy your NFT ticket");
  report("wallet");
  const { request } = await simulateEnter(wallet, target);
  // Gas use depends on which horse comes out of the hat, so an exact estimate can run out and fail.
  // Asking for half as much again covers that, and whatever isn't used is refunded.
  const estimate = await publicClient.estimateContractGas({
    ...sweep,
    functionName: "enter",
    args: [BigInt(target.id)],
    account: wallet.account,
  });
  const hash = await wallet.writeContract({ ...request, gas: (estimate * 3n) / 2n });
  report("network", hash);
  const receipt = await confirmed(hash);
  const [pulled] = parseEventLogs({ abi: sweepAbi, logs: receipt.logs, eventName: "HorseAssigned" });
  return pulled?.args.name ?? null;
}

/** Test chains only: mints free test tokens to the connected wallet, which pays its own gas. */
export async function mintTestTokens(wallet: Wallet) {
  const token = await loadToken();
  const { request } = await publicClient.simulateContract({
    address: token.address,
    abi: parseAbi(["function mint(address to, uint256 amount)"]),
    functionName: "mint",
    args: [wallet.account.address, 100n * 10n ** BigInt(token.decimals)],
    account: wallet.account,
  });
  await confirmed(await wallet.writeContract(request));
}

export async function claimTicket(wallet: Wallet, id: bigint, onProgress: (p: Progress) => void) {
  const token = await loadToken();
  const title = `Claim your ${token.symbol}`;
  onProgress({ step: 1, of: 1, title, phase: "wallet" });
  const { request } = await publicClient.simulateContract({
    ...sweep,
    functionName: "claim",
    args: [id],
    account: wallet.account,
  });
  const hash = await wallet.writeContract(request);
  onProgress({ step: 1, of: 1, title, phase: "network", hash });
  await confirmed(hash);
}
