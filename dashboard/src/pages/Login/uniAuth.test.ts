import { describe, expect, it } from "vitest";
import { buildUniLoginUrl, readUniToken } from "./uniAuth";
import type { UniAuthStatus } from "../../api/modules/auth";

const BASE: UniAuthStatus = {
  enabled: true,
  login_path: "/cmsCrm/crm/uni/oa/login",
  return_host_suffix: "/cmsCrm",
};

describe("buildUniLoginUrl", () => {
  it("keeps the relay path relative to the current origin", () => {
    const url = buildUniLoginUrl(BASE, "http://octop.example/chat");
    expect(url).toBe(
      `/cmsCrm/crm/uni/oa/login?RETURN_HOST=${
        window.location.origin
      }/cmsCrm&RETURN_URL=${encodeURIComponent("http://octop.example/chat")}`,
    );
  });

  it("encodes the return URL so its query string survives", () => {
    const url = buildUniLoginUrl(BASE, "http://octop.example/chat?tab=1");
    expect(url).toContain(
      `RETURN_URL=${encodeURIComponent("http://octop.example/chat?tab=1")}`,
    );
  });
});

describe("readUniToken", () => {
  it("reads the dotted query parameter", () => {
    expect(readUniToken("?foo=1&auth.token=abc.def")).toBe("abc.def");
  });

  it("returns null when the parameter is absent or blank", () => {
    expect(readUniToken("?foo=1")).toBeNull();
    expect(readUniToken("?auth.token=")).toBeNull();
  });
});
