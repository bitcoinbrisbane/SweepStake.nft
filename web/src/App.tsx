import { useCallback, useEffect, useState } from "react";
import {
  amountLabel,
  buyTicket,
  claimTicket,
  feeLabel,
  fundLocalWallet,
  loadMine,
  loadOverview,
  loadTicketImage,
  mintTestTokens,
  shortAddress,
  type Progress,
  type Sweep,
  type Ticket,
} from "./chain";
import { CHAIN, EXPLORER, isConfigured, IS_LOCAL, IS_TEST_MONEY, RACE_START, SWEEP_ADDRESS } from "./config";
import { friendlyError } from "./errors";
import { MyTickets } from "./MyTickets";
import { Runners } from "./Runners";
import { SuccessModal, type Purchase } from "./SuccessModal";
import { SweepCard, type Message } from "./SweepCard";
import { useNow, usePoll } from "./usePoll";
import { useWallet, type WalletOption } from "./wallet";

const POLL_MS = 15_000;

export default function App() {
  if (!isConfigured) {
    return (
      <main className="page">
        <section className="notice">
          <h1>Melbourne Cup Sweep</h1>
          <p>The sweep isn't open yet. Check back soon.</p>
          {import.meta.env.DEV && (
            <p className="muted">
              Set <code>VITE_SWEEP_ADDRESS</code> to the deployed address, and <code>VITE_CHAIN</code> if it isn't on Ethereum.
            </p>
          )}
        </section>
      </main>
    );
  }
  return <Sweepstake />;
}

function countdown(seconds: number) {
  const d = Math.floor(seconds / 86400);
  const h = Math.floor((seconds % 86400) / 3600);
  const m = Math.floor((seconds % 3600) / 60);
  const s = seconds % 60;
  return [d ? `${d}d` : "", d || h ? `${h}h` : "", `${m}m`, `${s}s`].filter(Boolean).join(" ");
}

const whenFormat = new Intl.DateTimeFormat(undefined, {
  weekday: "short",
  day: "numeric",
  month: "short",
  hour: "numeric",
  minute: "2-digit",
  timeZoneName: "short",
});
const when = (unix: number) => whenFormat.format(new Date(unix * 1000));

/** One wallet action at a time, because wallets queue their prompts and the steps would get confusing. */
type Action = { sweepId?: number; ticketId?: bigint; progress: Progress | null };

function Sweepstake() {
  const wallet = useWallet();
  const now = useNow();
  const overview = usePoll(loadOverview, POLL_MS);

  const { account } = wallet;
  const loadAccount = useCallback(() => (account ? loadMine(account) : Promise.resolve(null)), [account]);
  const mine = usePoll(loadAccount, POLL_MS);
  const refreshMine = mine.refresh;

  useEffect(() => {
    if (!IS_LOCAL || !account) return;
    fundLocalWallet(account)
      .then(() => refreshMine())
      .catch(() => {});
  }, [account, refreshMine]);

  const [selectedSweep, setSelectedSweep] = useState(0);
  const [purchase, setPurchase] = useState<Purchase | null>(null);

  const [picker, setPicker] = useState(false);
  const [walletError, setWalletError] = useState<string | null>(null);
  const [action, setAction] = useState<Action | null>(null);
  const [sweepMessage, setSweepMessage] = useState<(Message & { sweepId: number }) | null>(null);
  const [ticketMessage, setTicketMessage] = useState<(Message & { ticketId: bigint }) | null>(null);

  async function connectTo(option: WalletOption) {
    setWalletError(null);
    setPicker(false);
    try {
      await wallet.connect(option);
    } catch (err) {
      setWalletError(friendlyError(err));
    }
  }

  function requestConnect() {
    if (wallet.options.length === 1) void connectTo(wallet.options[0]);
    else setPicker(true);
  }

  async function switchChain() {
    setWalletError(null);
    try {
      await wallet.switchChain();
    } catch (err) {
      setWalletError(friendlyError(err));
    }
  }

  async function buy(target: Sweep) {
    if (!wallet.client) return;
    setSweepMessage(null);
    setSelectedSweep(target.id);
    setAction({ sweepId: target.id, progress: null });
    try {
      const bought = await buyTicket(wallet.client, target, (progress) => setAction({ sweepId: target.id, progress }));
      const text = bought ? `You're in. You pulled ${bought.horse} from the hat!` : "You're in. Your NFT ticket is below.";
      setSweepMessage({ sweepId: target.id, tone: "good", text });
      if (bought && overview.data) {
        const { ticketId, horse } = bought;
        setPurchase({ ticketId, sweepId: target.id, horse, fee: feeLabel(target.fee, overview.data.token), image: null });
        void loadTicketImage(ticketId).then((image) =>
          setPurchase((current) => (current?.ticketId === ticketId ? { ...current, image } : current)),
        );
      }
    } catch (err) {
      setSweepMessage({ sweepId: target.id, tone: "bad", text: friendlyError(err) });
    } finally {
      setAction(null);
      void overview.refresh();
      void mine.refresh();
    }
  }

  const [minting, setMinting] = useState(false);

  async function getTestTokens() {
    if (!wallet.client) return;
    setWalletError(null);
    setMinting(true);
    try {
      await mintTestTokens(wallet.client);
    } catch (err) {
      setWalletError(friendlyError(err));
    } finally {
      setMinting(false);
      void mine.refresh();
    }
  }

  async function claim(ticket: Ticket) {
    if (!wallet.client) return;
    setTicketMessage(null);
    setAction({ ticketId: ticket.id, progress: null });
    try {
      await claimTicket(wallet.client, ticket.id, (progress) => setAction({ ticketId: ticket.id, progress }));
      setTicketMessage({ ticketId: ticket.id, tone: "good", text: `${ticket.claimableLabel} is on its way to your wallet.` });
    } catch (err) {
      setTicketMessage({ ticketId: ticket.id, tone: "bad", text: friendlyError(err) });
    } finally {
      setAction(null);
      void overview.refresh();
      void mine.refresh();
    }
  }

  const data = overview.data;
  const closed = data ? now >= data.entriesClose : false;
  const winner = data && data.winningHorse !== null ? data.runners[data.winningHorse].name : null;
  const symbol = data?.token.symbol ?? "stablecoins";

  return (
    <main className="page">
      <header className="topbar">
        <span className="brand">SweepStake.nft</span>
        {account ? (
          <div className="wallet-chip">
            <span>{shortAddress(account)}</span>
            {mine.data && (
              <span className="wallet-balance">
                {amountLabel(mine.data.balance, mine.data.token)} on {CHAIN.name}
              </span>
            )}
            <button className="link-button" onClick={wallet.disconnect}>
              Disconnect
            </button>
          </div>
        ) : (
          <button className="ghost-button" onClick={requestConnect}>
            <span aria-hidden="true">🐎</span> Connect wallet
          </button>
        )}
      </header>

      {IS_TEST_MONEY && (
        <div className="alert" role="note">
          <span>
            {IS_LOCAL
              ? "This is a local test chain. Your wallet gets free test tUSDT here, which isn't your real balance, and nothing on this page can spend real money."
              : `This is a test on ${CHAIN.name} using free test tUSDT, so nothing here is real money.`}
          </span>
          {!IS_LOCAL && wallet.client && (
            <button className="ghost-button" disabled={minting} onClick={() => void getTestTokens()}>
              {minting ? "Minting…" : "Get 100 test tUSDT"}
            </button>
          )}
        </div>
      )}

      {picker && !account && (
        <div className="picker" role="dialog" aria-label="Choose a wallet">
          {wallet.options.length ? (
            <>
              <p>Choose a wallet</p>
              <div className="picker-options">
                {wallet.options.map((option) => (
                  <button key={option.info.uuid} className="ghost-button" onClick={() => void connectTo(option)}>
                    {option.info.icon && <img src={option.info.icon} alt="" width={20} height={20} />}
                    {option.info.name}
                  </button>
                ))}
              </div>
            </>
          ) : (
            <p>
              No wallet found. On a phone, open this page in your wallet app's browser. On a computer, install a wallet
              such as MetaMask or Rabby, then reload this page.
            </p>
          )}
          <button className="link-button" onClick={() => setPicker(false)}>
            Close
          </button>
        </div>
      )}

      {walletError && (
        <p className="alert" role="alert">
          {walletError}
        </p>
      )}

      {account && !wallet.onRightChain && (
        <div className="alert">
          <span>Your wallet is on a different network. This sweep runs on {CHAIN.name}.</span>
          <button className="ghost-button" onClick={() => void switchChain()}>
            Switch to {CHAIN.name}
          </button>
        </div>
      )}

      <section className="hero">
        <p className="eyebrow">Melbourne Cup 2026</p>
        <h1>
          The Sweep <span className="hero-trophy" aria-hidden="true">🏆</span>
        </h1>
        <p className="tagline">Pick your stake and buy an NFT ticket. A random horse comes out of the hat. If it wins, you take the pool.</p>
        {winner ? (
          <p className="clock clock-winner">{winner} won the Cup</p>
        ) : data && !closed ? (
          <p className="clock">
            Entries close in <strong>{countdown(data.entriesClose - now)}</strong>
            <span className="clock-when">
              {when(data.entriesClose)}
              {!IS_TEST_MONEY && ` · Race starts ${when(RACE_START)}`}
            </span>
          </p>
        ) : data ? (
          <p className="clock">
            Entries are closed
            <span className="clock-when">
              {!IS_TEST_MONEY && `Race starts ${when(RACE_START)} · `}Results from {when(data.resultsOpen)}
            </span>
          </p>
        ) : null}
      </section>

      {overview.failed && (
        <p className="alert" role="status">
          Can't reach {CHAIN.name} right now. Trying again shortly.
        </p>
      )}

      <section aria-label="Sweeps" className="sweeps">
        {data
          ? data.sweeps.map((s) => (
              <SweepCard
                key={s.id}
                sweep={s}
                selected={s.id === selectedSweep}
                onSelect={setSelectedSweep}
                overview={data}
                closed={closed}
                wallet={wallet}
                mine={mine.data}
                busy={action !== null}
                progress={action?.sweepId === s.id ? action.progress : null}
                active={action?.sweepId === s.id}
                message={sweepMessage?.sweepId === s.id ? sweepMessage : null}
                onBuy={(target) => void buy(target)}
                onConnect={requestConnect}
                onSwitch={() => void switchChain()}
              />
            ))
          : !overview.failed && <p className="muted loading">Loading the sweeps…</p>}
      </section>

      {account && (
        <MyTickets
          tickets={mine.data?.tickets ?? null}
          canClaim={wallet.client !== null}
          busy={action !== null}
          activeTicket={action?.ticketId ?? null}
          progress={action?.ticketId !== undefined ? action.progress : null}
          message={ticketMessage}
          onClaim={(ticket) => void claim(ticket)}
        />
      )}

      {data && <Runners overview={data} sweepId={selectedSweep} account={account} closed={closed} />}

      <section className="how">
        <h2>How it works</h2>
        <ol>
          <li>
            <strong>Buy an NFT ticket.</strong> Pay in {symbol} on {CHAIN.name}, with a little ETH for gas. For your first
            ticket your wallet asks twice: once to allow the {symbol}, and once to buy. The allowance covers every ticket in
            that sweep, so buying more only asks once, and you only pay for the tickets you buy. Every ticket is a real NFT in
            your wallet, with its pixel art stored onchain. You can buy as many as you like, and whoever holds a ticket when
            claiming gets paid, so you can send or sell them too.
          </li>
          <li>
            <strong>Get your horse.</strong> Your ticket pulls a random horse from that sweep's hat straight away, and each horse
            only comes out once. It shows up on your NFT, and in the runners above.
          </li>
          <li>
            <strong>Watch the race.</strong> In each sweep, whoever holds the NFT with the winning horse claims that sweep's
            whole pool from this page.
          </li>
          <li>
            <strong>Scratched?</strong> If your horse is scratched, your entry fee comes straight back to your wallet. If nobody
            in your sweep holds the winner, you can claim it back here.
          </li>
        </ol>
        <p className="muted">
          Only the sweep's owner can scratch a horse and enter the result, so you're trusting them to do both fairly. If they
          never enter a result, anyone can cancel a sweep a week after entries close, and its tickets get refunds.
        </p>
      </section>

      {purchase && <SuccessModal purchase={purchase} onClose={() => setPurchase(null)} />}

      <footer className="footer">
        <a href={`${EXPLORER}/address/${SWEEP_ADDRESS}#code`} target="_blank" rel="noreferrer">
          Sweep contract
        </a>
        {data && (
          <a href={`${EXPLORER}/token/${data.token.address}`} target="_blank" rel="noreferrer">
            {data.token.symbol}
          </a>
        )}
      </footer>
    </main>
  );
}
