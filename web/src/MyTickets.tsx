import { usdtLabel, type Progress, type Ticket } from "./chain";
import { EXPLORER, SWEEP_ADDRESS } from "./config";
import { ProgressLine, type Message } from "./SweepCard";

export function MyTickets(props: {
  tickets: Ticket[] | null;
  canClaim: boolean;
  busy: boolean;
  activeTicket: bigint | null;
  progress: Progress | null;
  message: (Message & { ticketId: bigint }) | null;
  onClaim: (ticket: Ticket) => void;
}) {
  const { tickets, canClaim, busy, activeTicket, progress, message, onClaim } = props;

  return (
    <section className="tickets">
      <h2>Your tickets</h2>
      {tickets === null ? (
        <p className="muted">Looking for your tickets…</p>
      ) : tickets.length === 0 ? (
        <p className="muted">No tickets in this wallet yet.</p>
      ) : (
        <ul className="ticket-grid">
          {tickets.map((ticket) => {
            const prize = ticket.status.startsWith("Winner");
            const isActive = activeTicket === ticket.id;
            return (
              <li key={ticket.id.toString()} className="ticket">
                <img src={ticket.image} alt={`Sweep ticket ${ticket.number}: ${ticket.horse}. ${ticket.status}.`} />
                {ticket.claimable > 0n && (
                  <button className="buy-button" disabled={busy || !canClaim} onClick={() => onClaim(ticket)}>
                    {isActive
                      ? "Working…"
                      : `Claim ${usdtLabel(ticket.claimable)} ${prize ? "prize" : "refund"}`}
                  </button>
                )}
                {isActive && progress && <ProgressLine progress={progress} />}
                {message?.ticketId === ticket.id && (
                  <p className={`message message-${message.tone}`} role={message.tone === "bad" ? "alert" : "status"}>
                    {message.text}
                  </p>
                )}
                <a
                  className="ticket-link"
                  href={`${EXPLORER}/nft/${SWEEP_ADDRESS}/${ticket.id}`}
                  target="_blank"
                  rel="noreferrer"
                >
                  View NFT
                </a>
              </li>
            );
          })}
        </ul>
      )}
    </section>
  );
}
