import { useCallback, useEffect, useMemo, useState } from "react";
import { createWalletClient, custom, getAddress, numberToHex, type Address, type EIP1193Provider } from "viem";
import type { Wallet } from "./chain";
import { CHAIN, EXPLORER, WALLETCONNECT_PROJECT_ID } from "./config";
import { disconnectWalletConnect, walletConnectProvider } from "./walletconnect";

export type WalletOption = {
  info: { uuid: string; name: string; icon: string; rdns: string };
  provider: EIP1193Provider;
};

const STORAGE_KEY = "sweep.wallet";
const WALLETCONNECT = "walletconnect";

const walletConnectOption: WalletOption = {
  info: { uuid: WALLETCONNECT, name: "WalletConnect", icon: "", rdns: WALLETCONNECT },
  provider: walletConnectProvider,
};

// Browser storage can throw in private windows. Forgetting the wallet is harmless.
function remembered(): string | null {
  try {
    return localStorage.getItem(STORAGE_KEY);
  } catch {
    return null;
  }
}

function remember(rdns: string | null) {
  try {
    if (rdns) localStorage.setItem(STORAGE_KEY, rdns);
    else localStorage.removeItem(STORAGE_KEY);
  } catch {
    // See remembered().
  }
}

function legacyProvider(): WalletOption | null {
  const provider = (window as unknown as { ethereum?: EIP1193Provider }).ethereum;
  if (!provider) return null;
  return { info: { uuid: "injected", name: "Browser wallet", icon: "", rdns: "injected" }, provider };
}

/** Finds browser wallets (EIP-6963, falling back to window.ethereum) and tracks the connected one. */
export function useWallet() {
  const [announced, setAnnounced] = useState<WalletOption[]>([]);
  const [legacy] = useState(legacyProvider);
  const [active, setActive] = useState<WalletOption | null>(null);
  const [account, setAccount] = useState<Address | null>(null);
  const [chainId, setChainId] = useState<number | null>(null);

  useEffect(() => {
    const onAnnounce = (event: Event) => {
      const detail = (event as CustomEvent<WalletOption>).detail;
      setAnnounced((known) => (known.some((w) => w.info.uuid === detail.info.uuid) ? known : [...known, detail]));
    };
    window.addEventListener("eip6963:announceProvider", onAnnounce);
    window.dispatchEvent(new Event("eip6963:requestProvider"));
    return () => window.removeEventListener("eip6963:announceProvider", onAnnounce);
  }, []);

  const options = useMemo(() => {
    const inBrowser = announced.length ? announced : legacy ? [legacy] : [];
    return WALLETCONNECT_PROJECT_ID ? [...inBrowser, walletConnectOption] : inBrowser;
  }, [announced, legacy]);

  const adopt = useCallback(async (option: WalletOption, accounts: readonly string[]) => {
    if (!accounts.length) return;
    const chain = await option.provider.request({ method: "eth_chainId" });
    setActive(option);
    setAccount(getAddress(accounts[0]));
    setChainId(Number(chain));
  }, []);

  const connect = useCallback(
    async (option: WalletOption) => {
      const accounts = await option.provider.request({ method: "eth_requestAccounts" });
      await adopt(option, accounts);
      remember(option.info.rdns);
    },
    [adopt],
  );

  const disconnect = useCallback(() => {
    if (active?.info.rdns === WALLETCONNECT) void disconnectWalletConnect();
    setActive(null);
    setAccount(null);
    setChainId(null);
    remember(null);
  }, [active]);

  const switchChain = useCallback(async () => {
    if (!active) return;
    const chainId = numberToHex(CHAIN.id);
    try {
      await active.provider.request({ method: "wallet_switchEthereumChain", params: [{ chainId }] });
    } catch (err) {
      // 4902 means the wallet doesn't know this network yet, which is common for Base, so offer to add it.
      const { code, data } = err as { code?: number; data?: { originalError?: { code?: number } } };
      if (code !== 4902 && data?.originalError?.code !== 4902) throw err;
      await active.provider.request({
        method: "wallet_addEthereumChain",
        params: [
          {
            chainId,
            chainName: CHAIN.name,
            nativeCurrency: CHAIN.nativeCurrency,
            rpcUrls: CHAIN.rpcUrls.default.http,
            blockExplorerUrls: EXPLORER ? [EXPLORER] : undefined,
          },
        ],
      });
    }
  }, [active]);

  // Reconnect quietly if this wallet was connected last time. eth_accounts never prompts.
  useEffect(() => {
    if (active) return;
    const option = options.find((w) => w.info.rdns === remembered());
    if (!option) return;
    option.provider
      .request({ method: "eth_accounts" })
      .then((accounts) => adopt(option, accounts))
      .catch(() => remember(null));
  }, [active, options, adopt]);

  useEffect(() => {
    if (!active) return;
    const { provider } = active;
    const onAccounts = (accounts: readonly string[]) => {
      if (accounts.length) setAccount(getAddress(accounts[0]));
      else disconnect();
    };
    const onChain = (chain: string) => setChainId(Number(chain));
    provider.on("accountsChanged", onAccounts as never);
    provider.on("chainChanged", onChain as never);
    return () => {
      provider.removeListener("accountsChanged", onAccounts as never);
      provider.removeListener("chainChanged", onChain as never);
    };
  }, [active, disconnect]);

  const onRightChain = chainId === CHAIN.id;

  const client = useMemo<Wallet | null>(() => {
    if (!active || !account || !onRightChain) return null;
    return createWalletClient({ account, chain: CHAIN, transport: custom(active.provider) });
  }, [active, account, onRightChain]);

  return { options, account, onRightChain, client, connect, disconnect, switchChain };
}

export type WalletState = ReturnType<typeof useWallet>;
