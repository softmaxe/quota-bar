<p align="center">
  <img src="Resources/AppIcon.png" alt="QuotaBar 应用图标" width="96">
</p>

<h1 align="center">QuotaBar</h1>

<p align="center">
  <a href="README.md"><kbd>English</kbd></a>
  <a href="README.zh-CN.md"><kbd>简体中文</kbd></a>
</p>

一个 macOS 菜单栏应用，用来查看 Codex 和 Claude 的剩余额度、重置时间、本地 token 用量与预估成本。

[安装](#安装) · [首次使用](#首次使用) · [额度](#额度统计方式) · [成本](#成本统计方式) · [报告](#导出用量报告) · [费率](#编辑模型费率) · [开发](#构建与开发) · [排查](#排查)

<p align="center">
  <img src="docs/images/hero.png" width="620" alt="使用示例数据渲染的 Claude 和 Codex 额度卡片">
</p>

截图和动画使用示例数据。应用界面为英文，导出的报告支持中英文切换。也可以查看卡片的[深色](docs/images/interactions/main-dark.png)与[浅色](docs/images/interactions/main-light.png)外观。

## 功能

- 查看会话与每周额度、重置时间、使用节奏和可用 Credits 余额，刷新失败时保留上次有效读数。
- 按日期和模型查看本地 token 用量与预估成本，将同一账号的 OpenCode 和 Pi Agent OAuth 用量计入 Codex。
- 估算 Standard、Fast 和长上下文成本，支持 GPT-6 Astra，可在设置中编辑 Standard 费率。
- 将最近 7 天或 30 天的已保存用量导出为离线 HTML 报告，支持中英文切换。

## 安装

要求 **macOS 14+**。预编译版本和 Homebrew cask 支持 **Apple Silicon**，无需安装 Xcode 或 Swift。

额度统计使用同一台 Mac 上由 Codex CLI、Claude Code 或两者创建的 OAuth 凭据，不支持仅使用 API key 的会话。

### Homebrew

```bash
brew install --cask softmaxe/tap/quota-bar
```

<details>
<summary>更新或卸载</summary>

```bash
brew upgrade --cask quota-bar
brew uninstall --cask quota-bar
```

同时删除应用数据：

```bash
brew uninstall --zap --cask quota-bar
```

</details>

<details>
<summary>手动下载与首次启动安全提示</summary>

从 [GitHub Releases](https://github.com/softmaxe/quota-bar/releases) 下载 `arm64` ZIP，解压后将 `QuotaBar.app` 移到 `/Applications`。

每个 ZIP 都有对应的 `.sha256` 文件。解压前请先校验：

```bash
shasum -a 256 -c QuotaBar-*-macos-arm64.zip.sha256
```

发布包使用 ad hoc 签名，未通过 Apple Developer ID 公证。若 macOS 首次启动时阻止打开，请先尝试打开一次，再前往 **系统设置 → 隐私与安全性**，选择 **仍要打开**。如果仍无法打开，确认应用位于 `/Applications` 后，可以只移除这个应用的隔离属性：

```bash
xattr -dr com.apple.quarantine /Applications/QuotaBar.app
```

</details>

## 首次使用

QuotaBar 复用官方 CLI 创建的 OAuth 凭据，没有单独的登录流程。请通过需要统计的 CLI 登录：

```bash
codex login
claude
```

打开 QuotaBar，点击菜单栏图标，选择 **Codex** 或 **Claude**。在 [Settings](docs/images/settings-general.png) 中修改刷新间隔或[编辑模型费率](#编辑模型费率)。

未登录时，点击 **Copy command**，在终端中执行复制的命令，登录后返回并点击 **Check sign-in**。复制命令不会自动执行它。

读取 Claude 凭据时，macOS 可能弹出钥匙串授权提示。如果手动 **Refresh** 收到 HTTP 401，QuotaBar 会让 Claude Code 尝试一次短时凭据刷新。自动刷新不会启动 Claude Code。

## 额度统计方式

### 额度窗口与使用节奏

每个有限额的窗口显示剩余百分比和重置时间。在重置时间控件中选择 **Countdown** 或 **Clock time**，可同时切换两个有限额窗口的显示方式。无限额会话显示 **Session ∞** 和 **No limit**。展开 **Usage pace details**，可查看额度储备、缺口和使用余量。

QuotaBar 会比较用量与已过时间。积累至少三个可比较的周窗口后，每周节奏也会结合历史记录。额度采样保留 56 天。

检测到会话或每周额度重置后，下次打开卡片时会播放简短的额度条动画，标题显示新读数。应用遵循 macOS 的减弱动态效果设置。

<details>
<summary>额度重置动画</summary>

<p align="center">
  <img src="docs/images/quota-reset.gif" width="560" alt="简短的额度重置动效，标题始终显示新读数">
</p>

</details>

### 刷新与错误恢复

在设置中选择手动刷新，或每 1、2、5、15、30 分钟刷新一次，默认 5 分钟。

- 定时刷新、打开卡片和点击 **Refresh** 都只更新当前供应商。切换标签页时，会请求更新新选中的供应商。
- 每家供应商有独立的一分钟刷新冷却，服务端限流可能延长等待时间。
- 手动触发 Claude 凭据恢复时可以跳过本地冷却，但仍受服务端限制。

刷新失败时，卡片保留最后一次有效的额度，在顶部显示数据距今时间和恢复指引。冷却期间，重试控件会显示剩余等待时间。本地扫描单独显示进度，并提供 **Retry local scan** 操作。

<details>
<summary>登录与刷新失败示例</summary>

<table align="center">
  <tr><th>登录指引</th><th>刷新失败时保留额度</th></tr>
  <tr>
    <td valign="top"><img src="docs/images/interactions/sign-in.png" width="280" alt="Codex 登录卡片，提供可复制的 CLI 命令和 Check sign-in 按钮"></td>
    <td valign="top"><img src="docs/images/interactions/refresh-failed.png" width="280" alt="已保存额度上方的刷新警告，显示数据距今时间和重试倒计时"></td>
  </tr>
</table>

</details>

### 菜单栏与快捷键

菜单栏机器人显示当前供应商的状态。会话或每周额度任一剩余 10% 或更少时，机器人变红。刷新失败时图标变淡，还没有数据时更淡。

<p align="center">
  <img src="docs/images/menu-bar-icons.png" width="440" alt="菜单栏机器人的几种状态：正常、快用完、刷新失败、无数据">
</p>

图标来自 Material Design Icons 的 `robot-excited`。卡片内容过长时可滚动，底部操作保持可见，重新打开时详情收起。以下快捷键在卡片打开时生效：

| 快捷键 | 操作 |
| --- | --- |
| ⌘1 / ⌘2 | 查看 Codex / Claude |
| ⌘R | 可用时刷新或检查登录状态 |
| ⌘, | 打开设置 |
| ⌘Q | 退出，有未保存的费率修改时先询问 |
| Esc | 关闭卡片 |

<details>
<summary>鼠标、标签切换与动效细节</summary>

供应商标签等宽，文字位置固定。选中项使用高亮底色和加粗名称，悬停时显示较浅的高亮。左键在按下时开关卡片，右键在松开时开关。按钮在按下时响应，展开的多行内容同时出现。减弱动态效果会关闭自定义过渡，保留按下和选中状态。

</details>

## 成本统计方式

QuotaBar 从本地会话数据计算 token 和成本，不使用计费 API。

### 查看图表

在图表上方选择 **Tokens** 或 **Cost**。图表覆盖十个日历日，总计覆盖最近 30 天。悬停可预览某天，点击可固定日期，日期获得焦点后也可用左右方向键切换。展开 **Model breakdown** 可查看当天的模型明细，并固定日期。重新打开卡片可恢复悬停预览，切换单位会保留选中日期。

缺失信息与零用量会分别显示：

| 显示 | 含义 |
| --- | --- |
| **0** 或 **$0.00** | 已扫描的数值在当前显示精度下为零。缺失费率会另行标注。 |
| **—**、**Not scanned yet** | 该日期晚于最后一次完成扫描的日期，且还没有记录到用量。 |
| **—**、**Unpriced** | 已记录用量，但无法根据模型费率估算成本。 |
| **Partial estimate** | 金额只包含有费率的用量，没有费率的部分未计入。 |

在 **Settings → Pricing** 中补充费率后，该模型的所有已记录用量都会重新计算成本。

<details>
<summary>图表日期预览</summary>

<p align="center">
  <img src="docs/images/chart-hover.gif" width="560" alt="图表按日期预览 token 总量，Model breakdown 默认折叠">
</p>

</details>

### 数据来源

| 来源 | 本地数据 |
| --- | --- |
| Codex | `$CODEX_HOME/sessions` 和 `$CODEX_HOME/archived_sessions`；未设置时使用 `~/.codex` 下的同名目录 |
| Claude | `$CLAUDE_CONFIG_DIR/projects`，或 `~/.claude/projects` 和 `~/.config/claude/projects` |
| OpenCode | `$OPENCODE_DATA_HOME/opencode.db`、`$XDG_DATA_HOME/opencode/opencode.db`，或 `~/.local/share/opencode/opencode.db` |
| Pi Agent | `$PI_CODING_AGENT_SESSION_DIR`、`$PI_CODING_AGENT_DIR/sessions`，或 `~/.pi/agent/sessions` |

OpenCode 的 `openai` 用量和 Pi Agent 的 `openai-codex` 助手用量，仅在通过 OAuth 使用当前 Codex 账号时计入 Codex 总计。其他供应商、API key 会话和账号不匹配的数据不计入。这些本地用量不会改变额度条。

### 历史记录

首次扫描大量历史记录可能需要一些时间。QuotaBar 用 SQLite 保存日期、模型、来源、token 数量和预估成本，以及去重标识和扫描位置。删除源会话或重启应用不会丢失已保存用量，超出图表和总计时间范围的记录也会保留。扫描前就被删除的会话无法恢复。

<details>
<summary>增量扫描与数据库迁移</summary>

Codex 和 Claude 从上次读到的字节继续扫描，OpenCode 和 Pi Agent 按稳定 ID 去重。Codex 标准 rollout UUID 能避免归档移动或复制后被重复计算。QuotaBar 还会缓存 Codex 的当前模型、服务层级和最后一次 token 总计，所以长会话追加内容时不会重新处理前面的记录。

第一次使用时，QuotaBar 会把 `~/Library/Caches/QuotaBar/cost-usage/` 下已有的成本数据库复制到[持久存储位置](#隐私与网络)，已提交的 SQLite WAL 数据也会一起复制，旧缓存保持不动。扫描器升级时保留已记录的历史，不会从源日志重建。

</details>

### 计价规则

- Standard 费率依次使用手动覆盖和内置[价格表](Sources/QuotaBarCore/Resources/Pricing/price-book.json)。
- 价格表按生效日期分段记录每个模型的费率。每天的用量按当天生效的费率计价，调价和促销结束后，过去的日期仍使用当时的费率。
- Codex Fast 用量使用价格表中该时段的 Fast 倍率，不受手动覆盖影响；没有 Fast 倍率的模型在 Fast 模式下不计价。

成本在显示或导出时根据已记录的 token 计算。手动费率作用于该模型的所有已记录日期，包括之前未计价的用量。更新费率的方法见[维护价格表](docs/pricing.md)。

成本是估算值。供应商计费规则、缓存计算方式和价格变化，都可能让结果与账单不同。

## 导出用量报告

1. 打开 **Settings → Export**，也可以在设置窗口中按 ⌘3。
2. 选择 **Last 7 days** 或 **Last 30 days**。
3. 如需导出后立即查看，保留 **Open after export** 勾选。
4. 点击 **Export Report…** 并选择保存位置。如果所选时段没有已保存的用量，QuotaBar 会先提示，不会打开保存对话框。

<p align="center">
  <img src="docs/images/report-export.png" width="760" alt="离线用量报告的英文视图，含中英文切换控件，使用示例数据">
</p>

报告是一个可离线打开、切换中英文的 HTML 文件。它包含 SQLite 中所有符合条件的 Codex、Claude、OpenCode 和 Pi Agent 用量，展示每日用量、按模型汇总的成本、token 与缓存构成，以及可展开的数据表。

导出只读取已保存的数据，不刷新额度、重扫日志或请求网络。它用与菜单相同的费率为已保存的 token 计价；未计价 token 不计入成本，费率缺失会明确标注。报告显示缓存 token 数量，不推算单独的缓存成本。

文件包含时段、生成时间、时区、来源、模型、token 数量、未计价 token 数量和估算成本，不含提示词、回复、推理文本、凭据和账号 ID。数据格式与开发验证见[用量报告导出](docs/usage-report-export.md)。

## 编辑模型费率

打开 **Settings → Pricing**。费率单位是每百万 token 的美元价格。展开模型行，可以编辑一小时缓存写入费率、长上下文阈值，以及超过阈值后的费率。

列表显示受支持的 API 模型和本地发现的未计价模型。点击列标题排序；恢复默认顺序后，API 模型回到固定顺序，**Others** 按用量排序。

<p align="center">
  <img src="docs/images/settings-pricing.png" width="620" alt="价格设置，包含可编辑费率、展开的长上下文字段和各模型的操作菜单">
</p>

- 费率须为非负有限数值，可选的长上下文阈值须为正整数 token 数量。无效字段会禁用 **Save**。
- **Save** 显示进度和结果。应用运行期间，保存失败、切换标签页或关闭设置窗口都会保留草稿。**Discard** 恢复上次保存的费率。
- 移除覆盖费率时，在模型的 **…** 菜单选择 **Restore default rate** 或 **Clear custom rate**，然后保存。
- 有有效草稿时退出，可选择 **Save**、**Discard** 或 **Cancel**。无效草稿须修正后才能保存。

<details>
<summary>无效费率示例</summary>

<p align="center">
  <img src="docs/images/interactions/pricing-invalid.png" width="620" alt="费率输入非数字时显示字段错误和错误汇总，Save 按钮不可用">
</p>

</details>

保存后的费率作用于该模型的所有已记录用量，包括之前未计价的用量。恢复默认后，每一天都回到价格表中对应日期的费率。

## 隐私与网络

QuotaBar 会读取 CLI 凭据并解析本地会话记录，但不会直接写入 CLI 的凭据存储。手动恢复 Claude 凭据时，QuotaBar 可以启动 Claude Code，由后者更新自己的凭据。统计会使用时间、模型、token 数量、稳定记录 ID，以及匹配 OAuth 会话所需的账号 ID。提示词、回复和推理文本不会写入 QuotaBar 用量历史或上传。

<details>
<summary>本地存储路径</summary>

```text
~/Library/Application Support/QuotaBar/usage-history.json
~/Library/Application Support/QuotaBar/pricing-overrides.json
~/Library/Application Support/QuotaBar/cost-usage/cost-usage.sqlite
~/Library/Preferences/com.quotabar.app.plist
```

</details>

Codex 额度请求会使用 `$CODEX_HOME/config.toml` 中的 `chatgpt_base_url`；未设置时使用 ChatGPT 默认接口。QuotaBar 还会请求 `auth.openai.com` 刷新 Codex token、请求 `api.anthropic.com` 获取 Claude 额度。模型价格随应用发布，不会联网获取。本地会话记录不会发送到这些服务。

## 构建与开发

Building requires full Xcode with a Swift 6 toolchain. The project uses Swift Package Manager and has no Xcode project. Build commands use `Scripts/swift.sh`, which defaults to `/Applications/Xcode.app/Contents/Developer` without changing the global `xcode-select` setting.

```bash
git clone https://github.com/softmaxe/quota-bar.git
cd quota-bar
make app
open build/QuotaBar.app
```

To use another full Xcode installation, set `DEVELOPER_DIR` to its `Contents/Developer` directory:

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
make app
```

<details>
<summary>开发命令</summary>

| 命令 | 用途 |
| --- | --- |
| `make build` | 构建调试版本。 |
| `make run` | 构建并在前台运行。 |
| `make test` | 运行核心断言和界面、行为规则验证。 |
| `make probe` | 检查两家供应商的集成。 |
| `make probe-cost` | 重新扫描本地日志并输出成本总计。 |
| `make benchmark-startup` | 使用调试版本，离线测量菜单栏项目的创建耗时。 |
| `make benchmark-cost` | 使用离线价格测试 Codex 扫描性能，会读取本地日志。 |
| `make benchmark-cost PROVIDER=claude` | 使用相同的离线价格测试 Claude 扫描性能。 |
| `make logs` | 持续显示 `com.quotabar.app` 的日志。 |
| `make readme-assets` | 重新生成截图、状态示例和 GIF。 |
| `make clean` | 删除构建产物。 |

`make probe` 会输出账号和用量元数据，分享前请先检查内容。

</details>

<details>
<summary>界面预览与截图</summary>

如需用示例额度和成本数据预览交互，运行：

```bash
make build
.build/debug/QuotaBar --preview-interface loaded
```

将 `loaded` 换成 `signed-out` 或 `stale`，可以查看对应状态。预览使用隔离的偏好设置和临时历史记录，不读取凭据、不请求供应商接口，也不扫描真实日志。通过预览中的 **Quit** 清理临时数据。预览可以与已安装的应用同时运行，因此菜单栏会多出一个图标。

`make readme-assets` 使用当前视图和示例数据，重新生成两版 README 共用的图片，包括登录、刷新失败和无效费率状态。修改界面后应同步生成图片。

生成素材需要 ffmpeg。HTML 报告截图还需要 Node.js、Playwright 和 Chromium 浏览器，详见[报告开发验证](docs/usage-report-export.md#verification)。[实施记录](docs/design-implementation.md)列出了渲染命令和验证范围。

</details>

<details>
<summary>打包与发布</summary>

如需生成测试包，在仓库的 **Actions** 页面手动运行 **Build and Release**，并选择要构建的分支。手动运行会将开发版 ZIP 和 SHA-256 文件上传为工作流产物，不会发布 Release。

发布正式版本时，推送符合 `vMAJOR.MINOR.PATCH` 格式的 Git 标签，标签决定应用版本号。工作流会运行测试、打包 `arm64` ZIP、校验签名、版本、架构和校验和，发布 GitHub Release，然后更新 `softmaxe/homebrew-tap`。标签发布要求仓库已配置 `TAP_GITHUB_TOKEN` secret。确认 **Release** 和 **Update Homebrew tap** 都完成后，发布流程才算结束。

</details>

## 排查

| 问题 | 检查方法 |
| --- | --- |
| 供应商显示未登录 | 复制卡片中的命令，完成 CLI 登录后点击 **Check sign-in**。使用 `make probe` 查看原始错误。 |
| 数据过期或刷新返回 HTTP 429 | 查看已保存额度上方的警告，等待倒计时结束后重试。服务端限制可能超过一分钟。 |
| 本地扫描失败 | 查看本地用量区域的错误，点击 **Retry local scan**。确认 CLI 正在向上面的路径写入会话日志。 |
| 成本显示 Unpriced 或 Partial estimate | 在 **Settings → Pricing** 中补充模型费率，该模型的已记录用量也会一并计价。 |
| 日期显示 Not scanned yet | 等待本地扫描完成。这表示该日期尚未被扫描覆盖，不代表零用量。 |
| 费率修改无法保存 | 修正标记的字段。保存失败时草稿仍会保留，可以重试或放弃修改。 |
| 缺少 OpenCode 用量 | 确认 OpenCode 使用 `openai` OAuth，且账号与 Codex 相同。在 **Settings → Pricing** 查看数据库或认证错误。 |
| 缺少 Pi Agent 用量 | 确认 Pi Agent 通过 `/login openai-codex` 登录了与 Codex 相同的账号。在 **Settings → Pricing** 查看会话或认证错误。 |

## 已知限制

- 预编译 Release 和 Homebrew cask 仅支持 Apple Silicon。Release ZIP 使用 ad hoc 签名，且未经过公证。
- Claude 凭据恢复只会在手动 **Refresh** 后运行。如果仍需交互式登录，需要自行打开 Claude Code。
- 成本来自本地日志，不是账单。
- OpenCode 不记录每条历史请求的认证方式。QuotaBar 无法还原它未运行期间发生的 OAuth → API key → OAuth 切换。

## 许可证与致谢

QuotaBar 使用 [AGPL-3.0](LICENSE) 许可证。从 CodexBar 改编的代码仍按其 MIT 条款提供。详见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

QuotaBar 基于 [CodexBar](https://github.com/steipete/CodexBar) 重写，使用了它的思路与实现细节。Copyright © 2026 Peter Steinberger。
