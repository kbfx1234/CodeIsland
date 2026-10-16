# upstream v1.0.38 兼容移植说明

本分支以 `wxtsky/CodeIsland` `v1.0.38`（`31cf9b5`）为基线，按功能组移植 fork 的 Codex/Kiro 适配。

## 已移植并验证

- Codex provider profile、官方 OAuth/API key/API Router 识别、本地 token 扫描与官方额度模型。
- Kiro CLI/IDE session credits、账户周期额度只读缓存、Kiro v2 Agent profile 和 v3 standalone hooks。
- Codex Desktop transcript/session identity、CLI/Desktop namespace 隔离、raw hook twin reconciliation、子 Agent merge/hide/separate。
- Codex Desktop hook canonicalization、guardian/internal transcript 过滤、续接 rollout 去重。
- cmux surface/workspace 解析与 Codex shared daemon 的终端定位。
- hook health diagnostics、repair backup、Kiro v3 配置迁移，同时保留 upstream 的 extra config roots 和 symlink 写入保护。
- Codex/Kiro 用量显示接入 upstream 的 Claude quota、task progress、Compact density、Markdown reply 和 push UI。
- 中文、英文及现有多语言 usage 文案，新增回归测试。

## 验证结果

- Codex/core routing：78 个测试通过。
- hook/config/repair：89 个测试通过。
- Codex/Kiro integration：49 个测试通过。
- arm64 Release 构建：`CodeIsland` 和 `codeisland-bridge` 均通过。
- App 包：`.build/CodeIsland-upstream-v1.0.38-codex-kiro.zip`。

## 合并前剩余事项

完整 upstream 测试仍有两个与本移植无关的环境/时序失败：

- `CoworkSessionWatcherTests.testFileSystemEventsDriveUpdatesEndToEnd`：FSEvents 通知超时。
- `HermesTurnSettleTests.testLocalSessionGetsItsTitleFromTheStore`：Hermes store 读取超时。

另外，GitHub PR 合入 fork `main` 时会出现历史基线冲突，因为 fork `main` 已经包含基于 `v1.0.33` 的本地提交；需要在审查时选择以本分支的 `v1.0.38 + 手工移植` 结果作为新的主线，再处理历史合并提交。
