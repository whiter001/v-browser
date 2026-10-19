import { describe, it, expect } from "vitest";
import { decideAuthToken } from "./authToken";

describe("decideAuthToken", () => {
  it("URL token 与本地凭据一致时自动放行", () => {
    expect(decideAuthToken("stored-token", "stored-token")).toEqual({
      kind: "trusted",
      token: "stored-token",
    });
  });

  it("URL 带 token 但本地还没有凭据时需要显式确认", () => {
    expect(decideAuthToken("fresh-token", "")).toEqual({
      kind: "confirm",
      token: "fresh-token",
      reason: "first-pairing",
    });
  });

  it("URL token 与本地凭据不一致时需要显式确认", () => {
    expect(decideAuthToken("other-token", "stored-token")).toEqual({
      kind: "confirm",
      token: "other-token",
      reason: "credential-change",
    });
  });

  it("URL 没有 token 时沿用本地凭据", () => {
    expect(decideAuthToken("", "stored-token")).toEqual({
      kind: "trusted",
      token: "stored-token",
    });
    expect(decideAuthToken("   ", "")).toEqual({ kind: "trusted", token: "" });
  });

  it("URL token 前后空白不会绕过比较", () => {
    expect(decideAuthToken("  stored-token  ", "stored-token")).toEqual({
      kind: "trusted",
      token: "stored-token",
    });
  });
});
