// Timeboost express-lane client: bid for a round and submit a tx through the
// express lane. Mirrors the Arbitrum docs flow (auctioneer_submitBid +
// timeboost_sendExpressLaneTransaction). Falls back gracefully when the express
// lane is unavailable (e.g. the Sepolia resolver outage) — see TEST-RESULTS.md.
import { concat, keccak256, toHex, numberToBytes, pad, parseAbi } from 'viem';

export const AUCTION_ABI = parseAbi([
  'function currentRound() view returns (uint64)',
  'function roundTimingInfo() view returns (int64 offset, uint64 round, uint64 closing, uint64 reserve)',
  'function balanceOf(address) view returns (uint256)',
  'function resolvedRounds() view returns ((address controller, uint64 round),(address controller, uint64 round))',
]);

async function rpc(url, method, params) {
  const r = await fetch(url, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ jsonrpc: '2.0', id: 1, method, params }) });
  return r.json();
}

export async function controlsRound(pub, auction, controller, round) {
  const resolved = await pub.readContract({ address: auction, abi: AUCTION_ABI, functionName: 'resolvedRounds' });
  return Number(resolved[0].round) === round && resolved[0].controller.toLowerCase() === controller.toLowerCase();
}

// Fetch the live dynamic reserve price (wei). Since April 2026 the reserve is set
// per round by an off-chain agent; the on-chain reservePrice() reads 1 wei and bids
// below the *dynamic* reserve are rejected. Fetch it from the reserve-pricer API.
// https://forum.arbitrum.foundation/t/announcement-of-dynamic-reserve-price-change/30833
export async function dynamicReserve(cfg) {
  try {
    const r = await (await fetch(cfg.reserveApi)).json();
    return BigInt(r.reserve_price_in_wei);
  } catch {
    return 0n;
  }
}

// Try to win the express lane for the next round. Bids above the live dynamic
// reserve (and a floor that clears the typical rival bid). Returns the round number
// on success, or null if bidding is unavailable.
export async function bidNextRound(pub, account, cfg, amount) {
  try {
    if (amount === undefined) {
      const reserve = await dynamicReserve(cfg);
      // 2.5x reserve, with a 0.005 WETH floor to outbid the standing rival.
      amount = reserve * 5n / 2n;
      const floor = 5_000_000_000_000_000n;
      if (amount < floor) amount = floor;
    }
    const timing = await pub.readContract({ address: cfg.auction, abi: AUCTION_ABI, functionName: 'roundTimingInfo' });
    const round = Number(await pub.readContract({ address: cfg.auction, abi: AUCTION_ABI, functionName: 'currentRound' }));
    const bidRound = round + 1;
    const sig = await account.signTypedData({
      domain: { name: 'ExpressLaneAuction', version: '1', chainId: cfg.chainId, verifyingContract: cfg.auction },
      types: { Bid: [{ name: 'round', type: 'uint64' }, { name: 'expressLaneController', type: 'address' }, { name: 'amount', type: 'uint256' }] },
      primaryType: 'Bid',
      message: { round: BigInt(bidRound), expressLaneController: account.address, amount },
    });
    const res = await rpc(cfg.auctioneer, 'auctioneer_submitBid', [{ chainId: cfg.hexChainId, expressLaneController: account.address, auctionContractAddress: cfg.auction, round: `0x${bidRound.toString(16)}`, amount: `0x${amount.toString(16)}`, signature: sig }]);
    if (res.error) return { bidRound, ok: false, error: res.error.message };
    return { bidRound, ok: true };
  } catch (e) {
    return { bidRound: null, ok: false, error: String(e?.message || e) };
  }
}

// Submit a pre-signed tx through the express lane for a round we control.
export async function sendExpressLane(cfg, account, signedTx, round, seq = 0n) {
  const sigData = concat([
    keccak256(toHex('TIMEBOOST_BID')), pad(cfg.hexChainId), cfg.auction,
    toHex(numberToBytes(BigInt(round), { size: 8 })), toHex(numberToBytes(seq, { size: 8 })), signedTx,
  ]);
  const env = await account.signMessage({ message: { raw: sigData } });
  return rpc(cfg.rpc, 'timeboost_sendExpressLaneTransaction', [{
    chainId: cfg.hexChainId, round: `0x${round.toString(16)}`, auctionContractAddress: cfg.auction,
    sequenceNumber: `0x${seq.toString(16)}`, transaction: signedTx, options: {}, signature: env,
  }]);
}
