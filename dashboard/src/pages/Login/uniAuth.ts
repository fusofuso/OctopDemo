import { getRememberLoginPreference, setAuthToken } from "../../api";
import {
  authApi,
  type LoginResponse,
  type UniAuthStatus,
} from "../../api/modules/auth";

/**
 * Query parameter the intranet unified-auth (CMS) relay appends to the return
 * URL. Fixed by the CMS contract, so it is not configurable.
 */
export const UNI_TOKEN_PARAM = "auth.token";

/**
 * Build the CMS login relay URL.
 *
 * Mirrors the CMS hand-off contract: ``RETURN_HOST`` is the local origin plus
 * the deployment path prefix, ``RETURN_URL`` is the page to come back to.
 *
 * ``login_path`` may be an absolute ``http(s)://`` URL — required when Octop is
 * reached on a different origin than the relay (e.g. Octop on ``:8088`` behind a
 * cloud gateway on ``:80``).
 */
export function buildUniLoginUrl(
  status: UniAuthStatus,
  currentUrl: string,
): string {
  const origin = window.location.origin;
  const relay = /^https?:\/\//i.test(status.login_path)
    ? status.login_path
    : `${origin}${status.login_path}`;
  const returnHost = `${origin}${status.return_host_suffix}`;
  return `${relay}?RETURN_HOST=${returnHost}&RETURN_URL=${encodeURIComponent(
    currentUrl,
  )}`;
}

/** Read the one-time CMS token from the current URL, if present. */
export function readUniToken(
  search: string = window.location.search,
): string | null {
  const token = new URLSearchParams(search).get(UNI_TOKEN_PARAM);
  return token && token.trim() ? token : null;
}

/** Drop the one-time CMS token from the address bar before any network call. */
export function stripUniToken(): void {
  const url = new URL(window.location.href);
  if (!url.searchParams.has(UNI_TOKEN_PARAM)) return;
  url.searchParams.delete(UNI_TOKEN_PARAM);
  window.history.replaceState(
    null,
    "",
    `${url.pathname}${url.search}${url.hash}`,
  );
}

/** Exchange the CMS token for an Octop session token and persist it. */
export async function completeUniLogin(token: string): Promise<LoginResponse> {
  const res = await authApi.exchangeUniToken(token);
  setAuthToken(res.access_token, getRememberLoginPreference());
  return res;
}
