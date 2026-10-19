# dsh-open-in-app-lite

把 DeepSeek Harness 桌面端右上角的 **Open In…** 菜单收成四张固定卡片——文件资源管理器、VS Code、Git Bash、**VSCodium**——并带上各自的真实图标。

只影响「用哪个本地应用打开工作区」这一个动作，不动 DSH 本体，也不改 `app.asar`。

## 为什么需要它

上游 `@deepseek-ai/dsh-host-open-in-app` 的应用目录是**编译期固定的白名单**，`cordis.yml` 里只能配三个超时参数：

```yaml
config:
  probeTimeoutMs: 10000
  iconTimeoutMs: 10000
  launchWatchMs: 1000
```

于是：

- 装过的 Cursor / Windsurf / JetBrains / Fork / Windows Terminal 会全部挤进菜单，没法关掉；
- 目录里**没有 VSCodium**；
- 浏览器侧的标签词典同样没有 `app.vscodium`，就算宿主返回了这个 id，前端也会直接过滤掉。

上游 README 也写明了这是已知限制：「目录在构建期固定……扩展列表意味着同时扩展 `OPEN_IN_APP_CATALOG` 与浏览器包的词典」。所以这个需求只能自己做插件。

> `dsh-open-in-app` 这个 npm 名字已被另一个同主题插件占用（做的是自定义头部控件、列出全部应用）。本项目是"更小的那一版"：只保留四项，因此取名 `-lite`。

## 包结构

| 包 | 角色 |
| --- | --- |
| [`packages/bundle`](packages/bundle) `dsh-open-in-app-lite` | **组合包**。只有一个 `cordis.patch.yml`：禁用上游两项、插入下面两项。安装它是唯一需要的一步 |
| [`packages/host`](packages/host) `dsh-open-in-app-lite-host` | 宿主插件。`/open-in-app/apps`、`/icon/<id>`、`/open` 三条路由 + 四应用目录，零外部依赖（只用 Node 内置模块） |
| [`packages/client`](packages/client) `dsh-open-in-app-lite-client` | 浏览器插件。沿用官方分体按钮，只补了 `vscodium` 的词条 |

## 安装

### 标准方式：插件管理器

在侧边栏「插件」页安装 `dsh-open-in-app-lite`，DSH 会自己带上 bundle 的 patch 层，不需要手改任何 YAML。命令行等价：

```bash
dsh plugin --profile <name> add dsh-open-in-app-lite
```

装完重启 DSH。

> `desktop` 这个 profile 被 Electron 独占，CLI 会拒绝管理它。桌面端请在应用内的插件页操作。

### 离线 / 桌面 profile 兜底：脚本

```powershell
git clone https://github.com/huluzhou/dsh-open-in-app-lite.git "$env:USERPROFILE\dsh-open-in-app-lite"
cd "$env:USERPROFILE\dsh-open-in-app-lite"
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

它做三件事：把三个包 junction 到 profile 的 `node_modules`、写 `link:` 依赖、把 `dsh-open-in-app-lite` 追加进 `dsh.profile.bundles`。**不碰** profile 自己的 `cordis.patch.yml`——patch 在 bundle 里。

参数：`-ProfileName`（默认 `desktop`）、`-DshHome`（默认 `$env:USERPROFILE\.dsh`）。卸载跑 `.\uninstall.ps1`。

> 之前手工装过？先把 profile 的 `cordis.patch.yml` 里那段 `local-open-in-app` 删掉，否则两层会插入重复的行。

## 实现要点

- **只认已安装的应用**：每次请求检查 exe 是否存在，没装的不会出现在菜单里（没装 Git for Windows 就没有 Git Bash 项）。
- **图标**：.NET `[System.Drawing.Icon]::ExtractAssociatedIcon` 抽 32px PNG，首次约 0.8s/个，之后内存缓存（几十毫秒）；失败返回 404，前端自动退回通用图标。
- **启动**：`spawn` 时 `detached: true`，编辑器不被宿主生命周期绑住。
- **环境清理**（关键）：宿主自身跑在 Electron 里，环境带 `ELECTRON_RUN_AS_NODE=1`，子进程会继承。VS Code / VSCodium 拿到它就会**降级成 node 解释器**，把目录参数当入口脚本 require 然后 `exit 1`——表现是"点了没反应"。插件启动前清掉 `ELECTRON_RUN_AS_NODE`、`ELECTRON_NO_ATTACH_CONSOLE`、`NODE_OPTIONS`、`NODE_PATH` 等。
- **失败可见**：`spawn` 成功不等于打开成功，所以启动后观察 800ms；非 0 提前退出按失败处理（HTTP 502 → 前端弹「打开失败，请重试」），存活超过 800ms 视为成功。单实例转发（exit 0）仍算成功。

## 已知限制

- **仅 Windows**：依赖 `explorer.exe` / `VSCodium.exe` / `git-bash.exe` 与 PowerShell 图标提取。
- **图标 32px**：`ExtractAssociatedIcon` 的固有上限，菜单里按 14px 显示。
- **文档预览的菜单也会收窄**：替换的是整个 `ui-open-in-app`，侧边栏文档预览的「打开方式」同样只剩这四个应用。这是刻意的，两处共用一套目录。
- **VSCodium 打开 WSL 路径**：没有微软的 WSL 扩展，`\\wsl.localhost\...` 按普通 Windows UNC 目录处理，体验不同于 VS Code + WSL 远程。

## 维护者：发布

三个包按依赖顺序发布（host → client → bundle），一条命令搞定：

```bash
node scripts/publish.mjs            # 依次发布
node scripts/publish.mjs --dry-run  # 只打印不发布
node scripts/publish.mjs --tag next # 跟上游一样的 rc dist-tag
```

脚本会先校验账号、拒绝有未提交改动的仓库、跳过 registry 上已存在的版本，所以中断后重跑即可续发。

发布需要 **带 "Bypass 2FA" 的 Granular Token**——这个账号对 publish 动作强制 2FA，网页登录拿到的 token 不够用：

```bash
npm config set //registry.npmjs.org/:_authToken npm_xxx
```

版本号跟随 DSH CLI（当前 `0.2.1-rc.2`）：客户端 bundle 的 release 身份校验会拿它和宿主版本比对，`engines.dsh` 也按它声明兼容范围。

## License

MIT
