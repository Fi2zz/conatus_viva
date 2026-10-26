/// `/api/settings` 客户端；只读状态，写入时不回显密钥。
export interface SettingsStatus {
  dashscope_configured: boolean;
  workspace_id: string;
  oss_configured: boolean;
}

export interface SettingsInput {
  dashscope_api_key?: string;
  workspace_id?: string;
  oss_access_key_id?: string;
  oss_access_key_secret?: string;
}

export class SettingsApiError extends Error {
  readonly status: number;

  constructor(status: number, message: string) {
    super(message);
    this.name = "SettingsApiError";
    this.status = status;
  }
}

async function request<T>(path: string, init?: RequestInit): Promise<T> {
  let response: Response;
  try {
    response = await fetch(path, init);
  } catch (error) {
    throw new SettingsApiError(0, `网络错误：${String(error)}`);
  }
  const text = await response.text();
  let payload: unknown = null;
  try {
    payload = text === "" ? null : JSON.parse(text);
  } catch {
    payload = null;
  }
  if (!response.ok) {
    const body = payload as { error?: unknown } | null;
    throw new SettingsApiError(
      response.status,
      typeof body?.error === "string" ? body.error : `请求失败（HTTP ${response.status}）`,
    );
  }
  return payload as T;
}

function json(method: string, body: unknown): RequestInit {
  return {
    method,
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  };
}

export const settingsApi = {
  get(): Promise<SettingsStatus> {
    return request("/api/settings");
  },
  save(input: SettingsInput): Promise<SettingsStatus> {
    return request("/api/settings", json("PUT", input));
  },
};
