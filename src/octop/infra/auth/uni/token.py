"""Decode and validate intranet unified-auth (CMS) JWTs.

The CMS token is never used for authorization — only to establish identity.
Signature verification is therefore optional: when the CMS signing key is not
available to Octop, deployments run in "trusted intranet" mode where ``iss``,
``aud`` and ``exp`` are still enforced.
"""

from __future__ import annotations

from collections.abc import Mapping
from dataclasses import dataclass
from typing import Any

import jwt

# Symmetric and asymmetric algorithms a CMS issuer may plausibly use.
_ALLOWED_ALGORITHMS = ("HS256", "HS384", "HS512", "RS256", "RS384", "RS512", "ES256")
_LEEWAY_SECONDS = 60


class UniTokenError(Exception):
    """Raised when the unified-auth token is missing, expired, or malformed."""


def decode_uni_token(
    token: str,
    *,
    issuer: str | None,
    audience: str | None,
    verify_signature: bool,
    secret: bytes | None = None,
) -> dict[str, Any]:
    """Return the claims of ``token``, enforcing expiry and (when configured) iss/aud.

    ``exp`` is always required. ``iss``/``aud`` are checked whenever a value is
    configured, regardless of ``verify_signature`` — PyJWT would otherwise skip
    them once signature verification is turned off.
    """
    if not token or not token.strip():
        raise UniTokenError("unified-auth token is empty")
    if verify_signature and secret is None:
        raise UniTokenError("signature verification requires a configured key")

    options: dict[str, Any] = {
        "verify_signature": verify_signature,
        "verify_exp": True,
        "verify_aud": bool(audience),
        "verify_iss": bool(issuer),
    }
    kwargs: dict[str, Any] = {
        "key": secret or "",
        "algorithms": list(_ALLOWED_ALGORITHMS),
        "options": options,
        "leeway": _LEEWAY_SECONDS,
    }
    if issuer:
        kwargs["issuer"] = issuer
    if audience:
        kwargs["audience"] = audience

    try:
        return dict(jwt.decode(token, **kwargs))
    except jwt.ExpiredSignatureError as exc:
        raise UniTokenError("unified-auth token expired") from exc
    except jwt.InvalidTokenError as exc:
        raise UniTokenError(str(exc)) from exc


@dataclass(frozen=True)
class UniIdentity:
    """Identity established by a unified-auth token."""

    subject: str
    username: str
    display_name: str | None

    def claims(self) -> dict[str, Any]:
        """Shape the identity as OIDC-like claims for ``UserManager`` helpers."""
        claims: dict[str, Any] = {"preferred_username": self.username}
        if self.display_name:
            claims["name"] = self.display_name
        return claims


def _first_string(claims: Mapping[str, Any], names: tuple[str, ...]) -> str | None:
    for name in names:
        value = claims.get(name)
        if isinstance(value, str) and value.strip():
            return value.strip()
    return None


def identity_from_claims(claims: Mapping[str, Any]) -> UniIdentity:
    """Map unified-auth claims onto an ``UniIdentity``.

    ``role`` is deliberately absent from the mapping: the CMS token carries no
    role Octop could trust, so authorization stays with the local user record.
    """
    subject = _first_string(claims, ("userId", "_userId", "_uid_", "sub"))
    if subject is None:
        raise UniTokenError("unified-auth token has no user id")
    username = _first_string(claims, ("userAccount", "preferred_username", "uname")) or subject
    display_name = _first_string(claims, ("userName", "name"))
    return UniIdentity(subject=subject, username=username, display_name=display_name)
