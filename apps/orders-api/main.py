import json
import os
import time
import uuid
from collections.abc import Callable
from functools import lru_cache

from fastapi import FastAPI, HTTPException, Request, Response
from google.cloud import pubsub_v1
from prometheus_client import CONTENT_TYPE_LATEST, Counter, Histogram, generate_latest
from pydantic import BaseModel, Field

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


@app.get("/metrics")
def metrics() -> Response:
    return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)


@app.post("/orders", status_code=202)
def create_order(order: Order) -> dict:
    order_id = str(uuid.uuid4())
    payload = {"order_id": order_id, **order.model_dump()}
    try:
        get_publisher().publish(topic_path(), json.dumps(payload).encode()).result(timeout=10)
    except Exception as exc:
        raise HTTPException(status_code=503, detail="publish failed") from exc
    return {"order_id": order_id}
