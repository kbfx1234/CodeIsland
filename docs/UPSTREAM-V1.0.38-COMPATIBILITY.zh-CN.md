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

## 本地测试版修复（2026-10-16）

- 崩溃栈确认 Kiro 目录枚举的 package 判断进入 LaunchServices 同步调用，造成后台任务阻塞和主队列 watchdog。扫描普通 session 文件时去掉 package 判断，并隔离测试中的自动真实目录扫描。
- Kiro 账户 SQLite 读取恢复到后台执行，测试采用有期限的等待，不再靠扩大固定轮询次数掩盖阻塞。
- Hermes store 超时随上述阻塞一起消失，未修改 Hermes 的数据库行为。
- Cowork FSEvents 测试在原生 macOS 环境通过；执行沙箱无法接收系统事件时，须在原生环境验证。没有删除或跳过这项测试。
- 补齐 Codex hook canonicalization 的真实请求入口、Kiro v3 启动安装和修复入口，以及 Codex Desktop thread 深链接。
- 本地版本为 `1.2.0-beta.1`，更新源指向 fork，关闭自动更新检查。

最终候选版本原生完整回归通过 2,252 个测试，0 失败，5 个可选测试跳过；包含补齐入口的 58 个回归测试。测试日志：`/tmp/codeisland-beta-final-tests.log`。

## 合并安排

先安装本地候选 App，等待实际体验反馈，再处理 PR 与 fork `main` 的历史冲突和最终合并。
