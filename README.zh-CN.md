<p align="center">
  <img src="Resources/AppIcon.png" alt="QuotaBar 应用图标" width="180">
</p>

<h1 align="center">QuotaBar</h1>

<p align="center">
  <a href="README.md"><kbd>English</kbd></a>
  <a href="README.zh-CN.md"><kbd>简体中文</kbd></a>
</p>

一个 macOS 菜单栏应用，用来查看 Codex 和 Claude 的剩余额度、重置时间、本地 token 用量与预估成本。

<p align="center">
  <img src="docs/images/hero.png" width="620" alt="Claude 和 Codex 额度卡片">
</p>

QuotaBar 将 Codex 和 Claude 放在同一个菜单栏图标中。项目基于 [CodexBar](https://github.com/steipete/CodexBar) 重写。

## 功能

- 显示会话与每周剩余额度、重置时间、使用节奏和可用 credits。
- 按日期和模型展示本地 Codex、Claude 的 token 用量与预估成本。
- 为 GPT-6 Astra 的 Standard、Fast 和长上下文用量计价，Standard 费率可以手动修改。
- 将同一账号的 OpenCode 和 Pi Agent OpenAI OAuth 用量计入 Codex。
- 菜单栏机器人一次显示一家供应商。QuotaBar 刷新当前选中的供应商；切换后会请求刷新新选中的供应商，仍受其冷却时间限制。
- 使用内置费率、公开的 [models.dev](https://models.dev) 目录和手动费率。
- 刷新失败时保留最后一次有效的额度数据。
- 跟随 macOS 的 **减弱动态效果** 设置。

<p align="center">
  <img src="docs/images/menu-bar-icons.png" width="440" alt="菜单栏机器人的几种状态：正常、快用完、刷新失败、无数据">
</p>

机器人图标用的是 Material Design Icons 的 `robot-excited`，也就是 Omarchy agents 组件放在顶栏里的那个字形。当前查看的那家，5 小时或每周额度任一剩余 10% 或更少时，机器人变红。刷新失败时机器人变淡，还没有数据时更淡。

## 安装

QuotaBar 要求 macOS 14 或更高版本。目前 Homebrew cask 和 Release ZIP 仅支持 Apple Silicon。安装预编译版本不需要 Xcode 或 Swift。

额度统计使用同一台 Mac 上由 Codex CLI、Claude Code 或两者创建的 OAuth 凭据，不支持仅使用 API key 的会话。

### Homebrew

```bash
brew install --cask softmaxe/tap/quota-bar
```

更新或卸载：

```bash
brew upgrade --cask quota-bar
brew uninstall --cask quota-bar
```

同时删除应用数据：

```bash
brew uninstall --zap --cask quota-bar
```

### 手动下载

从 [GitHub Releases](https://github.com/softmaxe/quota-bar/releases) 下载 `arm64` ZIP，解压后将 `QuotaBar.app` 移到 `/Applications`。

每个 ZIP 都有对应的 `.sha256` 文件。解压前可以校验：

```bash
shasum -a 256 -c QuotaBar-*-macos-arm64.zip.sha256
```

发布包使用 ad hoc 签名，没有 Apple Developer ID 公证。若 macOS 首次启动时阻止打开，请先尝试打开一次，再前往 **系统设置 → 隐私与安全性**，选择 **仍要打开**。也可以在确认应用位于 `/Applications` 后，只移除这个应用的 quarantine attribute：

```bash
xattr -dr com.apple.quarantine /Applications/QuotaBar.app
```

## 首次使用

QuotaBar 复用官方 CLI 创建的 OAuth 凭据，没有单独的登录流程。请通过需要统计的 CLI 登录：

```bash
codex login
claude
```

然后打开 QuotaBar：

- 点击菜单栏图标，查看额度与本地成本。
- 在菜单顶部用两个等宽按钮切换 Codex 和 Claude。按钮只显示供应商名称和色点，额度百分比放在下方当前供应商的详情中。
- 打开 **Settings**，修改刷新间隔或模型费率。

选中项使用高亮底色和加粗名称。悬停另一项时，只显示轻微底色并提亮色点，名称不加粗。切换时文字位置保持固定。

读取 Claude 凭据时，macOS 可能弹出 Keychain 授权提示。如果手动 `Refresh` 收到 HTTP 401，QuotaBar 会让 Claude Code 尝试一次短时凭据刷新。自动刷新不会启动 Claude Code。

## 额度统计方式

每个可用的额度窗口都会显示剩余百分比和重置时间。点击 `Resets in …` 可以在倒计时与具体时刻之间切换。

QuotaBar 会比较用量与已过时间。记录满三个可比较的每周窗口后，每周节奏会改用你的历史数据。额度采样保留 56 天。

后台刷新可设为手动，或每 1、2、5、15、30 分钟一次，默认 5 分钟。两家供应商各有一分钟刷新冷却，避免重复请求和 HTTP 429。

会话或每周窗口重置后，下次打开卡片时会播放一段短动画。最后读数和尚未播放的动画会在重启后保留。

<p align="center">
  <img src="docs/images/quota-reset.gif" width="560" alt="额度条从上次读数变化到重置后额度">
</p>

## 成本统计方式

QuotaBar 从本地会话数据计算 token 和成本，不使用计费 API。

将指针移到图表中的某一天，可以查看模型明细。点击高亮日期，可以在 token 和成本之间切换图表。

<p align="center">
  <img src="docs/images/chart-hover.gif" width="560" alt="基线下方的标记跟随指针所在的日期，明细随之变化">
</p>

| 来源 | 本地数据 |
| --- | --- |
| Codex | `$CODEX_HOME/sessions` 和 `$CODEX_HOME/archived_sessions`；未设置时使用 `~/.codex` 下的同名目录 |
| Claude | `$CLAUDE_CONFIG_DIR/projects`，或 `~/.claude/projects` 和 `~/.config/claude/projects` |
| OpenCode | `$OPENCODE_DATA_HOME/opencode.db`、`$XDG_DATA_HOME/opencode/opencode.db`，或 `~/.local/share/opencode/opencode.db` |
| Pi Agent | `$PI_CODING_AGENT_SESSION_DIR`、`$PI_CODING_AGENT_DIR/sessions`，或 `~/.pi/agent/sessions` |

只有 OpenCode 的 `openai` 供应商使用 OAuth，且 account ID 与当前 Codex 账号一致时，这部分数据才会计入 Codex。其他供应商、API key 会话和账号不匹配的数据都会被忽略。OpenCode 用量不会改变额度条。

Pi Agent 遵循同样的规则。只有匹配 OAuth 账号的 `openai-codex` assistant 用量会被计入。Pi Agent 用量不会改变额度条，成本使用 QuotaBar 的模型价格估算，不代表 OpenAI 账单。

历史记录很多时，第一次扫描会花一些时间。QuotaBar 用一个精简的 SQLite 库保存用量历史，记录日期、模型、来源工具、token 数量和预估成本，以及去重用的标识和扫描位置。Codex 和 Claude 从上次读到的字节继续扫描，OpenCode 和 Pi Agent 按稳定 ID 去重。删除源会话不会删除已记录的用量，重启 QuotaBar 后也一样。Codex 标准 rollout UUID 能避免归档移动或复制后被重复计算。图表只显示最近 30 天，更早的记录仍然保存在库里。价格目录缓存 24 小时。手动修改费率只影响之后的用量，过去的总计保留扫描时的价格。

第一次使用时，QuotaBar 会把 `~/Library/Caches/QuotaBar/cost-usage/` 下已有的成本数据库复制到下方列出的持久位置，已提交的 SQLite WAL 数据也会一起复制，旧缓存保持不动。只有已经扫描过的用量能在源会话删除后保留。QuotaBar 扫描之前就被删除的会话无法恢复。扫描器升级时保留已记录的历史，不会从源日志重建。

对于 Codex，QuotaBar 还会缓存当前模型、服务层级和最后一次 token 总计，所以长会话追加内容时不会重新处理前面的记录。目录条目缺少缓存价格或长上下文价格时，Astra 使用完整的内置费率。内置费率来自 [Astra 官方模型价格](https://developers.openai.com/api/docs/models/gpt-6-astra)。

<p align="center">
  <img src="docs/images/settings-pricing.png" width="620" alt="可编辑模型费率的价格设置">
</p>

成本是估算值。供应商计费规则、缓存计算方式和价格变化，都可能让结果与账单不同。

## 隐私与网络

QuotaBar 会读取 CLI 凭据并解析本地会话记录，但不会写入 CLI 的凭据存储。统计会使用时间、模型、token 数量、稳定记录 ID，以及匹配 OAuth 会话所需的账号 ID。prompt、回复和 reasoning 字段会被丢弃，不会写入 QuotaBar 缓存或上传。

应用自己的数据保存在：

```text
~/Library/Application Support/QuotaBar/usage-history.json
~/Library/Application Support/QuotaBar/pricing-overrides.json
~/Library/Application Support/QuotaBar/cost-usage/cost-usage.sqlite
~/Library/Caches/QuotaBar/model-pricing/
~/Library/Preferences/com.quotabar.app.plist
```

Codex 额度请求会使用 `$CODEX_HOME/config.toml` 中的 `chatgpt_base_url`；未设置时使用 ChatGPT 默认接口。QuotaBar 还会请求 `auth.openai.com` 刷新 Codex token、请求 `api.anthropic.com` 获取 Claude 额度，并从 `models.dev` 获取模型价格。本地会话记录不会发送到这些服务。

## 构建与开发

构建需要 Xcode 或 Command Line Tools 提供的 Swift 6 工具链。项目使用 Swift Package Manager，没有 Xcode 工程。

```bash
git clone https://github.com/softmaxe/quota-bar.git
cd quota-bar
make app
open build/QuotaBar.app
```

常用命令：

```bash
make build          # Build the debug binary
make run            # Build and run in the foreground
make test           # Run assertions and animation verifiers
make probe          # Check both provider integrations
make probe-cost     # Rescan local logs; may refresh model prices
make benchmark-startup # Measure status-item construction offline in a debug build
make benchmark-cost # Measure Codex scans with offline pricing; reads local logs
make logs           # Stream logs for com.quotabar.app
make readme-assets  # Rebuild README images; requires ffmpeg
make clean
```

`make probe` 会输出账号和用量元数据，分享前请先检查内容。

如需生成测试包，在仓库的 **Actions** 页面手动运行 **Build and Release**。发布正式版本时，推送符合 `vMAJOR.MINOR.PATCH` 格式的 tag。workflow 会完成测试、打包 `arm64` ZIP，然后创建 GitHub Release。

## 排查

| 问题 | 检查方法 |
| --- | --- |
| 供应商显示未登录 | 运行对应 CLI 的登录流程，再选择 `Refresh`。用 `make probe` 查看原始错误。 |
| 数据过期或刷新返回 HTTP 429 | 等待供应商冷却结束，并选择更长的刷新间隔。 |
| 缺少成本统计 | 确认 CLI 正在向上面的路径写入会话日志，并确认模型有目录价格或手动费率。 |
| 缺少 OpenCode 用量 | 确认 OpenCode 使用 `openai` OAuth，且账号与 Codex 相同。在 **Settings → Pricing** 查看数据库或认证错误。 |
| 缺少 Pi Agent 用量 | 确认 Pi Agent 通过 `/login openai-codex` 登录了与 Codex 相同的账号。在 **Settings → Pricing** 查看会话或认证错误。 |

## 已知限制

- 预编译 Release 和 Homebrew cask 仅支持 Apple Silicon。Release ZIP 使用 ad hoc 签名，且未经过公证。
- Claude 凭据恢复只会在手动 `Refresh` 后运行，交互式登录仍需自行打开 Claude Code。
- 成本来自本地日志，不是账单。
- OpenCode 不记录每条历史请求的认证方式。QuotaBar 无法还原它未运行期间发生的 OAuth → API key → OAuth 切换。

## 许可证

QuotaBar 使用 [AGPL-3.0](LICENSE) 许可证。从 CodexBar 改编的代码仍按其 MIT 条款提供。详见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

## 致谢

QuotaBar 使用了 CodexBar 的思路与实现细节，Copyright © 2026 Peter Steinberger。
