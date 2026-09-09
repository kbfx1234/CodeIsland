# 本地 Hack 路线

这个 fork 面向个人本地使用，优先覆盖 `Codex CLI + Kiro CLI + cmux`。

## Phase 1A：ChatGPT/Codex Desktop 跳转

- 已支持 `Codex Desktop` 识别和 `codex://threads/<providerSessionId>` deep link。
- 已过滤内部 `guardian_review` 线程，并将 Desktop subagent 默认合并到主线程卡片。
- 已增加 `com.codeisland/session-jump` 日志、非法 thread 拒绝和普通窗口激活回退。
- 验收：点击两个不同 Desktop 卡片，确认标题/左侧高亮会话确实切换。系统返回 URL 已接收只能作为“已请求跳转”，不能单独证明线程已落地。

## Phase 1B：cmux + Codex CLI/Kiro CLI

- 已支持 `CMUX_SURFACE_ID` / `CMUX_WORKSPACE_ID`，并将明确的 cmux identity 放在原生 App 路由之前。
- 已使用 `cmux focus-panel --panel <surface> --workspace <workspace>`，记录缺少 binary、参数缺失和命令失败。
- 已覆盖 Hook 状态、SessionStart/Stop、完成通知和卡片跳转。
- 验收：cmux 重启或关闭 surface 后，点击卡片应明确失败或恢复到正确 pane，不能误跳到 ChatGPT Desktop。

## Phase 2：Hook Health Check

- 设置页展示 bridge、hook script、socket、已检测 CLI 和 OpenCode plugin 的结构化状态。
- 支持重新检查和一键修复；修复前对已存在的 CLI 配置创建 `.codeisland.bak.<timestamp>` 旁路备份。
- 不删除或覆盖用户未由 CodeIsland 管理的 hooks。

## Phase 3：会话清理与生命周期

- 增加隐藏、恢复、清除已完成会话和面板过滤。
- worktree 使用可读名称；运行中或等待审批的会话不可被批量清除。
- 只清理 CodeIsland 自己的 `sessions.json` 状态，不删除 Codex/Kiro transcript、credentials 或原始日志。

## Phase 4：审批与异常状态

- 为审批、问题回答和外部跳转增加执行中、成功、失败和超时状态。
- 对失效 socket、命令非零退出、重复 waiting 和过期请求给出可见反馈，避免永久等待或静默失败。

## Phase 5：Kiro Usage

- 优先读取 Kiro CLI `/usage` 或本地机器可读缓存；不读取或上传 token/cookie。
- UI 明确区分本地 session 消耗估算、账户计划额度、reset 时间和 organization 账户提示。
- 在无法可靠得到总额度时显示“额度未知”，不计算误导性的百分比。

## Phase 6：Kiro IDE

复用 Kiro bridge，新增 IDE 项目识别和窗口激活。第一版只保证激活正确的 Kiro 窗口/项目。

Apple Watch、SSH Remote 暂不列入路线。
