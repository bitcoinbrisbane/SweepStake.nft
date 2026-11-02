import type { EIP1193Provider } from "viem";
import { CHAIN, RPC_URL, WALLETCONNECT_PROJECT_ID } from "./config";

/** The package is large, so it's only fetched once someone actually picks WalletConnect. */
async function createProvider() {
  const { EthereumProvider } = await import("@walletconnect/ethereum-provider");
  const origin = window.location.origin;
  return EthereumProvider.init({
    projectId: WALLETCONNECT_PROJECT_ID,
    // Optional rather than required, so a wallet that doesn't list this chain can still connect.
    // The page then asks it to switch, as it does for any wallet on the wrong network.
    optionalChains: [CHAIN.id],
    rpcMap: { [CHAIN.id]: RPC_URL },
    showQrModal: true,
    metadata: {
      name: "Melbourne Cup Sweep",
      description: "Pick your stake, buy an NFT ticket, and a random horse comes out of the hat.",
      url: origin,
      icons: [`${origin}/favicon.svg`],
    },
  });
}

let loaded: ReturnType<typeof createProvider> | null = null;

function load() {
  loaded ??= createProvider().catch((err: unknown) => {
    loaded = null;
    throw err;
  });
  return loaded;
}

/** Looks like any other browser wallet to the rest of the page. */
export const walletConnectProvider = {
  request: async ({ method, params }: { method: string; params?: unknown }) => {
    const provider = await load();
    if (method === "eth_requestAccounts") return provider.session ? provider.accounts : provider.enable();
    if (method === "eth_accounts") return provider.session ? provider.accounts : [];
    return provider.request({ method, params: params as object | undefined });
  },
  on: (event: string, listener: (...args: never[]) => void) => {
    void load().then((provider) => provider.on(event as "accountsChanged", listener as never));
  },
  removeListener: (event: string, listener: (...args: never[]) => void) => {
    void load().then((provider) => provider.removeListener(event as "accountsChanged", listener as never));
  },
} as unknown as EIP1193Provider;

export async function disconnectWalletConnect() {
  const provider = await load();
  if (provider.session) await provider.disconnect();
}
