/// 设置表单的纯函数：把输入拼成 PUT body，避免组件持有业务规则。
import type { SettingsInput, SettingsStatus } from "./api";

export interface SettingsDraft {
  apiKey: string;
  workspaceId: string;
  ossAccessKeyId: string;
  ossAccessKeySecret: string;
}

export const EMPTY_DRAFT: SettingsDraft = {
  apiKey: "",
  workspaceId: "",
  ossAccessKeyId: "",
  ossAccessKeySecret: "",
};

/// 空白密钥字段表示「不修改」；workspace 始终提交当前值，便于清空。
export function buildSettingsInput(draft: SettingsDraft): SettingsInput {
  const input: SettingsInput = {};
  const apiKey = draft.apiKey.trim();
  if (apiKey !== "") input.dashscope_api_key = apiKey;
  input.workspace_id = draft.workspaceId.trim();
  const ossId = draft.ossAccessKeyId.trim();
  if (ossId !== "") input.oss_access_key_id = ossId;
  const ossSecret = draft.ossAccessKeySecret.trim();
  if (ossSecret !== "") input.oss_access_key_secret = ossSecret;
  return input;
}

/// 清除全部密钥（workspace 也一并清空）。
export function clearSettingsInput(): SettingsInput {
  return {
    dashscope_api_key: "",
    workspace_id: "",
    oss_access_key_id: "",
    oss_access_key_secret: "",
  };
}

export function statusLabel(configured: boolean): string {
  return configured ? "已配置" : "未配置";
}

export function initialDraft(status: SettingsStatus | null): SettingsDraft {
  return {
    ...EMPTY_DRAFT,
    workspaceId: status?.workspace_id ?? "",
  };
}
