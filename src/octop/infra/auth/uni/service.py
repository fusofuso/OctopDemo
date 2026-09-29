"""Intranet unified-auth (CMS) login: exchange an external token for an Octop user.

The external token establishes identity only. Roles, permissions and policy come
from the local Octop user record, so a token cannot grant more than the
auto-provisioned account already has.
"""

from __future__ import annotations

import logging
from typing import Any

from octop.config import UniAuthConfig
from octop.infra.auth.uni.token import UniTokenError, decode_uni_token, identity_from_claims
from octop.infra.db.services import SharedServices
from octop.infra.errors import ErrorCode, OctopError
from octop.infra.users.identity import User
from octop.infra.users.manager import UserManager

logger = logging.getLogger(__name__)

# SSO provider kind used to scope unified-auth identities in ``user_sso_identities``.
UNI_PROVIDER_KIND = "uni"
UNI_PROVIDER_NAME = "Unified Auth"
# ``secret_repo`` key holding the CMS signing key (only used with verify_signature).
_SIGNING_SECRET_KEY = "uni_auth"


class UniAuthService:
    """Owns the ``uni`` SSO provider row and the token → user exchange."""

    def __init__(self, services: SharedServices, user_manager: UserManager) -> None:
        self._services = services
        self._user_manager = user_manager
        self._cached_provider_id: int | None = None
        cfg = self._config()
        if cfg.enabled and not cfg.verify_signature:
            logger.warning(
                "unified auth is enabled without signature verification; "
                "any client that can reach this port can impersonate a user"
            )

    async def exchange(self, token: str) -> User:
        """Resolve (or auto-provision) the local user behind a unified-auth token."""
        cfg = self._config()
        if not cfg.enabled:
            raise OctopError(ErrorCode.AUTH_FAILED, "unified auth is disabled")
        if self._user_manager.count() == 0:
            raise OctopError(ErrorCode.SETUP_REQUIRED, "initial admin not created")
        try:
            claims = decode_uni_token(
                token,
                issuer=cfg.issuer or None,
                audience=cfg.audience or None,
                verify_signature=cfg.verify_signature,
                secret=self._signing_secret() if cfg.verify_signature else None,
            )
            identity = identity_from_claims(claims)
        except UniTokenError as exc:
            raise OctopError(ErrorCode.AUTH_FAILED, "invalid unified-auth token") from exc

        user = await self._user_manager.resolve_or_create_sso_user(
            provider_id=self._provider_row_id(),
            subject=identity.subject,
            claims=identity.claims(),
        )
        self._services.audit_repo.write(
            actor=user.username, action="auth.uni_login", target=user.username
        )
        return user

    def status(self) -> dict[str, Any]:
        """Public login-page config; no secrets are exposed."""
        cfg = self._config()
        return {
            "enabled": bool(cfg.enabled and self._user_manager.count() > 0),
            "login_path": cfg.login_path,
            "return_host_suffix": cfg.return_host_suffix,
        }

    def _config(self) -> UniAuthConfig:
        return self._services.config.uni_auth

    def _signing_secret(self) -> bytes | None:
        return self._services.secret_repo.get(_SIGNING_SECRET_KEY)

    def _provider_row_id(self) -> int:
        """Return the ``uni`` provider row id, creating it on first use."""
        if self._cached_provider_id is None:
            row = self._services.sso_repo.get_by_kind(UNI_PROVIDER_KIND)
            if row is None:
                cfg = self._config()
                row = self._services.sso_repo.upsert_by_kind(
                    UNI_PROVIDER_KIND,
                    enabled=True,
                    display_name=UNI_PROVIDER_NAME,
                    issuer=cfg.issuer,
                    client_id=cfg.audience,
                    client_secret_enc=None,
                    scopes="",
                    dashboard_origin=None,
                    extra={},
                )
            self._cached_provider_id = row.id
        return self._cached_provider_id
