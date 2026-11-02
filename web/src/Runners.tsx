import type { CSSProperties } from "react";
import { feeLabel, SweepState, ticketNumber, type Overview, type Runner, type Sweep, type Ticket } from "./chain";
import { TIER_COLOURS } from "./SweepCard";

function Holder({ runner, sweep, mine }: { runner: Runner; sweep: Sweep; mine: Set<bigint> }) {
  if (sweep.state === SweepState.Open) return <span title="Not drawn yet">·</span>;
  const ticket = runner.tickets[sweep.id];
  if (!ticket) return <span title="Nobody in this sweep drew this horse">–</span>;
  if (mine.has(ticket)) return <strong className="runner-you">You</strong>;
  return <span title={`Ticket ${ticketNumber(ticket)}`}>#{ticketNumber(ticket)}</span>;
}

/** Every horse, and who holds it in each sweep. Horses are only handed out at the draw. */
export function Runners({ overview, myTickets }: { overview: Overview; myTickets: Ticket[] }) {
  const { runners, sweeps, token, winningHorse } = overview;
  const mine = new Set(myTickets.map((t) => t.id));
  const anyDrawn = sweeps.some((s) => s.state !== SweepState.Open);

  return (
    <section className="runners">
      <h2>The runners</h2>
      <p className="muted">
        {anyDrawn
          ? "A number is the NFT ticket holding that horse in that sweep. A dash means nobody in that sweep drew it, and a dot means that sweep hasn't been drawn yet."
          : "You buy an NFT ticket, not a horse. Each ticket gets a random horse when entries close, and this table fills in then."}
      </p>
      <table className="runner-table">
        <thead>
          <tr>
            <th scope="col">Horse</th>
            {sweeps.map((s) => (
              <th
                key={s.id}
                scope="col"
                className="runner-sweep"
                style={{ "--tier": TIER_COLOURS[s.id] ?? "var(--gold)" } as CSSProperties}
              >
                {feeLabel(s.fee, token)}
              </th>
            ))}
          </tr>
        </thead>
        <tbody>
          {runners.map((runner) => {
            const won = winningHorse === runner.index;
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
                {sweeps.map((s) => (
                  <td
                    key={s.id}
                    className="runner-sweep"
                    style={{ "--tier": TIER_COLOURS[s.id] ?? "var(--gold)" } as CSSProperties}
                  >
                    <Holder runner={runner} sweep={s} mine={mine} />
                  </td>
                ))}
              </tr>
            );
          })}
        </tbody>
      </table>
    </section>
  );
}
