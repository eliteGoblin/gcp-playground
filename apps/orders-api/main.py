import json
import os
import time
import urllib.parse
import urllib.request
import uuid
from collections.abc import Callable
from functools import lru_cache
from pathlib import Path

from fastapi import FastAPI, HTTPException, Request, Response
from google.cloud import pubsub_v1
from prometheus_client import CONTENT_TYPE_LATEST, Counter, Histogram, generate_latest
from pydantic import BaseModel, Field

VERSION = "1.2.0"

app = FastAPI(title="orders-api")

REQUESTS = Counter("http_requests_total", "HTTP requests", ["method", "path", "status"])
LATENCY = Histogram("http_request_duration_seconds", "HTTP request latency", ["method", "path"])


class Order(BaseModel):
    item: str = Field(min_length=1, max_length=100)
    quantity: int = Field(gt=0, le=1000)


@lru_cache
def get_publisher() -> pubsub_v1.PublisherClient:
    return pubsub_v1.PublisherClient()


def topic_path() -> str:
    return get_publisher().topic_path(os.environ["GCP_PROJECT_ID"], os.environ["PUBSUB_TOPIC"])


def check_stock(item: str) -> int | None:
    """Ask inventory-api how many units are available. None = the integration is not configured."""
    base = os.environ.get("INVENTORY_URL")
    if not base:
        return None
    if not base.startswith(("http://", "https://")):
        raise ValueError("INVENTORY_URL must be an http(s) URL")
    # ServiceAccount token for the audience "inventory-api". The kubelet writes and renews this file
    # (projected volume), so read it for each call.
    token = Path(os.environ.get("INVENTORY_TOKEN_PATH", "/var/run/secrets/tokens/inventory-api")).read_text().strip()
    request = urllib.request.Request(
        f"{base}/stock/{urllib.parse.quote(item, safe='')}",
        headers={"Authorization": f"Bearer {token}"},
    )
    with urllib.request.urlopen(request, timeout=3) as response:
        return json.load(response)["available"]


@app.middleware("http")
async def record_metrics(request: Request, call_next: Callable) -> Response:
    start = time.perf_counter()
    status = 500
    try:
        response = await call_next(request)
        status = response.status_code
        return response
    finally:
        route = request.scope.get("route")
        path = route.path if route else "unmatched"
        LATENCY.labels(request.method, path).observe(time.perf_counter() - start)
        REQUESTS.labels(request.method, path, str(status)).inc()


@app.get("/healthz")
def healthz() -> dict:
    return {"status": "ok"}


@app.get("/version")
def version() -> dict:
    # Shows which release answers a request, for example during a canary.
    return {"version": VERSION}


@app.get("/metrics")
def metrics() -> Response:
    return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)


@app.post("/orders", status_code=202)
def create_order(order: Order) -> dict:
    try:
        available = check_stock(order.item)
    except Exception as exc:
        raise HTTPException(status_code=503, detail="inventory check failed") from exc
    if available is not None and available < order.quantity:
        raise HTTPException(status_code=409, detail="not enough stock")
    order_id = str(uuid.uuid4())
    payload = {"order_id": order_id, **order.model_dump()}
    try:
        get_publisher().publish(topic_path(), json.dumps(payload).encode()).result(timeout=10)
    except Exception as exc:
        raise HTTPException(status_code=503, detail="publish failed") from exc
    return {"order_id": order_id}
