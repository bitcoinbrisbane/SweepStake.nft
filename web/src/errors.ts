import {
  BaseError,
  ChainMismatchError,
  ContractFunctionRevertedError,
  InsufficientFundsError,
  UserRejectedRequestError,
  WaitForTransactionReceiptTimeoutError,
} from "viem";

const REVERTS: Record<string, string> = {
  EntriesClosed: "Entries have closed.",
  SweepFull: "That sweep has just sold out.",
  WrongState: "That sweep isn't taking entries any more.",
  NothingToClaim: "There's nothing left to claim on this ticket.",
  NotYourTicket: "That ticket isn't in this wallet.",
};

/** True if the sweep contract itself refused, rather than, say, USDT finding no allowance. USDT's reverts carry no error data. */
export function isSweepRevert(err: unknown): boolean {
  if (!(err instanceof BaseError)) return false;
  return !!err.walk((e) => e instanceof ContractFunctionRevertedError && e.data !== undefined);
}

/** Turns whatever a wallet, RPC or the contract threw into one sentence for the page. */
export function friendlyError(err: unknown): string {
  if (err instanceof BaseError) {
    if (err.walk((e) => e instanceof UserRejectedRequestError)) return "You cancelled that in your wallet.";
    if (err.walk((e) => e instanceof InsufficientFundsError)) return "You need a little more ETH to pay for gas.";
    if (err.walk((e) => e instanceof ChainMismatchError)) return "Switch your wallet to Ethereum and try again.";
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
    return /user (rejected|denied)/i.test(err.message) ? "You cancelled that in your wallet." : err.message;
  }
  return "Something went wrong. Please try again.";
}
