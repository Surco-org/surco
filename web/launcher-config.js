// Single-place configuration for the Surco Launcher pages (/coins, /launch, /coin, /creator).
// Switching from the TEST factory to the real factory only requires updating FACTORY, HOOK, and IS_TEST_FACTORY.
import { parseAbi } from "viem"

export const IS_TEST_FACTORY = false
export const HAS_METADATA_URI = true
export const HAS_COLLECTIVE_SILO = true

export const FACTORY = "0xf3A050114d4310beF64660a68332169Eb76D0d70"
export const HOOK = "0x9e0DB1E907Da713Ef19E95b0aB539f8ef9ffEAEc"
export const VE_CHIRP = "0x7b817Bd8773b5CaAE267e9cc43FEdbceF148F0ed"
export const COLLECTIVE_SILO = "0x1e050aDAC1011bcCeEf66FA485331fAaFA9Ad064"

// Base mainnet shared contracts (verified on-chain).
export const POOL_MANAGER = "0x498581fF718922c3f8e6A244956aF099B2652b2b"
export const UNIVERSAL_ROUTER = "0x6fF5693b99212Da76ad316178A184AB56D299b43"
export const V4_QUOTER = "0x0d5e0F971ED27FBfF6c2837bf31316121532048D"
export const PERMIT2 = "0x000000000022D473030F116dDEE9F6B43aC78BA3"
export const WETH = "0x4200000000000000000000000000000000000006"
export const PINTO = "0xb170000aeeFa790fa61D6e837d1035906839a3c8"
export const CHIRP = "0x4D2D8C1E1c8239Ca56Db7612C9Efe5d6a1a2ea13"

export const LAUNCH_FEE_WEI = 100_000_000_000_000n // 0.0001 ETH
export const VE_MIN_DAYS = 2
export const VE_MAX_DAYS = 365

export const READ_RPC_URL = "https://base.publicnode.com"
export const BASE_CHAIN_ID = 8453
export const BASESCAN = "https://basescan.org"

export const LP_FEE = 0
export const TICK_SPACING = 200
export const SUPPLY_WEI = 1_000_000_000n * 10n ** 18n
export const START_FDV_WETH = 10n * 10n ** 18n
export const TOLL_START_BPS = 8000
export const TOLL_WINDOW = 600
export const PLATFORM_BPS = 2000
export const MIN_FEE_BPS = 30
export const MAX_FEE_BPS = 300
export const MAX_CREATOR_BPS = 2000
export const REDEEM_FEE_BPS = 100

export const FACTORY_ABI = parseAbi([
  "function launch((string name, string symbol, string imageURI, uint8 mode, uint16 feeBps, uint16 creatorBps, address creatorPayout) p) payable returns (address coin, address vault, bytes32 id)",
  "event Launched(address indexed coin, address vault, bytes32 indexed id, address indexed launcher, uint8 mode, uint16 feeBps, uint16 creatorBps, uint256 firstBuyWeth, uint256 coinsBought)",
  "error ZeroAddress()",
  "error BadFee()",
  "error BadCreatorBps()",
  "error EmptyName()",
  "error BadPayout()",
  "error KeptFunds()",
  "error TransferFailed()",
])

export const FACTORY_V2_ABI = parseAbi([
  "function launch((string name, string symbol, string imageURI, string metadataURI, uint8 mode, uint16 feeBps, uint16 creatorBps, address creatorPayout) p) payable returns (address coin, address vault, bytes32 id)",
  "event Launched(address indexed coin, address vault, bytes32 indexed id, address indexed launcher, uint8 mode, uint16 feeBps, uint16 creatorBps, uint256 firstBuyWeth, uint256 coinsBought)",
  "error ZeroAddress()",
  "error BadFee()",
  "error BadCreatorBps()",
  "error EmptyName()",
  "error BadPayout()",
  "error KeptFunds()",
  "error TransferFailed()",
  "error InsufficientLaunchFee()",
])

export const VE_CHIRP_ABI = parseAbi([
  "function lock(uint128 amount, uint32 lockDays, bool permanent, address coin) returns (uint256 id)",
  "function addAmount(uint256 id, uint128 addChirp)",
  "function extend(uint256 id, uint32 newEndDay)",
  "function setPermanent(uint256 id, bool on)",
  "function switchCoin(uint256 id, address newCoin)",
  "function withdraw(uint256 id)",
  "function currentDay() view returns (uint32)",
  "function totalLocked() view returns (uint256)",
  "function latestSnap(uint256 id) view returns ((uint32 fromDay, uint32 endDay, bool permanent, address coin, uint128 amount))",
  "error ZeroAmount()",
  "error BadDuration()",
  "error UnknownCoin()",
  "error NotOwner()",
  "error IsPermanent()",
  "error StillLocked()",
  "error SameCoin()",
  "error TransferFailed()",
])

export const COLLECTIVE_SILO_ABI = parseAbi([
  "function seed()",
  "function convert()",
  "function plant() returns (uint256 beans)",
  "function claim(uint256 lockId, uint32 maxDays) returns (address coin, uint256 payout)",
  "function siloPinto() view returns (uint256)",
  "function yieldPinto() view returns (uint256)",
  "error NothingPending()",
  "error NotClaimant()",
  "error Locked()",
])

export const VAULT_ABI = parseAbi([
  "function split()",
  "function seed()",
  "function setCreatorPayout(address next)",
  "function redeem(uint256 amount, uint256 minPinto, address recipient) returns (uint256 out)",
  "function siloPinto() view returns (uint256)",
  "function pendingPintoWeth() view returns (uint256)",
  "function creatorPayout() view returns (address)",
  "function creatorBps() view returns (uint16)",
  "error ZeroAddress()",
  "error OnlyCreator()",
  "error NothingPending()",
  "error ZeroOut()",
  "error Slippage()",
  "error Locked()",
])

export const QUOTER_ABI = parseAbi([
  "function quoteExactInputSingle(((address currency0, address currency1, uint24 fee, int24 tickSpacing, address hooks) poolKey, bool zeroForOne, uint128 exactAmount, bytes hookData) params) returns (uint256 amountOut, uint256 gasEstimate)",
])

export const UNIVERSAL_ROUTER_ABI = parseAbi([
  "function execute(bytes commands, bytes[] inputs, uint256 deadline) payable",
])

export const PERMIT2_ABI = parseAbi([
  "function allowance(address user, address token, address spender) view returns (uint160 amount, uint48 expiration, uint48 nonce)",
  "function approve(address token, address spender, uint160 amount, uint48 expiration)",
])
