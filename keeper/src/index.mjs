// Agama liquidation keeper — best-effort, runs on Eden's machine.
//
// The protocol is fully autonomous on-chain (liquidate() is permissionless, the NAV
// accrues from block.timestamp), so this keeper is pure speed: it indexes borrower
// positions from pool events, recomputes every health factor each block, and the
// instant one drops below 1 it fires liquidate() — through the Timeboost express lane
// when it controls the round, otherwise the normal lane. If it hasn't run in two
// weeks, nothing breaks; when it runs, liquidations are a block faster.
//
// Wiring point for bond.credit: replace `scanAndLiquidate`'s detection with their
// Watchtower feed. The execution path (express lane) stays.
import { createPublicClient, createWalletClient, http, defineChain, parseAbi, keccak256 } from 'viem';
import { privateKeyToAccount } from 'viem/accounts';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { bidNextRound, sendExpressLane, controlsRound, AUCTION_ABI } from './timeboost.mjs';

const __dir = dirname(fileURLToPath(import.meta.url));
const dep = JSON.parse(readFileSync(join(__dir, '../../stylus/deployments/arbitrum-sepolia.json'), 'utf8'));

const cfg = {
  chainId: dep.chainId,
  hexChainId: `0x${dep.chainId.toString(16)}`,
  rpc: process.env.RPC || dep.rpc,
  auctioneer: process.env.AUCTIONEER || 'https://arbsepolia-auctioneer.arbitrum.io/',
  reserveApi: process.env.RESERVE_API || 'https://arbsepolia-reserve-pricer.arbitrum.io/api/latest',
  auction: process.env.AUCTION || '0x991DbEDf388CB5925318f06362D4fCa7b040527D',
  pool: dep.contracts.LendingPool,
};
const PK = process.env.PK;
if (!PK) { console.error('set PK'); process.exit(1); }

const chain = defineChain({ id: cfg.chainId, name: 'arb', nativeCurrency: { name: 'ETH', symbol: 'ETH', decimals: 18 }, rpcUrls: { default: { http: [cfg.rpc] } } });
const account = privateKeyToAccount(PK);
const pub = createPublicClient({ chain, transport: http(cfg.rpc) });
const wallet = createWalletClient({ account, chain, transport: http(cfg.rpc) });

const POOL_ABI = parseAbi([
  'event Borrowed(address indexed user, uint256 assets)',
  'event CollateralDeposited(address indexed user, address indexed vault, uint256 shares)',
  'event Liquidated(address indexed user, address indexed liquidator, address indexed vault, uint256 repaid, uint256 seizedShares)',
  'function healthFactor(address user) view returns (uint256)',
  'function debtOf(address user) view returns (uint256)',
  'function vaultsCount() view returns (uint256)',
  'function vaultAt(uint256 i) view returns (address)',
  'function collateralShares(address user, address vault) view returns (uint256)',
  'function liquidate(address user, address vault, uint256 repayAssets)',
]);
const WAD = 10n ** 18n;

// ---- 1. index borrower set from events ----
async function indexBorrowers() {
  const logs = await pub.getLogs({ address: cfg.pool, events: POOL_ABI.filter(x => x.type === 'event' && (x.name === 'Borrowed' || x.name === 'CollateralDeposited')), fromBlock: 0n, toBlock: 'latest' });
  const set = new Set();
  for (const l of logs) if (l.args?.user) set.add(l.args.user.toLowerCase());
  return [...set];
}

// pick the vault where the user has the most collateral (best to seize)
async function bestVault(user) {
  const n = Number(await pub.readContract({ address: cfg.pool, abi: POOL_ABI, functionName: 'vaultsCount' }));
  let best = null, bestShares = 0n;
  for (let i = 0; i < n; i++) {
    const v = await pub.readContract({ address: cfg.pool, abi: POOL_ABI, functionName: 'vaultAt', args: [BigInt(i)] });
    const s = await pub.readContract({ address: cfg.pool, abi: POOL_ABI, functionName: 'collateralShares', args: [user, v] });
    if (s > bestShares) { bestShares = s; best = v; }
  }
  return best;
}

// ---- 2 + 3. compute HF, fire liquidation through express lane if controlled ----
async function scanAndLiquidate() {
  const borrowers = await indexBorrowers();
  const atRisk = [];
  for (const u of borrowers) {
    const hf = await pub.readContract({ address: cfg.pool, abi: POOL_ABI, functionName: 'healthFactor', args: [u] });
    if (hf < WAD) atRisk.push({ user: u, hf });
  }
  console.log(`[scan] ${borrowers.length} borrowers, ${atRisk.length} liquidatable`);
  for (const { user, hf } of atRisk) {
    const vault = await bestVault(user);
    if (!vault) continue;
    const debt = await pub.readContract({ address: cfg.pool, abi: POOL_ABI, functionName: 'debtOf', args: [user] });
    const repay = debt / 2n; // close factor 50%
    console.log(`[liquidate] user ${user} HF=${(Number(hf) / 1e18).toFixed(3)} vault ${vault} repay ${repay}`);
    await fireLiquidation(user, vault, repay);
  }
  return atRisk.length;
}

async function fireLiquidation(user, vault, repay) {
  const data = encodeLiquidate(user, vault, repay);
  const round = Number(await pub.readContract({ address: cfg.auction, abi: AUCTION_ABI, functionName: 'currentRound' }).catch(() => 0));
  // Try express lane if we already control this round.
  let express = false;
  try { express = round && await controlsRound(pub, cfg.auction, account.address, round); } catch {}
  const signed = await wallet.signTransaction({ to: cfg.pool, data, gas: 1_500_000n, maxFeePerGas: 500_000_000n, maxPriorityFeePerGas: 0n, nonce: await pub.getTransactionCount({ address: account.address }) });
  const t0 = Date.now();
  if (express) {
    const res = await sendExpressLane(cfg, account, signed, round);
    if (res.error) { console.log(`  express rejected (${res.error.message}); falling back to normal lane`); await sendNormal(signed); }
    else console.log(`  ⚡ submitted via Timeboost express lane`);
  } else {
    await sendNormal(signed);
    console.log(`  submitted via normal lane (no express-lane control this round)`);
  }
  try {
    const rec = await pub.waitForTransactionReceipt({ hash: keccak256(signed), timeout: 30000 });
    console.log(`  included blk ${rec.blockNumber} status ${rec.status} in ${Date.now() - t0}ms (express=${express})`);
  } catch (e) { console.log(`  receipt wait: ${e.message}`); }
}

async function sendNormal(signed) {
  await fetch(cfg.rpc, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'eth_sendRawTransaction', params: [signed] }) });
}

function encodeLiquidate(user, vault, repay) {
  // liquidate(address,address,uint256) selector + args
  const sel = keccak256(new TextEncoder().encode('liquidate(address,address,uint256)')).slice(0, 10);
  const p = (h) => h.toLowerCase().replace('0x', '').padStart(64, '0');
  return sel + p(user) + p(vault) + p('0x' + repay.toString(16));
}

// ---- main loop ----
const once = process.argv.includes('--once');
async function tick() {
  // keep an express-lane bid in flight so we control the round if a liquidation lands
  bidNextRound(pub, account, cfg).then(r => { if (r.ok) console.log(`[timeboost] bid placed for round ${r.bidRound}`); else if (r.error) console.log(`[timeboost] bid unavailable: ${r.error}`); });
  await scanAndLiquidate();
}
if (once) { await tick(); process.exit(0); }
console.log(`Agama keeper watching pool ${cfg.pool} on chain ${cfg.chainId}`);
for (;;) { try { await tick(); } catch (e) { console.error('tick error', e.message); } await new Promise(r => setTimeout(r, 12000)); }
