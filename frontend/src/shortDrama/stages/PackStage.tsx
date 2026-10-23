/// 打包工序占位：P3 接成片/SRT/封面/前 3 秒多版本。
export default function PackStage() {
  return (
    <section className="sd-stage">
      <header className="sd-stage-head">
        <div>
          <h2>08 打包</h2>
          <p>成片、SRT、封面与前 3 秒多版本。</p>
        </div>
        <span className="sd-pill">未接入</span>
      </header>
      <div className="sd-panel">
        <p className="sd-empty">
          P3 接入合成后，这里会显示 final.mp4、final.srt 与投放包。
        </p>
      </div>
    </section>
  );
}
