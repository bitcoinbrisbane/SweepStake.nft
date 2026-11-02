import { createPublicClient, fallback, getAddress, http, isAddress, zeroAddress } from "viem";
import { mainnet } from "viem/chains";

const configured: string = import.meta.env.VITE_SWEEP_ADDRESS ?? "";
const rpc: string | undefined = import.meta.env.VITE_RPC_URL;

export const isConfigured = isAddress(configured);
export const SWEEP_ADDRESS = isAddress(configured) ? getAddress(configured) : zeroAddress;
export const USDT_ADDRESS = "0xdAC17F958D2ee523a2206206994597C13D831ec7";
export const USDT_DECIMALS = 6;
export const CHAIN = mainnet;
export const EXPLORER = CHAIN.blockExplorers.default.url;

/** 3 Nov 2026 3:00pm AEDT. The race time isn't onchain, only the close of entries is. */
export const RACE_START = 1793678400;

export const publicClient = createPublicClient({
  chain: CHAIN,
  batch: { multicall: true },
  transport: rpc
    ? http(rpc)
    : fallback([
        http("https://ethereum-rpc.publicnode.com"),
        http("https://eth.drpc.org"),
        http("https://cloudflare-eth.com"),
      ]),
});
