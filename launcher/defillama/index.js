// DeFiLlama TVL Adapter for Surco (https://surcofi.com) on Base.
// Target path in DefiLlama/DefiLlama-Adapters: projects/surco/index.js
//
// Methodology:
//   - tvl: Total Pinto deposited in Pinto's Silo across Surco's immutable contracts:
//       1) ChirpBook (Chirp's one-sided Pinto Silo book)
//       2) CollectiveSilo (shared Pinto Silo funded by Launcher trade fees)
//       3) Every BurnVault / RedeemVault deployed by LauncherFactory
//   - staking: CHIRP locked in VeChirp (ERC-721 vote-escrow gauge).

const { getLogs2 } = require("../helper/cache/getLogs");

const PINTO = "0xb170000aeeFa790fa61D6e837d1035906839a3c8";
const CHIRP = "0x4D2D8C1E1c8239Ca56Db7612C9Efe5d6a1a2ea13";
const CHIRP_BOOK = "0x10b919A89a5ABfecEBd805836DA174F02B023756";
const COLLECTIVE_SILO = "0x1e050aDAC1011bcCeEf66FA485331fAaFA9Ad064";
const VE_CHIRP = "0x7b817Bd8773b5CaAE267e9cc43FEdbceF148F0ed";
const LAUNCHER_FACTORY = "0xf3A050114d4310beF64660a68332169Eb76D0d70";
const LAUNCHER_START_BLOCK = 60614593;

const LAUNCHED_EVENT_ABI =
  "event Launched(address indexed coin, address vault, bytes32 indexed id, address indexed launcher, uint8 mode, uint16 feeBps, uint16 creatorBps, uint256 firstBuyWeth, uint256 coinsBought)";

async function tvl(api) {
  // 1. ChirpBook + CollectiveSilo Silo Pinto backing
  const [chirpSilo, collectiveSiloPinto] = await api.multiCall({
    abi: "uint256:siloPinto",
    calls: [CHIRP_BOOK, COLLECTIVE_SILO],
    permitFailure: true,
  });
  if (chirpSilo) api.add(PINTO, chirpSilo);
  if (collectiveSiloPinto) api.add(PINTO, collectiveSiloPinto);

  // 2. All Launcher vaults deployed by LauncherFactory
  const logs = await getLogs2({
    api,
    factory: LAUNCHER_FACTORY,
    eventAbi: LAUNCHED_EVENT_ABI,
    fromBlock: LAUNCHER_START_BLOCK,
  });
  const vaults = [...new Set(logs.map((l) => l.vault).filter(Boolean))];
  if (vaults.length > 0) {
    const vaultPinto = await api.multiCall({
      abi: "uint256:siloPinto",
      calls: vaults,
      permitFailure: true,
    });
    for (const bal of vaultPinto) {
      if (bal) api.add(PINTO, bal);
    }
  }
}

async function staking(api) {
  const locked = await api.call({
    abi: "uint256:totalLocked",
    target: VE_CHIRP,
  });
  api.add(CHIRP, locked);
}

module.exports = {
  methodology:
    "TVL counts Pinto deposited in Pinto's Silo across ChirpBook, CollectiveSilo, and all Surco Launcher vaults on Base. Staking counts CHIRP locked in VeChirp.",
  start: 1794873600, // 2026-11-17 (Chirp launch on Base)
  base: {
    tvl,
    staking,
  },
};
