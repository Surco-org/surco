// Single-place configuration for the Pinto Launcher indexer & API.
// Switching from the mainnet TEST factory to the real factory only requires updating ACTIVE_LAUNCHER below.
import type { Address } from "viem";

export type LegacyFactory = {
  factory: Address;
  hook: Address;
  deployBlock: number;
};

export type LauncherConfig = {
  factory: Address;
  hook: Address;
  safe: Address;
  deployBlock: number;
  isTest: boolean;
  veChirp?: Address;
  collectiveSilo?: Address;
  /** Earlier Base mainnet factories whose active coins remain listed and tradeable on / and /coin. */
  extraFactories?: ReadonlyArray<LegacyFactory>;
};

// Base mainnet shared protocol addresses (verified on-chain).
export const BASE_POOL_MANAGER = "0x498581fF718922c3f8e6A244956aF099B2652b2b" as Address;
export const BASE_WETH = "0x4200000000000000000000000000000000000006" as Address;
export const BASE_PINTO = "0xb170000aeeFa790fa61D6e837d1035906839a3c8" as Address;
export const BASE_CHIRP = "0x4D2D8C1E1c8239Ca56Db7612C9Efe5d6a1a2ea13" as Address;
export const BASE_USDC = "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913" as Address;
export const BASE_USDC_WELL = "0x3e1133aC082716DDC3114bbEFEeD8B1731eA9cb1" as Address;
// Uniswap v3 WETH/USDC 0.05% pool on Base (token0 = WETH, token1 = USDC, 18 vs 6 decimals).
export const BASE_WETH_USDC_POOL = "0xd0b53D9277642d899DF5C87A3966A349A798F224" as Address;
export const BASE_SWAP_ROUTER02 = "0x2626664c2603336E57B271c5C0b26F421741e481" as Address;

export const LAUNCHER_LP_FEE = 0;
export const LAUNCHER_TICK_SPACING = 200;
export const LAUNCHER_TOLL_WINDOW = 600; // 10 minutes
export const LAUNCHER_SUPPLY = 1_000_000_000n * 10n ** 18n;

// Active deployment: Base mainnet production Surco Launcher + Collective Silo + veChirp (2026-11-21).
export const ACTIVE_LAUNCHER: LauncherConfig = {
  factory: "0xf3A050114d4310beF64660a68332169Eb76D0d70",
  hook: "0x9e0DB1E907Da713Ef19E95b0aB539f8ef9ffEAEc",
  safe: "0x2D67Fc71e6ed4527E09dD9F8C73f3D7c72219449",
  deployBlock: 60_614_593,
  isTest: false,
  veChirp: "0x7b817Bd8773b5CaAE267e9cc43FEdbceF148F0ed",
  collectiveSilo: "0x1e050aDAC1011bcCeEf66FA485331fAaFA9Ad064",
};
