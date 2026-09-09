# Fork 首版变更记录

本仓库由 [kbfx1234](https://github.com/kbfx1234) 维护，fork 自
[wxtsky/CodeIsland](https://github.com/wxtsky/CodeIsland)，基线为上游
`v1.0.33`（提交 `63013bf`）。项目继续采用 MIT 许可证，并保留原作者版权声明。

## 首个稳定版本

### Codex Desktop 与 CLI

- 支持 Codex Desktop 会话识别和 `codex://threads/<thread-id>` 精确跳转。
- 统一 hook、rollout transcript 和状态数据库发现得到的 Desktop 会话身份。
- 使用 transcript `session_meta.payload.session_id` 作为权威 thread ID，避免续接
  rollout 文件名生成重复卡片。
- 合并 Desktop 子 Agent，过滤 `guardian_review` 等内部线程，同时保持 Codex CLI
  与 Desktop 会话隔离。
- 改进 transcript 增量恢复、问题回答路由、权限状态和完成状态同步。

### Claude Code 与 cmux

- 在原生 bridge 和 shell fallback 中传递 `CMUX_SURFACE_ID` 与
  `CMUX_WORKSPACE_ID`。
- cmux identity 优先于桌面应用和普通终端推断，点击卡片可精确聚焦对应 surface。
- Claude hook 脚本升级为 v6，旧安装可自动修复并移除遗留 Vibe Island hook。

### Kiro CLI

- 增加 Kiro CLI v2 Agent profile 与 v3 standalone hook 配置、安装和健康检查。
- 支持 Kiro 会话发现、事件归一化、使用量读取和设置页展示。
- 避免修改用户的 cmux Agent 配置，并为 hook 配置保留旁路备份。

### Hook 与会话可靠性

- 设置页新增 bridge、socket、hook script、CLI 和插件健康检查及一键修复。
- 修复前备份已有配置；只管理 CodeIsland 自己注册的 hook。
- 增加交互请求超时、失效连接恢复、进程存活检查和会话持久化。
- 支持隐藏、恢复和清理已完成会话，不删除原始 transcript 或凭据。

### 界面与 macOS 行为

- 改进会话列表信息密度、状态反馈、过滤、清理与外接显示器适配。
- 恢复 `LSUIElement` 和 accessory activation policy，正常运行时不常驻 Dock；
  设置窗口打开期间仍可临时显示 Dock 图标。
- 修复窗口尺寸、刘海屏幕选择和面板定位相关回归。

### 构建与验证

- 增加 macOS GitHub Actions 测试工作流和本地 Phase 1 smoke preflight。
- 修复 SwiftPM GUI app 的 bundle、Sparkle rpath、嵌套签名和覆盖安装流程。
- 为 Codex 会话身份、cmux 路由、Kiro、Hook 健康和会话生命周期增加回归测试。
