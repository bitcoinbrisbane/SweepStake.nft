import {
  BaseError,
  ChainMismatchError,
  ContractFunctionRevertedError,
  InsufficientFundsError,
  UserRejectedRequestError,
  WaitForTransactionReceiptTimeoutError,
} from "viem";
import { CHAIN } from "./config";

const REVERTS: Record<string, string> = {
  EntriesClosed: "Entries have closed.",
  SweepFull: "That sweep has just sold out.",
  WalletsOnly: "This sweep only takes ordinary wallets, not smart contract wallets.",
  WrongState: "That sweep isn't taking entries any more.",
  NothingToClaim: "There's nothing left to claim on this ticket.",
  NotYourTicket: "That ticket isn't in this wallet.",
};

const SWEEP_REFUSALS = new Set(["EntriesClosed", "SweepFull", "WrongState", "WalletsOnly"]);

/**
 * True if the sweep itself refused an entry. Checking the name matters because tokens complain about a
 * missing allowance in their own ways: USDT reverts with no reason, and USDC with a message.
 */
export function isSweepRevert(err: unknown): boolean {
  if (!(err instanceof BaseError)) return false;
  const revert = err.walk((e) => e instanceof ContractFunctionRevertedError);
  return revert instanceof ContractFunctionRevertedError && SWEEP_REFUSALS.has(revert.data?.errorName ?? "");
}

/** Turns whatever a wallet, RPC or the contract threw into one sentence for the page. */
export function friendlyError(err: unknown): string {
  // Connecting and switching networks go straight to the wallet, so these aren't wrapped by viem.
  if ((err as { code?: number } | null)?.code === 4001) return "You cancelled that in your wallet.";
  if (err instanceof BaseError) {
    if (err.walk((e) => e instanceof UserRejectedRequestError)) return "You cancelled that in your wallet.";
    if (err.walk((e) => e instanceof InsufficientFundsError)) return "You need a little more ETH to pay for gas.";
    if (err.walk((e) => e instanceof ChainMismatchError)) return `Switch your wallet to ${CHAIN.name} and try again.`;
    if (err.walk((e) => e instanceof WaitForTransactionReceiptTimeoutError)) {
      return "This is taking a while. Check your wallet to see how the transaction is going.";
    }
    const revert = err.walk((e) => e instanceof ContractFunctionRevertedError);
    if (revert instanceof ContractFunctionRevertedError) {
      const known = revert.data?.errorName && REVERTS[revert.data.errorName];
      if (known) return known;
    }
    if (/user (rejected|denied)/i.test(err.message)) return "You cancelled that in your wallet.";
    return err.shortMessage;
  }
  if (err instanceof Error) {
    // WalletConnect says "Connection request reset" when someone closes its window.
    return /user (rejected|denied)|connection request reset/i.test(err.message) ? "You cancelled that in your wallet." : err.message;
  }
  return "Something went wrong. Please try again.";
}
