import type { CSSProperties } from "react";
import type { Address } from "viem";
import { feeLabel, shortAddress, SweepState, ticketNumber, type Overview, type Sweep } from "./chain";
import { EXPLORER } from "./config";
import { TIER_COLOURS } from "./SweepCard";

function Owner({ owner, account }: { owner: Address; account: Address | null }) {
  if (owner === account) return <strong className="runner-you">You</strong>;
  if (!EXPLORER) return <span title={owner}>{shortAddress(owner)}</span>;
  return (
    <a href={`${EXPLORER}/address/${owner}`} target="_blank" rel="noreferrer" title={owner}>
      {shortAddress(owner)}
    </a>
  );
}

function note(sweep: Sweep) {
  if (sweep.state === SweepState.Open) {
    return "You buy an NFT ticket, not a horse. Each ticket gets a random horse when entries close, and this table fills in then.";
  }
  if (sweep.state === SweepState.Cancelled) return "This sweep was cancelled, so its NFT tickets can claim a refund.";
  return "Each row shows the NFT ticket holding that horse in this sweep, and who owns that NFT right now. A dash means nobody in this sweep drew it.";
}

/** Every horse, and who owns the NFT holding it in the chosen sweep. Horses are only handed out at the draw. */
export function Runners({
  overview,
  sweepId,
  account,
}: {
  overview: Overview;
  sweepId: number;
  account: Address | null;
}) {
  const { runners, token, winningHorse } = overview;
  const sweep = overview.sweeps[sweepId];
  const owners = new Map(sweep.tickets.map((t) => [t.id, t.owner]));
  const undrawn = sweep.state === SweepState.Open;
  const style = { "--tier": TIER_COLOURS[sweep.id] ?? "var(--gold)" } as CSSProperties;

  return (
    <section className="runners" style={style}>
      <h2>
        The runners <span className="runners-sweep">{feeLabel(sweep.fee, token)} sweep</span>
      </h2>
      <p className="muted">{note(sweep)}</p>

      {undrawn && sweep.tickets.length > 0 && (
        <div className="sold">
          <h3>NFT tickets sold so far</h3>
          <ul>
            {sweep.tickets.map((t) => (
              <li key={t.id.toString()}>
                #{ticketNumber(t.id)} <Owner owner={t.owner} account={account} />
              </li>
            ))}
          </ul>
        </div>
      )}

      <table className="runner-table">
        <thead>
          <tr>
            <th scope="col">Horse</th>
            <th scope="col" className="runner-ticket">
              NFT
            </th>
            <th scope="col" className="runner-owner">
              NFT owner
            </th>
          </tr>
        </thead>
        <tbody>
          {runners.map((runner) => {
            const won = winningHorse === runner.index;
            const ticket = runner.tickets[sweep.id];
            const owner = owners.get(ticket);
            return (
              <tr key={runner.index} className={won ? "runner-winner" : runner.scratched ? "runner-scratched" : undefined}>
                <td>
                  <div className="runner-horse">
                    <img className="runner-art" src={runner.image} alt="" width={40} height={40} />
                    <span className="runner-no">{runner.number}</span>
                    <span className="runner-name">
                      {won && <span aria-label="Winner">🏆 </span>}
                      {runner.scratched ? <s>{runner.name}</s> : runner.name}
                      {runner.scratched && <small> Scratched</small>}
                    </span>
                  </div>
                </td>
                <td className="runner-ticket">{undrawn ? "·" : ticket ? `#${ticketNumber(ticket)}` : "–"}</td>
                <td className="runner-owner">{owner ? <Owner owner={owner} account={account} /> : undrawn ? "·" : "–"}</td>
              </tr>
            );
          })}
        </tbody>
      </table>
    </section>
  );
}
