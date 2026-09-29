"""Intranet unified-auth (CMS) token-relay routes."""

from __future__ import annotations

from typing import Any, cast

from fastapi import APIRouter, Depends
from pydantic import BaseModel, Field

from octop.api.deps import get_server, sign_token
from octop.api.routers.auth import _user_json
from octop.infra.auth.uni.service import UniAuthService

router = APIRouter()


class UniExchangeBody(BaseModel):
    token: str = Field(min_length=1, max_length=16384)


def _service(server: Any) -> UniAuthService:
    return cast(UniAuthService, server.uni_auth_service)


@router.get("/uni/status", summary="Unified-auth login availability")
async def uni_status(server: Any = Depends(get_server)) -> dict[str, Any]:
    """Return whether unified-auth login is available and the CMS relay settings.

    The CMS relay URL is built by the dashboard from these fields, because only
    the browser knows the origin the user is currently on.
    """
    return _service(server).status()


@router.post("/uni/exchange", summary="Exchange a unified-auth token")
async def uni_exchange(body: UniExchangeBody, server: Any = Depends(get_server)) -> dict[str, Any]:
    """Exchange a CMS ``auth.token`` for the standard Octop JWT login response."""
    user = await _service(server).exchange(body.token)
    secret = server.services.secret_repo.get("jwt")
    ttl = server.services.config.access_token_ttl_seconds
    return {
        "access_token": sign_token(
            secret, sub=user.id, uname=user.username, role=user.role, ttl_seconds=ttl
        ),
        "token_type": "Bearer",
        "expires_in": ttl,
        "user": _user_json(user, locale=user.locale),
    }
