import type { CSSProperties } from "react";
import { amountLabel, feeLabel, SweepState, ticketNumber, type Mine, type Overview, type Progress, type Sweep, type Token } from "./chain";
import { CHAIN, EXPLORER } from "./config";
import type { WalletState } from "./wallet";

export type Message = { tone: "good" | "bad"; text: string };

// The same colours as the NFT art.
export const TIER_COLOURS = ["var(--bronze)", "var(--silver)", "var(--gold)"];

export function ProgressLine({ progress }: { progress: Progress }) {
  const { step, of, title, phase, hash } = progress;
  return (
    <p className="progress" role="status">
      {of > 1 && <span className="progress-step">Step {step} of {of}</span>}
      <span>
        {title}. {phase === "wallet" ? "Confirm in your wallet." : "Waiting for the network…"}
      </span>
      {hash && (
        <a href={`${EXPLORER}/tx/${hash}`} target="_blank" rel="noreferrer">
          View transaction
        </a>
      )}
    </p>
  );
}

function outcome(sweep: Sweep, token: Token): string {
  if (sweep.state === SweepState.Settled) {
    return `Ticket #${ticketNumber(sweep.winningTicket)} won ${amountLabel(sweep.pool, token)}`;
  }
  if (sweep.state === SweepState.Cancelled) {
    return sweep.ticketCount ? "Cancelled. Tickets can claim a refund." : "No entries";
  }
  if (sweep.state === SweepState.Drawn) return "Drawn. Every NFT ticket has its horse.";
  return "";
}

type ButtonState = { label: string; disabled?: boolean; onClick?: () => void };

export function SweepCard(props: {
  sweep: Sweep;
  overview: Overview;
  closed: boolean;
  wallet: WalletState;
  mine: Mine | null;
  busy: boolean;
  active: boolean;
  progress: Progress | null;
  message: Message | null;
  onBuy: (sweep: Sweep) => void;
  onConnect: () => void;
  onSwitch: () => void;
}) {
  const { sweep, overview, closed, wallet, mine, busy, active, progress, message, onBuy, onConnect, onSwitch } = props;
  const { token } = overview;
  const capacity = Math.max(overview.activeHorses, sweep.ticketCount);
  const full = sweep.ticketCount >= overview.activeHorses;
  const open = sweep.state === SweepState.Open && !closed && !full;

  function button(): ButtonState | null {
    if (sweep.state !== SweepState.Open) return null;
    if (closed) return { label: "Entries closed", disabled: true };
    if (full) return { label: "Sold out", disabled: true };
    if (!wallet.account) return { label: "Connect wallet to buy", onClick: onConnect };
    if (!wallet.onRightChain) return { label: `Switch to ${CHAIN.name}`, onClick: onSwitch };
    if (active) return { label: "Working…", disabled: true };
    if (!mine) return { label: "Checking your balance…", disabled: true };
    if (mine.balance < sweep.fee) return { label: `You need ${amountLabel(sweep.fee, token)}`, disabled: true };
    if (mine.eth === 0n) return { label: "You need ETH for gas", disabled: true };
    return { label: "Buy an NFT ticket", disabled: busy, onClick: () => onBuy(sweep) };
  }

  const action = button();
  const result = outcome(sweep, token);

  return (
    <article className="sweep" style={{ "--tier": TIER_COLOURS[sweep.id] ?? "var(--gold)" } as CSSProperties}>
      <h2 className="sweep-fee">{feeLabel(sweep.fee, token)}</h2>
      <p className="sweep-sub">{amountLabel(sweep.fee, token)} per NFT ticket</p>

      <div className="ticks" aria-hidden="true">
        {Array.from({ length: capacity }, (_, i) => (
          <span key={i} className={i < sweep.ticketCount ? "tick tick-sold" : "tick"} />
        ))}
      </div>

      <dl className="sweep-facts">
        <div>
          <dt>Sold</dt>
          <dd>
            {sweep.ticketCount} of {capacity}
          </dd>
        </div>
        <div>
          <dt>Pool</dt>
          <dd>{amountLabel(sweep.pool, token)}</dd>
        </div>
      </dl>

      {result && <p className="sweep-result">{result}</p>}

      {action && (
        <button className="buy-button" disabled={action.disabled} onClick={action.onClick}>
          {action.label}
        </button>
      )}

      {open && active && !progress && <p className="progress" role="status">Getting ready…</p>}
      {active && progress && <ProgressLine progress={progress} />}
      {message && (
        <p className={`message message-${message.tone}`} role={message.tone === "bad" ? "alert" : "status"}>
          {message.text}
        </p>
      )}
    </article>
  );
}
