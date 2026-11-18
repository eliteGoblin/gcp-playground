import os
import time
from collections.abc import Callable
from functools import lru_cache
from typing import Annotated

import jwt
from fastapi import Depends, FastAPI, Header, HTTPException, Request, Response
from prometheus_client import CONTENT_TYPE_LATEST, Counter, Histogram, generate_latest

# Internal service: no route from the internet. Callers prove their identity with a
# Kubernetes ServiceAccount token (JWT) that the kubelet issues for the audience below.
AUDIENCE = "inventory-api"

STOCK = {"milk": 120, "bread": 40, "eggs": 60, "book": 7}

app = FastAPI(title="inventory-api")

REQUESTS = Counter("http_requests_total", "HTTP requests", ["method", "path", "status"])
LATENCY = Histogram("http_request_duration_seconds", "HTTP request latency", ["method", "path"])


def issuer() -> str:
    return os.environ["TOKEN_ISSUER"]


def allowed_callers() -> set[str]:
    # Example: system:serviceaccount:orders:orders-api
    return set(os.environ["ALLOWED_CALLERS"].split(","))


@lru_cache
def jwks_client() -> jwt.PyJWKClient:
    # Public keys of the cluster's token issuer. Downloaded once, then cached; no call per request.
    return jwt.PyJWKClient(f"{issuer()}/jwks", cache_keys=True, lifespan=3600)


def signing_key(token: str):
    return jwks_client().get_signing_key_from_jwt(token).key


def caller(authorization: Annotated[str | None, Header()] = None) -> str:
    """Authenticate (valid token for this audience) and authorize (caller is on the allow list)."""
    if not authorization or not authorization.startswith("Bearer "):
        raise HTTPException(status_code=401, detail="missing bearer token")
    token = authorization.removeprefix("Bearer ")
    try:
        claims = jwt.decode(
            token,
            signing_key(token),
            algorithms=["RS256"],
            audience=AUDIENCE,
            issuer=issuer(),
            options={"require": ["exp", "iss", "aud", "sub"]},
        )
    except jwt.PyJWTError as exc:
        raise HTTPException(status_code=401, detail="invalid token") from exc
    if claims["sub"] not in allowed_callers():
        raise HTTPException(status_code=403, detail="caller not allowed")
    return claims["sub"]


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


@app.get("/stock/{item}")
def stock(item: str, sub: Annotated[str, Depends(caller)]) -> dict:
    return {"item": item, "available": STOCK.get(item, 0), "caller": sub}
