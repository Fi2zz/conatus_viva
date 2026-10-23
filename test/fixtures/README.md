本目录存放离线测试夹具：`ep07.storyboard.json` 是渲染计划单用例的输入样例（12 镜，内容即
`docs/superpowers/plans/2026-10-23-storyboard-render-plan.md` §1.1），**只读、不要改写**——
改它会同时让 `storyboard_test` / `render_plan_test` / `planner_cli_test` 的预期数字失效。

在仓库根执行单行验收（默认输出到 `pipeline_out/ep07/07_plan.json`，不产生任何真实生成请求）：

```bash
dart run bin/short_drama.dart plan --storyboard test/fixtures/ep07.storyboard.json --budget 20
```
