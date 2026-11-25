// Traffic generator for ShopLite. Sends a realistic mix of requests to the gateway.
//   node tools/load.js                 # 60 s at ~4 req/s against http://localhost:3000
//   node tools/load.js 120 8           # 120 s at ~8 req/s
//   GATEWAY_URL=http://localhost:3000 node tools/load.js
const BASE = process.env.GATEWAY_URL || 'http://localhost:3000';
const seconds = Number(process.argv[2] || 60);
const perSecond = Number(process.argv[3] || 4);

// weight = how often each request is picked
const MIX = [
  { w: 45, name: 'list products', run: () => fetch(`${BASE}/api/products`) },
  { w: 30, name: 'checkout', run: () => fetch(`${BASE}/api/checkout`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ productId: 1 + Math.floor(Math.random() * 20), quantity: 1 + Math.floor(Math.random() * 3), userId: `user-${1 + Math.floor(Math.random() * 50)}` }),
    }) },
  { w: 10, name: 'slow', run: () => fetch(`${BASE}/api/slow?ms=${800 + Math.floor(Math.random() * 1200)}`) },
  { w: 5, name: 'error', run: () => fetch(`${BASE}/api/error`) },
  { w: 10, name: 'missing product', run: () => fetch(`${BASE}/api/checkout`, {
      method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ productId: 999 }) }) },
];
const total = MIX.reduce((s, m) => s + m.w, 0);
const pick = () => { let r = Math.random() * total; for (const m of MIX) { if ((r -= m.w) < 0) return m; } return MIX[0]; };

const stats = {};
const end = Date.now() + seconds * 1000;
console.log(`load: ${perSecond} req/s for ${seconds}s against ${BASE}`);

const timer = setInterval(async () => {
  if (Date.now() > end) {
    clearInterval(timer);
    setTimeout(() => { console.table(stats); }, 2500);
    return;
  }
  const m = pick();
  const key = m.name;
  stats[key] ??= { sent: 0, ok: 0, failed: 0 };
  stats[key].sent++;
  try {
    const res = await m.run();
    await res.arrayBuffer();
    res.ok ? stats[key].ok++ : stats[key].failed++;
  } catch {
    stats[key].failed++;
  }
}, 1000 / perSecond);
