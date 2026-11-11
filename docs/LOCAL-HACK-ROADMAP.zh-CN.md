# 本地 Hack 路线

这个 fork 面向个人本地使用，优先覆盖 `Codex CLI + Kiro CLI + cmux`。

## 当前开发分支进度

`codex/codex-runtime-profile` 已完成第一轮 Codex/Kiro 用量基础能力：

- Codex 从 `auth.json` 和 `config.toml` 识别官方订阅、API key 与公司 API Router。
- 只有官方订阅才请求 5 小时 / 每周 quota；Router 和 API key 只显示本地活动统计。
- Codex rollout 的 `last_token_usage` 按 `session_meta.model_provider` 分组，支持增量读取和复制记录去重。
- Kiro IDE `messages.jsonl` 增量读取、CLI `.json` 的 metering credits 读取，跨文件去重，并报告不可读记录。
- Kiro 账户周期累计、套餐上限和重置日来自只读 `state.vscdb` 共享缓存；CLI `/usage` 可刷新此缓存，缓存超过 12 小时会提示过期。
- 设置页显示当前 Codex provider、endpoint host 和 quota 能力；不展示凭据内容。

下一阶段是持久化用量 Ledger、睡眠/网络恢复和按 reset cycle 的额度提醒。

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

## Phase 7：Kiro CLI 审批提醒与面板审批

### 调研结论

- [Vibe Island 官网](https://vibeisland.app/) 和公开 changelog 声称 Kiro 支持
  permission prompts、zero-config agent setup、事件转换、工具名映射和 IDE 自动识别。
- [Vibe Island 的公开 GitHub 仓库](https://github.com/vibeislandapp/vibe-island)
  目前是社区 issue、讨论和文档仓库，不包含 macOS 应用的 Kiro 实现源码；公开
  内容没有给出 Kiro 的 hook payload 或 allow/deny 响应 schema。
- 公开 issue [#83](https://github.com/vibeislandapp/vibe-island/issues/83)
  反而记录了 Kiro IDE hook 不生效和卸载状态不一致，说明其 Kiro 支持也存在
  版本和安装路径差异。
- [Open Vibe Island](https://github.com/Octane0411/open-vibe-island) 提供了另一套
  开源实现，但其当前公开源码树没有 Kiro hook/approval 实现，不能直接移植协议。

因此目前不需要安装 Vibe Island。安装闭源竞品只能观察最终行为，不能可靠得到协议；
只有在本地 Kiro payload 不完整、无法确认审批响应格式时，才考虑一次隔离的黑盒测试，
并且不覆盖用户现有 hooks。

### 开发分阶段

1. **协议采样**：在 Kiro CLI 的临时 agent 配置中捕获 `agentSpawn`、`preToolUse`、
   审批相关事件和终端输出，脱敏后确认哪个事件表示“等待用户决定”，以及 Kiro
   是否要求 hook 返回 allow/deny JSON。没有确认 schema 前，不把所有 `preToolUse`
   当成审批。
2. **事件路由**：增加 Kiro 专用事件归一化和 `PermissionRequest` 适配器，仅在事件
   明确携带审批语义时进入 CodeIsland 审批队列；普通工具调用继续保持 running 状态。
3. **面板交互**：复用现有审批队列，显示工具名、命令/路径、Kiro 会话和队列位置；
   支持 Allow、Deny、Always Allow（如果 Kiro 协议提供该能力），并处理重复事件、
   断开连接和超时。
4. **提醒与跳转**：审批到达时播放审批声音并按 Smart Suppress / Auto Expand 设置
   展开；Kiro 自己仍负责最终审批时，面板显示“请在 Kiro 中审批”并提供跳转到
   Kiro terminal 或 cmux surface 的按钮。
5. **验证与回归**：为每种 Kiro payload 建 fixture，覆盖普通 `preToolUse` 不弹审批、
   真实审批自动提醒、Allow/Deny 响应、Kiro 进程退出、cmux 精确跳转和旧版 hook
   兼容性；在 Kiro CLI 版本升级时重新跑协议采样。

### 完成标准

- Kiro 普通工具调用不会误弹审批卡片。
- Kiro 真正等待用户决定时，CodeIsland 在设置允许的情况下有声音和可见提醒。
- 面板内的决定能可靠返回 Kiro；若协议不支持面板决定，则明确提示并跳回正确窗口。
- Kiro、Claude、Codex 的审批队列互不误消费，socket 断开不会让 CLI 永久阻塞。

Apple Watch、SSH Remote 暂不列入路线。
