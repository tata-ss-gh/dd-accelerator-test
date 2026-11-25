"""ShopLite catalog service (Python / FastAPI + SQLite).

Tracing: run under the Datadog tracer, configured with DD_* environment variables:
    ddtrace-run uvicorn app:app --port 8001
ddtrace patches FastAPI, sqlite3 and logging automatically. The code below adds custom
spans and tags with the ddtrace API, and custom metrics with DogStatsD.
"""
import logging
import os
import random
import sqlite3
import time
from contextlib import contextmanager
from pathlib import Path

from datadog import DogStatsd
from ddtrace.trace import tracer
from fastapi import FastAPI, HTTPException
from pythonjsonlogger.json import JsonFormatter

DB_PATH = Path(__file__).with_name("catalog.db")

app = FastAPI(title="catalog")

# ---------------------------------------------------------------- logs
# JSON lines to a file the Datadog Agent tails. With DD_LOGS_INJECTION=true, ddtrace adds
# dd.trace_id / dd.span_id / dd.service / dd.env / dd.version to every record.
_log_dir = Path(os.getenv("LOG_DIR") or Path(__file__).resolve().parents[2] / "logs")
_log_dir.mkdir(parents=True, exist_ok=True)
_handler = logging.FileHandler(_log_dir / "catalog.json", encoding="utf-8")
_handler.setFormatter(JsonFormatter(
    "%(levelname)s %(name)s %(message)s",
    rename_fields={"levelname": "level", "name": "logger_name"},
    timestamp=True,
))
log = logging.getLogger("catalog")
log.setLevel(logging.INFO)
log.addHandler(_handler)

# ---------------------------------------------------------------- metrics
# DogStatsD to the local Datadog Agent (UDP :8125). DD_ENV / DD_SERVICE / DD_VERSION become tags.
statsd = DogStatsd(host=os.getenv("DD_AGENT_HOST", "localhost"), port=8125)


def add_tag(key, value):
    """Tag the request (root) span. Numbers go in as metrics so they can be range-filtered."""
    span = tracer.current_root_span()
    if span is not None:
        (span.set_metric if isinstance(value, (int, float)) else span.set_tag)(key, value)


# ---------------------------------------------------------------- database
@contextmanager
def db():
    conn = sqlite3.connect(DB_PATH)   # patched by ddtrace: every query becomes a span
    try:
        with conn:                    # commit on success, roll back on error
            yield conn
    finally:
        conn.close()


def sql(conn, statement, params=()):
    cur = conn.cursor()
    cur.execute(statement, params)
    return cur


def init_db():
    with db() as conn:
        conn.execute("CREATE TABLE IF NOT EXISTS products (id INTEGER PRIMARY KEY, name TEXT, price REAL, category_id INTEGER)")
        conn.execute("CREATE TABLE IF NOT EXISTS categories (id INTEGER PRIMARY KEY, name TEXT)")
        if conn.execute("SELECT COUNT(*) FROM products").fetchone()[0] == 0:
            conn.executemany("INSERT INTO categories VALUES (?, ?)",
                             [(1, "Books"), (2, "Electronics"), (3, "Garden")])
            conn.executemany("INSERT INTO products VALUES (?, ?, ?, ?)", [
                (i, f"Product {i}", round(random.uniform(5, 200), 2), (i % 3) + 1)
                for i in range(1, 21)
            ])


init_db()


# ---------------------------------------------------------------- routes
@app.get("/health")
def health():
    return {"status": "ok", "service": "catalog"}


@app.get("/products")
def list_products():
    with db() as conn:
        rows = sql(conn,
            "SELECT p.id, p.name, p.price, c.name FROM products p JOIN categories c ON c.id = p.category_id"
        ).fetchall()
    return [{"id": r[0], "name": r[1], "price": r[2], "category": r[3]} for r in rows]


@app.get("/products/{product_id}")
def get_product(product_id: int):
    add_tag("product_id", product_id)
    with db() as conn:
        row = sql(conn, "SELECT id, name, price FROM products WHERE id = ?", (product_id,)).fetchone()
    if not row:
        log.warning("product not found", extra={"product_id": product_id})
        raise HTTPException(status_code=404, detail="product not found")
    return {"id": row[0], "name": row[1], "price": apply_pricing(row[2])}


@tracer.wrap(name="apply-pricing-rules", span_type="app")   # custom span
def apply_pricing(price):
    time.sleep(random.uniform(0.005, 0.03))  # pretend business logic
    return price


# ---- chaos endpoints ----
@app.get("/n-plus-one")
def n_plus_one():
    """Classic anti-pattern: 1 query for the list + 1 query per row. Look at the trace waterfall."""
    with db() as conn:
        ids = [r[0] for r in sql(conn, "SELECT id FROM products").fetchall()]
        out = []
        for pid in ids:
            out.append(sql(conn, "SELECT name, price FROM products WHERE id = ?", (pid,)).fetchone())
    log.info("n-plus-one report built with %d queries", len(out) + 1)
    statsd.histogram("shoplite.catalog.db_queries_per_request", len(out) + 1, tags=["endpoint:n-plus-one"])
    return {"count": len(out)}


@app.get("/slow")
def slow(ms: int = 1200):
    time.sleep(ms / 1000)
    return {"slept_ms": ms}


@app.get("/error")
def error():
    raise RuntimeError("Deliberate catalog failure (chaos endpoint)")
