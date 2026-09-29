import { describe, expect, it } from "vitest";
import { buildUniLoginUrl, readUniToken } from "./uniAuth";
import type { UniAuthStatus } from "../../api/modules/auth";

const BASE: UniAuthStatus = {
  enabled: true,
  login_path: "/cmsCrm/crm/uni/oa/login",
  return_host_suffix: "/cmsCrm",
};

describe("buildUniLoginUrl", () => {
  it("resolves a relative relay path against the current origin", () => {
    const url = buildUniLoginUrl(BASE, "http://octop.example/chat");
    expect(url).toBe(
      `${window.location.origin}/cmsCrm/crm/uni/oa/login?RETURN_HOST=${
        window.location.origin
      }/cmsCrm&RETURN_URL=${encodeURIComponent("http://octop.example/chat")}`,
    );
  });

  it("uses an absolute relay path verbatim", () => {
    const url = buildUniLoginUrl(
      { ...BASE, login_path: "http://172.253.170.71/cmsCrm/crm/uni/oa/login" },
      "http://172.253.170.71:8088/login",
    );
    expect(url).toBe(
      `http://172.253.170.71/cmsCrm/crm/uni/oa/login?RETURN_HOST=${
        window.location.origin
      }/cmsCrm&RETURN_URL=${encodeURIComponent(
        "http://172.253.170.71:8088/login",
      )}`,
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
