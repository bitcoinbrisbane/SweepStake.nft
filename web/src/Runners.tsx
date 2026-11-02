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

function note(sweep: Sweep, closed: boolean) {
  if (sweep.state === SweepState.Cancelled) return "This sweep was cancelled, so its NFT tickets can claim a refund.";
  const first = "Every NFT ticket pulls a random horse from the hat as soon as it's bought, and this shows who owns each one right now.";
  return `${first} A dash means ${sweep.state === SweepState.Open && !closed ? "that horse is still in the hat" : "nobody in this sweep drew it"}.`;
}

/** Every horse, and who owns the NFT holding it in the chosen sweep. It fills in as tickets sell. */
export function Runners({
  overview,
  sweepId,
  account,
  closed,
}: {
  overview: Overview;
  sweepId: number;
  account: Address | null;
  closed: boolean;
}) {
  const { runners, token, winningHorse } = overview;
  const sweep = overview.sweeps[sweepId];
  const owners = new Map(sweep.tickets.map((t) => [t.id, t.owner]));
  const style = { "--tier": TIER_COLOURS[sweep.id] ?? "var(--gold)" } as CSSProperties;

  return (
    <section className="runners" style={style}>
      <h2>
        The runners <span className="runners-sweep">{feeLabel(sweep.fee, token)} sweep</span>
      </h2>
      <p className="muted">{note(sweep, closed)}</p>

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
                <td className="runner-ticket">{ticket ? `#${ticketNumber(ticket)}` : "–"}</td>
                <td className="runner-owner">{owner ? <Owner owner={owner} account={account} /> : "–"}</td>
              </tr>
            );
          })}
        </tbody>
      </table>
    </section>
  );
}
