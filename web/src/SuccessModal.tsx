import { useEffect, useRef, type CSSProperties } from "react";
import { TIER_COLOURS } from "./SweepCard";

export type Purchase = {
  ticketId: bigint;
  sweepId: number;
  horse: string;
  fee: string;
  /** Null until the NFT's image has loaded, or if it couldn't be. */
  image: string | null;
};

/** Shown once a purchase goes through. A native dialog handles focus and the Escape key. */
export function SuccessModal({ purchase, onClose }: { purchase: Purchase; onClose: () => void }) {
  const dialog = useRef<HTMLDialogElement>(null);

  useEffect(() => {
    if (dialog.current && !dialog.current.open) dialog.current.showModal();
  }, []);

  const post = `I just bought an NFT ticket in the ${purchase.fee} Melbourne Cup sweep and pulled ${purchase.horse} from the hat! 🐎🏆`;
  const postUrl = `https://x.com/intent/post?text=${encodeURIComponent(post)}&url=${encodeURIComponent(window.location.href)}`;

  return (
    <dialog
      ref={dialog}
      className="success"
      style={{ "--tier": TIER_COLOURS[purchase.sweepId] ?? "var(--gold)" } as CSSProperties}
      onClose={onClose}
      onClick={(event) => {
        // A click on the dialog itself, rather than what's inside it, is a click on the backdrop.
        if (event.target === dialog.current) dialog.current.close();
      }}
    >
      <div className="success-body">
        <h2>Success!</h2>
        {purchase.image ? (
          <img src={purchase.image} alt={`Your NFT ticket: ${purchase.horse}, token ${purchase.ticketId}.`} />
        ) : (
          <div className="success-art-placeholder" aria-hidden="true" />
        )}
        <p>
          You pulled <strong>{purchase.horse}</strong> from the hat.
        </p>
        <a className="buy-button" href={postUrl} target="_blank" rel="noreferrer">
          Post on X
        </a>
        <button type="button" className="link-button" onClick={() => dialog.current?.close()}>
          Close
        </button>
      </div>
    </dialog>
  );
}
