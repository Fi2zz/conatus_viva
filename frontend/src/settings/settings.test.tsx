import { renderToString } from "react-dom/server";
import { describe, expect, it } from "vitest";
import SettingsDialog from "./SettingsDialog";
import { buildSettingsInput, clearSettingsInput, initialDraft } from "./settings";

const unconfigured = {
  dashscope_configured: false,
  workspace_id: "",
  oss_configured: false,
};

describe("settings dialog", () => {
  it("renders unconfigured status and never renders a secret value", () => {
    const html = renderToString(
      <SettingsDialog initialStatus={unconfigured} onClose={() => {}} />,
    );
    expect(html).toContain("未配置");
    expect(html).toContain("DASHSCOPE_API_KEY");
    expect(html).not.toContain("sk-live");
  });

  it("shows configured status without echoing the key", () => {
    const html = renderToString(
      <SettingsDialog
        initialStatus={{
          dashscope_configured: true,
          workspace_id: "ws-1",
          oss_configured: true,
        }}
        onClose={() => {}}
      />,
    );
    expect(html).toContain("已配置");
    expect(html).toContain("留空不修改");
    expect(html).toContain("ws-1");
  });
});

describe("settings payload", () => {
  it("blank secret fields mean unchanged", () => {
    const payload = buildSettingsInput({
      ...initialDraft(unconfigured),
      workspaceId: "ws-2",
    });
    expect(payload).toEqual({ workspace_id: "ws-2" });
  });

  it("typed secrets are trimmed and included", () => {
    const payload = buildSettingsInput({
      apiKey: "  sk-test  ",
      workspaceId: "",
      ossAccessKeyId: " id ",
      ossAccessKeySecret: " secret ",
    });
    expect(payload).toEqual({
      dashscope_api_key: "sk-test",
      workspace_id: "",
      oss_access_key_id: "id",
      oss_access_key_secret: "secret",
    });
  });

  it("clear payload blanks every field", () => {
    expect(clearSettingsInput()).toEqual({
      dashscope_api_key: "",
      workspace_id: "",
      oss_access_key_id: "",
      oss_access_key_secret: "",
    });
  });
});
