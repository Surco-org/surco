// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// Every fixed parameter and Base address the launcher uses. Nothing here is settable.

uint256 constant SUPPLY = 1_000_000_000e18;

// The trade fee, in bps of the trade.
uint256 constant MIN_FEE_BPS = 30;
uint256 constant MAX_FEE_BPS = 300;

// Shares of the fee, in bps of the fee.
uint256 constant PLATFORM_BPS = 2000;
uint256 constant MAX_CREATOR_BPS = 2000;

// In bps of each convert / buyback batch.
uint256 constant TIP_BPS = 50;
uint256 constant REDEEM_FEE_BPS = 100;

// Pinto's LibConvertData.ConvertKind.LAMBDA_LAMBDA (read from ConvertFacet's verified source, fork-proven).
uint8 constant LAMBDA_LAMBDA = 0;
// RedeemVault merges its stems at the end of convert() once it holds more than this many.
uint256 constant MERGE_ABOVE_STEMS = 3;
// Gas convert() must still hold for that merge, or it reverts. A cold RedeemVault merge of 3 finished stems (+1
// germinating kept) on the real Diamond measured 660,614 as its own transaction (test/fork/LambdaMerge.t.sol
// test_vault_merge_real, --isolate, 2026-11-20; the raw Diamond 3-stem merge cold was 612,276). x1.5, rounded up.
uint256 constant MERGE_GAS = 1_000_000;

uint256 constant TOLL_START_BPS = 8000;
uint256 constant TOLL_WINDOW = 10 minutes;

// The cbETH well held ~6.53 cbETH / ~689k Pinto on 2026-11-20.
uint256 constant MAX_CONVERT_WETH = 0.05 ether;
uint256 constant MAX_BUYBACK_PINTO = 2_000e6; // Pinto has 6 decimals

// How far each Pinto-route leg may pay below its PriceGuard quote (PintoRoute). Sampled hourly for 30 days: 720
// read-only eth_calls, Base blocks 52,918,514..60,121,997 (2026-10-21 23:46 .. 11-20 22:46 UTC, mainnet.base.org).
// cbETH well spot vs pump EMA, price gap: p50 0.0 / p90 2.6 / p99 11.9 bps (one sample, 0.14%, at 696 bps: a
// large move the EMA had not caught up with). v3 spot vs the 1800 s TWAP tick: p50 0.6 / p90 1.0 / p99 4.0 / max
// 11.9 bps. The tightest value 99% fit is far under 50 bps, so both take the 50 bps floor. A same-transaction push
// can take at most ~WELL_TOL_BPS (+ WELL_FEE_BPS while PI-17 is not live) of a batch; a volatile hour makes
// convert() revert and the WETH wait. A full batch itself moves the well ~1.4%, so the next full convert (any
// vault) waits ~2 min for the EMA (fork, no other trades).
uint256 constant WELL_TOL_BPS = 50; // on top of WELL_FEE_BPS, which the well quote deducts separately
uint256 constant V3_TOL_BPS = 50;
// BurnVault's min-out below the coin pool's own EMA price. A young coin pool is volatile, so it stays wide.
uint256 constant COIN_TOL_BPS = 300;
uint32 constant V3_TWAP_SECONDS = 1800;
uint256 constant EMA_WINDOW = 1800;
int24 constant MAX_TICK_DRIFT = 300;
uint24 constant V3_POOL_FEE = 100; // the WETH/cbETH pool's 0.01% tier
uint256 constant WELL_FEE_BPS = 25; // PI-17 (draft) well swap fee; the guard deducts it whether or not it is live

int24 constant TICK_SPACING = 200;
uint24 constant LP_FEE = 0;
uint256 constant START_FDV_WETH = 10 ether; // Clanker's default start
// Flat launch fee routed to CollectiveSilo on every launch (0.0001 ETH).
uint256 constant LAUNCH_FEE = 0.0001 ether;

// Base mainnet, verified on-chain 2026-11-20 unless marked.
address constant CHIRP = 0x4D2D8C1E1c8239Ca56Db7612C9Efe5d6a1a2ea13;
address constant WETH = 0x4200000000000000000000000000000000000006;
address constant CBETH = 0x2Ae3F1Ec7F1F5012CFEab0185bfc7aa3cf0DEc22;
address constant PINTO = 0xb170000aeeFa790fa61D6e837d1035906839a3c8;
address constant PINTO_DIAMOND = 0xD1A0D188E861ed9d15773a2F3574a2e94134bA8f; // the Silo
address constant CBETH_WELL = 0x3e111115A82dF6190e36ADf0d552880663A4dBF1; // tokens [PINTO, cbETH]
address constant CBETH_WELL_PUMP = 0xBA51AAaA66DaB6c236B356ad713f759c206DcB93; // MultiFlowPump
address constant V3_WETH_CBETH_POOL = 0xA9DaFa443a02FBc907Cb0093276B3E6F4ef02A46; // 0.01%, token0 = cbETH
address constant SWAP_ROUTER02 = 0x2626664c2603336E57B271c5C0b26F421741e481;
address constant POOL_MANAGER = 0x498581fF718922c3f8e6A244956aF099B2652b2b;
address constant UNIVERSAL_ROUTER = 0x6fF5693b99212Da76ad316178A184AB56D299b43;
address constant V4_QUOTER = 0x0d5e0F971ED27FBfF6c2837bf31316121532048D;
