import { createPublicClient, fallback, getAddress, http, isAddress, zeroAddress, type Chain } from "viem";
import { base, baseSepolia, foundry, mainnet, sepolia } from "viem/chains";

const NETWORKS: Record<string, { chain: Chain; rpcs: string[] }> = {
  mainnet: {
    chain: mainnet,
    rpcs: ["https://ethereum-rpc.publicnode.com", "https://eth.drpc.org", "https://cloudflare-eth.com"],
  },
  base: { chain: base, rpcs: ["https://mainnet.base.org", "https://base-rpc.publicnode.com"] },
  "base-sepolia": { chain: baseSepolia, rpcs: ["https://sepolia.base.org", "https://base-sepolia-rpc.publicnode.com"] },
  sepolia: { chain: sepolia, rpcs: ["https://ethereum-sepolia-rpc.publicnode.com"] },
  // A local anvil chain. Its chain id means a wallet on a real network can't pass the page's network check.
  local: {
    chain: {
      ...foundry,
      name: "Local chain",
      contracts: { multicall3: { address: "0xcA11bde05977b3631167028862bE2a173976CA11" } },
    },
    rpcs: ["http://127.0.0.1:8545"],
  },
};

// Hidden switch: ?testnet=true on the URL swaps the page to the test contract on Sepolia.
const testnetAddress: string = import.meta.env.VITE_TESTNET_SWEEP_ADDRESS ?? "";
const useTestnet = new URLSearchParams(window.location.search).get("testnet") === "true" && isAddress(testnetAddress);

const configured: string = useTestnet ? testnetAddress : (import.meta.env.VITE_SWEEP_ADDRESS ?? "");
const customRpc: string | undefined = useTestnet ? undefined : import.meta.env.VITE_RPC_URL;
const network: { chain: Chain; rpcs: string[] } | undefined = useTestnet
  ? NETWORKS.sepolia
  : NETWORKS[import.meta.env.VITE_CHAIN || "mainnet"];

export const isConfigured = isAddress(configured) && network !== undefined;
export const SWEEP_ADDRESS = isAddress(configured) ? getAddress(configured) : zeroAddress;
export const CHAIN: Chain = (network ?? NETWORKS.mainnet).chain;
export const IS_LOCAL = CHAIN.id === foundry.id;
/** Chains where the betting currency is our free test token, which anyone can mint. */
export const IS_TEST_MONEY = IS_LOCAL || CHAIN.id === sepolia.id;
export const EXPLORER = CHAIN.blockExplorers?.default.url ?? "";

/** 3 Nov 2026 3:00pm AEDT. The race time isn't onchain, only the close of entries and the results time are. */
export const RACE_START = 1793678400;

const transport = () =>
  customRpc ? http(customRpc) : fallback((network ?? NETWORKS.mainnet).rpcs.map((url) => http(url)));

export const publicClient = createPublicClient({ chain: CHAIN, batch: { multicall: true }, transport: transport() });

/**
 * For tokenURI, which draws a whole NFT and costs millions of gas to read. Public RPCs cap the gas of
 * one read, so these go one at a time rather than being bundled into a multicall.
 */
export const artClient = createPublicClient({ chain: CHAIN, transport: transport() });
