/// 全局设置：录入百炼与 OSS 凭证；只显示配置状态，不回显任何密钥。
///
/// 保存后服务端立即更新运行中的 config，不需要重启应用。
import { useEffect, useState } from "react";
import { settingsApi } from "./api";
import type { SettingsStatus } from "./api";
import {
  buildSettingsInput,
  clearSettingsInput,
  initialDraft,
  statusLabel,
} from "./settings";
import type { SettingsDraft } from "./settings";

interface Props {
  initialStatus?: SettingsStatus;
  onClose: () => void;
}

function messageOf(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

export default function SettingsDialog({ initialStatus, onClose }: Props) {
  const [status, setStatus] = useState<SettingsStatus | null>(
    initialStatus ?? null,
  );
  const [draft, setDraft] = useState<SettingsDraft>(() =>
    initialDraft(initialStatus ?? null),
  );
  const [loading, setLoading] = useState(initialStatus === undefined);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState("");
  const [saved, setSaved] = useState(false);
  const [confirmClear, setConfirmClear] = useState(false);

  useEffect(() => {
    if (initialStatus !== undefined) return;
    let alive = true;
    void (async () => {
      try {
        const next = await settingsApi.get();
        if (!alive) return;
        setStatus(next);
        setDraft(initialDraft(next));
      } catch (cause) {
        if (alive) setError(messageOf(cause));
      } finally {
        if (alive) setLoading(false);
      }
    })();
    return () => {
      alive = false;
    };
  }, [initialStatus]);

  const update = (patch: Partial<SettingsDraft>) => {
    setDraft((current) => ({ ...current, ...patch }));
    setSaved(false);
    setConfirmClear(false);
  };

  const save = async () => {
    setSaving(true);
    setError("");
    setSaved(false);
    try {
      const next = await settingsApi.save(buildSettingsInput(draft));
      setStatus(next);
      setDraft(initialDraft(next));
      setSaved(true);
    } catch (cause) {
      setError(messageOf(cause));
    } finally {
      setSaving(false);
    }
  };

  const clear = async () => {
    if (!confirmClear) {
      setConfirmClear(true);
      return;
    }
    setSaving(true);
    setError("");
    try {
      const next = await settingsApi.save(clearSettingsInput());
      setStatus(next);
      setDraft(initialDraft(next));
      setSaved(true);
      setConfirmClear(false);
    } catch (cause) {
      setError(messageOf(cause));
    } finally {
      setSaving(false);
    }
  };

  return (
    <div className="settings-overlay" role="dialog" aria-modal="true">
      <div className="settings-card">
        <header className="settings-head">
          <div>
            <h2>设置</h2>
            <p>密钥保存在系统钥匙串；不会写入仓库或日志。</p>
          </div>
          <button
            type="button"
            className="settings-close"
            onClick={onClose}
            title="关闭"
          >
            ×
          </button>
        </header>

        {loading ? (
          <p className="settings-note">正在读取配置…</p>
        ) : (
          <>
            <div className="settings-status">
              <span>百炼 API Key</span>
              <b className={status?.dashscope_configured ? "ok" : "miss"}>
                {statusLabel(status?.dashscope_configured ?? false)}
              </b>
            </div>

            <label className="settings-field">
              <span>DASHSCOPE_API_KEY</span>
              <input
                type="password"
                autoComplete="off"
                placeholder={
                  status?.dashscope_configured
                    ? "已配置；留空不修改"
                    : "sk-..."
                }
                value={draft.apiKey}
                onChange={(event) => update({ apiKey: event.target.value })}
              />
            </label>

            <label className="settings-field">
              <span>Workspace ID（可选）</span>
              <input
                type="text"
                autoComplete="off"
                placeholder="留空走默认空间"
                value={draft.workspaceId}
                onChange={(event) =>
                  update({ workspaceId: event.target.value })
                }
              />
            </label>

            <div className="settings-status">
              <span>OSS 回退凭证</span>
              <b className={status?.oss_configured ? "ok" : "miss"}>
                {statusLabel(status?.oss_configured ?? false)}
              </b>
            </div>

            <details className="settings-oss">
              <summary>展开 OSS（仅需要公网 URL 回退时填写）</summary>
              <label className="settings-field">
                <span>OSS_ACCESS_KEY_ID</span>
                <input
                  type="password"
                  autoComplete="off"
                  value={draft.ossAccessKeyId}
                  onChange={(event) =>
                    update({ ossAccessKeyId: event.target.value })
                  }
                />
              </label>
              <label className="settings-field">
                <span>OSS_ACCESS_KEY_SECRET</span>
                <input
                  type="password"
                  autoComplete="off"
                  value={draft.ossAccessKeySecret}
                  onChange={(event) =>
                    update({ ossAccessKeySecret: event.target.value })
                  }
                />
              </label>
            </details>

            {error !== "" && <div className="settings-error">{error}</div>}
            {saved && <div className="settings-saved">已保存，立即生效。</div>}

            <div className="settings-actions">
              <button
                type="button"
                className="settings-btn ghost"
                onClick={clear}
                disabled={saving}
              >
                {confirmClear ? "再次点击确认清除" : "清除全部密钥"}
              </button>
              <button
                type="button"
                className="settings-btn primary"
                onClick={save}
                disabled={saving}
              >
                {saving ? "保存中…" : "保存"}
              </button>
            </div>
          </>
        )}
      </div>
    </div>
  );
}
