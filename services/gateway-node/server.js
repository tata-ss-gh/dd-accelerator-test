// ShopLite gateway: the entry point for the browser.
// Calls catalog (Python) and orders (Java) so one request becomes a distributed trace.
//
// Tracing: the Datadog tracer is loaded before this file by the start command
//   node -r dd-trace/init server.js
// and configured with DD_* environment variables (DD_SERVICE, DD_ENV, DD_VERSION, DD_LOGS_INJECTION, ...).
// require('dd-trace') below returns that same, already started tracer.
const tracer = require('dd-trace');
const path = require('path');
const fs = require('fs');
const express = require('express');

// Structured JSON logs, written to a file that the Datadog Agent tails.
// With DD_LOGS_INJECTION=true the tracer adds dd.trace_id / dd.span_id to every line written
// during a request, which links each log line to its trace.
const pino = require('pino');
const logDir = process.env.LOG_DIR || path.join(__dirname, '../../logs');
fs.mkdirSync(logDir, { recursive: true });
const log = pino(
  {
    level: 'info',
    base: { service: 'gateway' },
    messageKey: 'message',
    timestamp: () => `,"timestamp":"${new Date().toISOString()}"`,
    formatters: { level: (label) => ({ level: label }) },   // "level":"error" instead of 50
    serializers: { error: pino.stdSerializers.err },         // error.type / error.message / error.stack
  },
  pino.destination({ dest: path.join(logDir, 'gateway.json'), sync: false }),
);

const PORT = Number(process.env.GATEWAY_PORT || 3000);
const CATALOG_URL = process.env.CATALOG_URL || 'http://localhost:8001';
const ORDERS_URL = process.env.ORDERS_URL || 'http://localhost:8002';

const app = express();
app.use(express.json());
app.use(express.static(path.join(__dirname, '../../frontend')));

// Browser RUM settings for frontend/index.html. The RUM application id and client token
// are public by design: they ship to every browser and can only send RUM data.
app.get('/rum-config.js', (req, res) => {
  const cfg = {
    env: process.env.DD_ENV || 'dev',
    applicationId: process.env.DD_RUM_APP_ID || '',
    clientToken: process.env.DD_RUM_CLIENT_TOKEN || '',
    site: process.env.DD_SITE || 'datadoghq.com',
  };
  res.type('application/javascript').send(`window.SHOPLITE_RUM = ${JSON.stringify(cfg).replace(/</g, '\\u003c')};`);
});

// Custom business metrics via DogStatsD (UDP :8125 on the local Datadog Agent). The tracer
// adds env/service/version tags. Every unique tag combination is one billable custom metric.
const statsd = tracer.dogstatsd;
let inflight = 0;
function checkoutMetrics(result, total, productId, userId) {
  statsd.increment('shoplite.checkout.count', 1, { result });             // COUNT: rate of checkouts
  statsd.gauge('shoplite.gateway.checkouts_inflight', inflight);         // GAUGE: last value wins
  if (result !== 'paid') return;
  statsd.distribution('shoplite.checkout.amount', total, { product_id: String(productId) }); // global percentiles
  statsd.histogram('shoplite.checkout.amount_hist', total);              // agent-side avg/max/p95 per host
  // ANTI-PATTERN on purpose: a user id tag makes one time series per user (cardinality = cost).
  statsd.increment('shoplite.checkout.by_user', 1, { user_id: String(userId) });
}

// A custom span around code that nothing auto-instruments. It ends when the promise settles.
function customSpan(name, fn) {
  return tracer.trace(name, { type: 'app' }, () => fn());
}

// Tag the request span. With DD_TRACE_MIDDLEWARE_TRACING_ENABLED=false (see the start script)
// the active span inside a route handler is the request span itself.
function addTag(key, value) {
  tracer.scope().active()?.setTag(key, value);   // numbers stay numeric (measures)
}

async function getJson(url, options) {
  const res = await fetch(url, options); // fetch (undici) is auto-instrumented
  const body = await res.json().catch(() => ({}));
  if (!res.ok) {
    const err = new Error(`${options?.method || 'GET'} ${url} -> ${res.status}: ${body.error || ''}`);
    err.status = res.status;
    throw err;
  }
  return body;
}

app.get('/health', (req, res) => res.json({ status: 'ok', service: 'gateway' }));

app.get('/api/products', async (req, res, next) => {
  try {
    res.json(await getJson(`${CATALOG_URL}/products`));
  } catch (e) { next(e); }
});

app.post('/api/checkout', async (req, res, next) => {
  const { productId = 1, quantity = 1, userId = 'guest' } = req.body || {};
  inflight++;
  try {
    tracer.setUser({ id: userId });               // usr.id on the trace
    addTag('product_id', productId);

    log.info({ product_id: productId, quantity, usr: { id: userId } }, 'checkout started');
    const product = await getJson(`${CATALOG_URL}/products/${productId}`);

    const total = await customSpan('calculate-total', async () => {
      await new Promise((r) => setTimeout(r, 15));
      return Math.round(product.price * quantity * 100) / 100;
    });
    addTag('order_total', total);

    const order = await getJson(`${ORDERS_URL}/orders`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ productId, quantity, userId, amount: total }),
    });
    log.info({ order_id: order.orderId, order_total: total }, 'checkout completed');
    checkoutMetrics('paid', total, productId, userId);
    res.status(201).json(order);
  } catch (e) {
    checkoutMetrics('failed', 0, productId, userId);
    next(e);
  } finally { inflight--; }
});

// ---- Chaos endpoints for learning ----
app.get('/api/slow', async (req, res) => {
  const ms = Number(req.query.ms || 1500);
  await customSpan('deliberate-sleep', () => new Promise((r) => setTimeout(r, ms)));
  res.json({ sleptMs: ms });
});

app.get('/api/error', () => {
  throw new Error('Deliberate gateway failure (chaos endpoint)');
});

// Express error handler. The tracer marks the request span as an error automatically.
app.use((err, req, res, _next) => {
  log.error({ error: err, url: req.originalUrl }, `request failed: ${err.message}`);
  res.status(err.status && err.status < 600 ? 502 : 500).json({ error: err.message });
});

app.listen(PORT, () => console.log(`[gateway] listening on http://localhost:${PORT}`));
