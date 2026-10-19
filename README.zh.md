# dsh-open-in-app

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

上游 README 也写明了这是已知限制：「目录在构建期固定……扩展列表意味着同时扩展 `OPEN_IN_APP_CATALOG` 与浏览器包的词典」。所以这个需求只能自己做一对插件。

## 结构

| 包 | 角色 |
| --- | --- |
| [`host/`](host) `dsh-local-open-in-app` | 宿主插件。注册 `/open-in-app/apps`、`/open-in-app/icon/<id>`、`/open-in-app/open` 三条路由，目录固定为四个应用，零外部依赖（只用 Node 内置模块） |
| [`client/`](client) `dsh-local-ui-open-in-app` | 浏览器插件。沿用官方分体按钮的实现，只补了 `vscodium` 的标签词条 |

安装时会把这两个包 junction 到 profile 的 `node_modules`，并在 `cordis.patch.yml` 里禁用上游两项、插入这两项。

## 安装

```powershell
git clone https://github.com/huluzhou/dsh-open-in-app.git "$env:USERPROFILE\dsh-open-in-app"
cd "$env:USERPROFILE\dsh-open-in-app"
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

装完**完全退出** DeepSeek Harness 再打开（托盘里的图标也要退出，宿主进程不结束就不会重新加载插件）。

参数：

| 参数 | 默认值 | 说明 |
| --- | --- | --- |
| `-ProfileName` | `desktop` | profile 目录名，即 `$DshHome\profiles\<name>` |
| `-DshHome` | `$env:USERPROFILE\.dsh` | DSH 的用户目录 |

脚本会先备份 `package.json` 与 `cordis.patch.yml`（`*.bak-<时间戳>`），重复执行是安全的。

## 卸载

```powershell
cd "$env:USERPROFILE\dsh-open-in-app"
powershell -ExecutionPolicy Bypass -File .\uninstall.ps1
```

会移除 junction、依赖声明和 patch 段，然后同样需要重启 DSH。若 patch 段被手工改过导致匹配不上，脚本会明确提示，按提示删掉那段即可。

## 实现要点

- **只认已安装的应用**：每次请求时检查 exe 是否存在，没装的不会出现在菜单里（例如没装 Git for Windows 就没有 Git Bash 项）。
- **图标**：用 .NET 的 `[System.Drawing.Icon]::ExtractAssociatedIcon` 从 exe 抽 32px PNG，首次约 0.8s，之后走内存缓存（几十毫秒）。抽不到就返回 404，前端自动退回通用图标。
- **启动**：`spawn` 时 `detached: true`，编辑器不会被宿主生命周期绑住。
- **环境清理**（关键）：宿主自身跑在 Electron 里，环境里带着 `ELECTRON_RUN_AS_NODE=1`，子进程会继承。VS Code / VSCodium 拿到这个变量会**降级成 node 解释器**，把目录参数当入口脚本 require，然后 `exit 1`——表现就是"点了没反应"。插件在启动前清掉 `ELECTRON_RUN_AS_NODE`、`ELECTRON_NO_ATTACH_CONSOLE`、`NODE_OPTIONS`、`NODE_PATH` 等变量。
- **失败可见**：`spawn` 成功不等于打开成功，所以启动后观察 800ms；非 0 提前退出按失败处理（HTTP 502，前端弹「打开失败，请重试」），存活超过 800ms 视为成功。单实例转发（进程 exit 0）仍算成功，不会误报。

## 已知限制

- **仅 Windows**：依赖 `explorer.exe` / `VSCodium.exe` / `git-bash.exe` 与 PowerShell 图标提取，没有 macOS / Linux 实现。
- **图标 32px**：`ExtractAssociatedIcon` 的固有上限，不引入原生插件拿不到更大尺寸；菜单里按 14px 显示，够用。
- **只作用于桌面 profile**：`dsh` CLI 默认拒绝管理 `desktop` profile，所以这里不走 `dsh plugin`，而是直接改 profile 文件。
- **文档预览的「打开方式」也会收窄**：因为替换的是整个 `ui-open-in-app`，侧边栏文档预览里的打开菜单同样只剩这四个应用。这是刻意的——两处菜单共用一套目录。
- **git 工作区**：VSCodium 没有微软的 WSL 扩展，打开 `\\wsl.localhost\...` 是当普通 Windows UNC 目录用的，体验和 VS Code + WSL 远程不同。

## 目录约定

`dsh-local-*` 里的 `local` 指的是「部署在本地 profile、不发布到 npm」。两个包都标了 `"private": true`，避免误发。

## License

MIT
