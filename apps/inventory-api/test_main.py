import time

import jwt
import pytest
from cryptography.hazmat.primitives.asymmetric import rsa
from fastapi.testclient import TestClient

import main

ISSUER = "https://issuer.example"
ORDERS_API = "system:serviceaccount:orders:orders-api"

KEY = rsa.generate_private_key(public_exponent=65537, key_size=2048)
OTHER_KEY = rsa.generate_private_key(public_exponent=65537, key_size=2048)

client = TestClient(main.app)


@pytest.fixture(autouse=True)
def config(monkeypatch):
    monkeypatch.setenv("TOKEN_ISSUER", ISSUER)
    monkeypatch.setenv("ALLOWED_CALLERS", ORDERS_API)
    monkeypatch.setattr(main, "signing_key", lambda token: KEY.public_key())


def token(key=KEY, **overrides) -> str:
    claims = {"iss": ISSUER, "aud": main.AUDIENCE, "sub": ORDERS_API, "exp": int(time.time()) + 600}
    return jwt.encode(claims | overrides, key, algorithm="RS256")


def get_stock(tok: str | None):
    headers = {"Authorization": f"Bearer {tok}"} if tok else {}
    return client.get("/stock/milk", headers=headers)


def test_valid_token_from_allowed_caller():
    resp = get_stock(token())
    assert resp.status_code == 200
    assert resp.json() == {"item": "milk", "available": 120, "caller": ORDERS_API}


def test_unknown_item_has_no_stock():
    resp = client.get("/stock/caviar", headers={"Authorization": f"Bearer {token()}"})
    assert resp.json()["available"] == 0


def test_no_token_is_401():
    assert get_stock(None).status_code == 401


def test_garbage_token_is_401():
    assert get_stock("not-a-jwt").status_code == 401


def test_token_for_other_audience_is_401():
    assert get_stock(token(aud="payments-api")).status_code == 401


def test_token_from_other_issuer_is_401():
    assert get_stock(token(iss="https://evil.example")).status_code == 401


def test_expired_token_is_401():
    assert get_stock(token(exp=int(time.time()) - 60)).status_code == 401


def test_token_signed_with_other_key_is_401():
    assert get_stock(token(key=OTHER_KEY)).status_code == 401


def test_valid_token_from_other_service_is_403():
    assert get_stock(token(sub="system:serviceaccount:orders:orders-worker")).status_code == 403


def test_healthz_needs_no_token():
    assert client.get("/healthz").json() == {"status": "ok"}
