"""Integration tests for intranet unified-auth (CMS) login."""

from __future__ import annotations

import time
from collections.abc import AsyncIterator
from pathlib import Path
from typing import Any

import httpx
import jwt
import pytest
from tests.support.app import octop_client, write_octop_config
from tests.support.auth import bearer, bootstrap_admin

from octop.infra.server import OctopServer


def cms_token(**overrides: Any) -> str:
    """Build a token shaped like the intranet unified-auth (CMS) one.

    Signed with a throwaway key: Octop does not verify the signature unless
    ``uni_auth.verify_signature`` is enabled.
    """
    claims: dict[str, Any] = {
        "iss": "cms",
        "userAccount": "liuhs",
        "userName": "刘华松",
        "userId": "UR1000007180",
        "aud": "1001",
        "exp": int(time.time()) + 3600,
    }
    claims.update(overrides)
    return jwt.encode(claims, "cms-key-not-shared-with-octop-padding", algorithm="HS256")


@pytest.fixture
async def uni_client(tmp_path: Path) -> AsyncIterator[tuple[httpx.AsyncClient, OctopServer]]:
    write_octop_config(tmp_path, uni_auth={"enabled": True})
    async with octop_client(tmp_path) as (client, srv):
        await bootstrap_admin(client, tmp_path)
        yield client, srv


async def test_status_reports_the_relay_config(
    uni_client: tuple[httpx.AsyncClient, OctopServer],
) -> None:
    client, _srv = uni_client
    r = await client.get("/api/auth/uni/status")
    assert r.status_code == 200
    body = r.json()
    assert body["enabled"] is True
    assert body["login_path"] == "/cmsCrm/crm/uni/oa/login"
    assert body["return_host_suffix"] == "/cmsCrm"


async def test_exchange_auto_provisions_a_non_admin_user(
    uni_client: tuple[httpx.AsyncClient, OctopServer],
) -> None:
    client, srv = uni_client
    r = await client.post("/api/auth/uni/exchange", json={"token": cms_token()})
    assert r.status_code == 200
    body = r.json()
    assert body["token_type"] == "Bearer"
    assert body["user"]["username"] == "liuhs"
    assert body["user"]["display_name"] == "刘华松"
    # Authorization stays local: auto-provisioned users never inherit admin.
    assert body["user"]["role"] != "admin"
    assert srv.user_manager is not None
    provisioned = srv.user_manager.get("liuhs")
    assert provisioned is not None
    assert not provisioned.is_admin

    me = await client.get("/api/auth/me", headers=bearer(body["access_token"]))
    assert me.status_code == 200
    assert me.json()["username"] == "liuhs"


async def test_exchange_ignores_role_claims_from_the_token(
    uni_client: tuple[httpx.AsyncClient, OctopServer],
) -> None:
    client, _srv = uni_client
    r = await client.post(
        "/api/auth/uni/exchange",
        json={"token": cms_token(role="admin", uname="admin", sub="1")},
    )
    assert r.status_code == 200
    assert r.json()["user"]["role"] != "admin"


async def test_exchange_is_idempotent_for_the_same_identity(
    uni_client: tuple[httpx.AsyncClient, OctopServer],
) -> None:
    client, _srv = uni_client
    first = await client.post("/api/auth/uni/exchange", json={"token": cms_token()})
    second = await client.post("/api/auth/uni/exchange", json={"token": cms_token()})
    assert first.json()["user"]["id"] == second.json()["user"]["id"]


async def test_exchange_rejects_an_expired_token(
    uni_client: tuple[httpx.AsyncClient, OctopServer],
) -> None:
    client, srv = uni_client
    r = await client.post(
        "/api/auth/uni/exchange",
        json={"token": cms_token(exp=int(time.time()) - 120)},
    )
    assert r.status_code == 401
    assert r.json()["error"]["code"] == "AUTH_FAILED"
    assert srv.user_manager is not None
    assert srv.user_manager.get("liuhs") is None


@pytest.mark.parametrize("bad", [{"aud": "9999"}, {"iss": "someone-else"}])
async def test_exchange_rejects_wrong_issuer_or_audience(
    uni_client: tuple[httpx.AsyncClient, OctopServer], bad: dict[str, str]
) -> None:
    client, _srv = uni_client
    r = await client.post("/api/auth/uni/exchange", json={"token": cms_token(**bad)})
    assert r.status_code == 401


async def test_disabled_by_default(tmp_path: Path) -> None:
    async with octop_client(tmp_path) as (client, _srv):
        await bootstrap_admin(client, tmp_path)
        status = await client.get("/api/auth/uni/status")
        assert status.status_code == 200
        assert status.json()["enabled"] is False
        r = await client.post("/api/auth/uni/exchange", json={"token": cms_token()})
        assert r.status_code == 401
