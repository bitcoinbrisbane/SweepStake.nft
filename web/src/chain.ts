import { formatUnits, type Account, type Address, type Chain, type Hash, type Transport, type WalletClient } from "viem";
import { sweepAbi } from "./abi/sweep";
import { usdtAbi } from "./abi/usdt";
import { publicClient, SWEEP_ADDRESS, USDT_ADDRESS, USDT_DECIMALS } from "./config";
import { isSweepRevert } from "./errors";

const sweep = { address: SWEEP_ADDRESS, abi: sweepAbi } as const;
const usdt = { address: USDT_ADDRESS, abi: usdtAbi } as const;

export const SweepState = { Open: 0, Drawn: 1, Settled: 2, Cancelled: 3 } as const;

export type Sweep = {
  id: number;
  fee: bigint;
  state: number;
  ticketCount: number;
  winningTicket: bigint;
  pool: bigint;
};

export type Overview = {
  entriesClose: number;
  activeHorses: number;
  winner: string | null;
  sweeps: Sweep[];
};

export type Ticket = {
  id: bigint;
  sweepId: number;
  number: number;
  image: string;
  horse: string;
  status: string;
  claimable: bigint;
};

export type Mine = { tickets: Ticket[]; usdt: bigint; eth: bigint };

export type Wallet = WalletClient<Transport, Chain, Account>;

export type Progress = {
  step: number;
  of: number;
  title: string;
  phase: "wallet" | "network";
  hash?: Hash;
};

export const usdtLabel = (amount: bigint) => `${formatUnits(amount, USDT_DECIMALS)} USDT`;
export const feeLabel = (fee: bigint) => `$${formatUnits(fee, USDT_DECIMALS)}`;

/** Mirrors the contract's ticket ids: sweep 0's tickets are 1001-1024, sweep 1's 2001-2024, and so on. */
const ID_BASE = 1000;
const ticketId = (sweepId: number, number: number) => BigInt((sweepId + 1) * ID_BASE + number);

// ---------------------------------------------------------------- reads

async function loadSweeps(): Promise<Sweep[]> {
  const count = await publicClient.readContract({ ...sweep, functionName: "sweepCount" });
  return Promise.all(
    Array.from({ length: Number(count) }, async (_, id) => {
      const args = [BigInt(id)] as const;
      const [[fee, state, ticketCount, winningTicket], pool] = await Promise.all([
        publicClient.readContract({ ...sweep, functionName: "sweeps", args }),
        publicClient.readContract({ ...sweep, functionName: "prizePool", args }),
      ]);
      return { id, fee, state, ticketCount, winningTicket, pool };
    }),
  );
}

export async function loadOverview(): Promise<Overview> {
  const [entriesClose, activeHorses, raceSettled, winningHorse, sweeps] = await Promise.all([
    publicClient.readContract({ ...sweep, functionName: "entriesClose" }),
    publicClient.readContract({ ...sweep, functionName: "activeHorses" }),
    publicClient.readContract({ ...sweep, functionName: "raceSettled" }),
    publicClient.readContract({ ...sweep, functionName: "winningHorse" }),
    loadSweeps(),
  ]);
  const winner = raceSettled
    ? await publicClient.readContract({ ...sweep, functionName: "horseName", args: [winningHorse] })
    : null;
  return { entriesClose: Number(entriesClose), activeHorses: Number(activeHorses), winner, sweeps };
}

async function loadTicket(id: bigint, sweepId: number): Promise<Ticket> {
  const args = [id] as const;
  const [uri, claimable, status] = await Promise.all([
    publicClient.readContract({ ...sweep, functionName: "tokenURI", args }),
    publicClient.readContract({ ...sweep, functionName: "claimable", args }),
    publicClient.readContract({ ...sweep, functionName: "ticketStatus", args }),
  ]);
  const metadata = JSON.parse(atob(uri.split(",")[1])) as {
    image: string;
    attributes: { trait_type: string; value: string }[];
  };
  const horse = metadata.attributes.find((a) => a.trait_type === "Horse")?.value ?? "";
  return { id, sweepId, number: Number(id) % ID_BASE, image: metadata.image, horse, status, claimable };
}

/** The contract isn't enumerable, but there are at most 72 tickets, so just ask who owns each one. */
export async function loadMine(account: Address): Promise<Mine> {
  const [sweeps, usdtBalance, eth] = await Promise.all([
    loadSweeps(),
    publicClient.readContract({ ...usdt, functionName: "balanceOf", args: [account] }),
    publicClient.getBalance({ address: account }),
  ]);
  const all = sweeps.flatMap((s) =>
    Array.from({ length: s.ticketCount }, (_, i) => ({ id: ticketId(s.id, i + 1), sweepId: s.id })),
  );
  const owners = await Promise.all(
    all.map(({ id }) => publicClient.readContract({ ...sweep, functionName: "ownerOf", args: [id] })),
  );
  const mine = all.filter((_, i) => owners[i] === account);
  const tickets = await Promise.all(mine.map(({ id, sweepId }) => loadTicket(id, sweepId)));
  return { tickets, usdt: usdtBalance, eth };
}

// ---------------------------------------------------------------- writes

const readAllowance = (owner: Address) =>
  publicClient.readContract({ ...usdt, functionName: "allowance", args: [owner, SWEEP_ADDRESS] });

async function confirmed(hash: Hash) {
  const receipt = await publicClient.waitForTransactionReceipt({ hash });
  if (receipt.status !== "success") throw new Error("That transaction failed on the network.");
}

/** Public RPCs can lag behind the block we just saw, and the next step's simulation needs this to be visible. */
async function waitForAllowance(owner: Address, amount: bigint) {
  for (let tries = 0; tries < 15; tries++) {
    if ((await readAllowance(owner)) === amount) return;
    await new Promise((resolve) => setTimeout(resolve, 2000));
  }
}

async function approve(wallet: Wallet, amount: bigint, report: (phase: Progress["phase"], hash?: Hash) => void) {
  report("wallet");
  const { request } = await publicClient.simulateContract({
    ...usdt,
    functionName: "approve",
    args: [SWEEP_ADDRESS, amount],
    account: wallet.account,
  });
  const hash = await wallet.writeContract(request);
  report("network", hash);
  await confirmed(hash);
  await waitForAllowance(wallet.account.address, amount);
}

const simulateEnter = (wallet: Wallet, target: Sweep) =>
  publicClient.simulateContract({
    ...sweep,
    functionName: "enter",
    args: [BigInt(target.id)],
    account: wallet.account,
  });

/**
 * Buys one ticket, approving USDT first if needed. USDT refuses to change one non-zero allowance
 * straight to another, so a smaller leftover approval has to be cleared first. An approval that's
 * already big enough, such as from an attempt abandoned part way, is reused.
 */
export async function buyTicket(wallet: Wallet, target: Sweep, onProgress: (p: Progress) => void) {
  // If the sweep has closed or sold out since the page last looked, say so before anyone pays gas to
  // approve. Any other failure here is just the allowance that the steps below are about to set.
  await simulateEnter(wallet, target).catch((err: unknown) => {
    if (isSweepRevert(err)) throw err;
  });

  const allowance = await readAllowance(wallet.account.address);
  const needsApproval = allowance < target.fee;
  const needsReset = needsApproval && allowance > 0n;
  const of = 1 + (needsApproval ? 1 : 0) + (needsReset ? 1 : 0);
  let step = 0;

  const reporter = (title: string) => {
    step += 1;
    const current = step;
    return (phase: Progress["phase"], hash?: Hash) => onProgress({ step: current, of, title, phase, hash });
  };

  if (needsReset) await approve(wallet, 0n, reporter("Clear your old USDT approval"));
  if (needsApproval) await approve(wallet, target.fee, reporter(`Allow ${usdtLabel(target.fee)}`));

  const report = reporter("Buy your ticket");
  report("wallet");
  const { request } = await simulateEnter(wallet, target);
  const hash = await wallet.writeContract(request);
  report("network", hash);
  await confirmed(hash);
}

export async function claimTicket(wallet: Wallet, id: bigint, onProgress: (p: Progress) => void) {
  const title = "Claim your USDT";
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
