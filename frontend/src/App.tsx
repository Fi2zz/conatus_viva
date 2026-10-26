import { useState } from "react";
import ShortDrama from "./ShortDrama";
import SettingsDialog from "./settings/SettingsDialog";
import "./App.css";
import "./settings/Settings.css";

/// 应用唯一入口：短剧工作台 + 全局设置（密钥）入口。
export default function App() {
  const [settingsOpen, setSettingsOpen] = useState(false);

  return (
    <>
      <ShortDrama />
      <button
        type="button"
        className="settings-open"
        onClick={() => setSettingsOpen(true)}
        title="设置密钥"
      >
        设置
      </button>
      {settingsOpen && (
        <SettingsDialog onClose={() => setSettingsOpen(false)} />
      )}
    </>
  );
}
