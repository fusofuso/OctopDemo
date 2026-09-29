"""Unit tests for intranet unified-auth (CMS) token decoding."""

from __future__ import annotations

import time
from typing import Any

import jwt
import pytest

from octop.infra.auth.uni.token import (
    UniTokenError,
    decode_uni_token,
    identity_from_claims,
)

_SECRET = b"x" * 32
_ISSUER = "cms"
_AUDIENCE = "1001"


def _claims(**overrides: Any) -> dict[str, Any]:
    """The claim shape documented for the intranet unified-auth token."""
    base: dict[str, Any] = {
        "iss": _ISSUER,
        "userAccount": "liuhs",
        "userName": "刘华松",
        "userId": "UR1000007180",
        "_userId": "UR1000007180",
        "_uid_": "UR1000007180",
        "aud": _AUDIENCE,
        "ept": 525600,
        "exp": int(time.time()) + 3600,
        "atp": "security",
    }
    base.update(overrides)
    return base


def _encode(claims: dict[str, Any], *, secret: bytes = _SECRET) -> str:
    return jwt.encode(claims, secret, algorithm="HS256")


def test_identity_mapping_uses_documented_claims() -> None:
    identity = identity_from_claims(_claims())
    assert identity.subject == "UR1000007180"
    assert identity.username == "liuhs"
    assert identity.display_name == "刘华松"
    assert identity.claims() == {"preferred_username": "liuhs", "name": "刘华松"}


def test_identity_falls_back_to_user_id_without_an_account() -> None:
    identity = identity_from_claims(_claims(userAccount=None))
    assert identity.username == "UR1000007180"


def test_identity_requires_a_user_id() -> None:
    with pytest.raises(UniTokenError, match="no user id"):
        identity_from_claims({"iss": _ISSUER, "aud": _AUDIENCE})


def test_decode_accepts_an_unverified_token() -> None:
    claims = decode_uni_token(
        _encode(_claims()),
        issuer=_ISSUER,
        audience=_AUDIENCE,
        verify_signature=False,
    )
    assert claims["userAccount"] == "liuhs"


def test_decode_enforces_issuer_and_audience_without_a_signature() -> None:
    token = _encode(_claims())
    with pytest.raises(UniTokenError):
        decode_uni_token(token, issuer="other", audience=_AUDIENCE, verify_signature=False)
    with pytest.raises(UniTokenError):
        decode_uni_token(token, issuer=_ISSUER, audience="9999", verify_signature=False)


def test_decode_rejects_an_expired_token() -> None:
    token = _encode(_claims(exp=int(time.time()) - 120))
    with pytest.raises(UniTokenError, match="expired"):
        decode_uni_token(token, issuer=_ISSUER, audience=_AUDIENCE, verify_signature=False)


def test_decode_rejects_an_empty_token() -> None:
    with pytest.raises(UniTokenError, match="empty"):
        decode_uni_token("  ", issuer=None, audience=None, verify_signature=False)


def test_signature_verification_requires_a_key() -> None:
    with pytest.raises(UniTokenError, match="configured key"):
        decode_uni_token(_encode(_claims()), issuer=None, audience=None, verify_signature=True)


def test_signature_verification_accepts_the_matching_key() -> None:
    claims = decode_uni_token(
        _encode(_claims()),
        issuer=_ISSUER,
        audience=_AUDIENCE,
        verify_signature=True,
        secret=_SECRET,
    )
    assert claims["userId"] == "UR1000007180"


def test_signature_verification_rejects_a_forged_token() -> None:
    with pytest.raises(UniTokenError):
        decode_uni_token(
            _encode(_claims(), secret=b"y" * 32),
            issuer=_ISSUER,
            audience=_AUDIENCE,
            verify_signature=True,
            secret=_SECRET,
        )
