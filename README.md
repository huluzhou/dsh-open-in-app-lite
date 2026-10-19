# dsh-open-in-app

Narrows DeepSeek Harness' desktop **Open In…** menu to four fixed entries — File Explorer, VS Code, Git Bash and **VSCodium** — each with its real executable icon.

It only changes which local application opens the workspace. DSH itself is untouched, and `app.asar` is never modified.

## Why this exists

Upstream `@deepseek-ai/dsh-host-open-in-app` resolves a **compile-time catalog**; the only configurable fields are three timeouts:

```yaml
config:
  probeTimeoutMs: 10000
  iconTimeoutMs: 10000
  launchWatchMs: 1000
```

As a result:

- every installed editor / Git GUI / terminal shows up in the menu with no way to hide it;
- **VSCodium is not in the catalog**;
- the browser half has no `app.vscodium` label, so even a returned id would be filtered out by the client.

Upstream documents this as a known limitation: extending the list means extending both `OPEN_IN_APP_CATALOG` and the browser dictionary. That is why this is a plugin pair rather than a config tweak.

## Packages

| Package | Role |
| --- | --- |
| [`host/`](host) `dsh-local-open-in-app` | Host plugin. Serves `/open-in-app/apps`, `/open-in-app/icon/<id>` and `/open-in-app/open` for a fixed four-application catalog. Node built-ins only. |
| [`client/`](client) `dsh-local-ui-open-in-app` | Browser plugin. The shipped split-button implementation with the `vscodium` label added. |

Installation junction-links both packages into the profile's `node_modules`, disables the two upstream rows in `cordis.patch.yml`, and inserts these two instead.

## Install

```powershell
git clone https://github.com/huluzhou/dsh-open-in-app.git "$env:USERPROFILE\dsh-open-in-app"
cd "$env:USERPROFILE\dsh-open-in-app"
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

Then **fully quit** and relaunch DeepSeek Harness — including the tray icon, otherwise the host process keeps running and never reloads plugins.

| Parameter | Default | Meaning |
| --- | --- | --- |
| `-ProfileName` | `desktop` | profile directory, i.e. `$DshHome\profiles\<name>` |
| `-DshHome` | `$env:USERPROFILE\.dsh` | DSH user directory |

The script backs up `package.json` and `cordis.patch.yml` as `*.bak-<timestamp>` and is safe to re-run.

## Uninstall

```powershell
cd "$env:USERPROFILE\dsh-open-in-app"
powershell -ExecutionPolicy Bypass -File .\uninstall.ps1
```

Removes the junctions, the dependency entries and the patch block; restart DSH afterwards.

## How it works

- **Installed apps only**: executables are probed per request, so an app that is not installed never appears (no Git Bash without Git for Windows).
- **Icons**: `.NET` `[System.Drawing.Icon]::ExtractAssociatedIcon` renders a 32px PNG. First call ≈0.8s per app, then cached in memory; failures answer 404 and the client falls back to a generic glyph.
- **Launch**: `spawn` with `detached: true` so an editor is not tied to the host's lifetime.
- **Environment scrubbing** (the subtle one): the Host itself runs under Electron with `ELECTRON_RUN_AS_NODE=1` set, and children inherit it. Any Electron app — VS Code, VSCodium — then boots as a plain Node interpreter, treats the directory argument as an entry script and exits 1, which looks like "clicking does nothing". Launch strips `ELECTRON_RUN_AS_NODE`, `ELECTRON_NO_ATTACH_CONSOLE`, `NODE_OPTIONS`, `NODE_PATH` and friends.
- **Visible failures**: a successful `spawn` proves nothing, so the launch is watched for 800ms. A non-zero early exit becomes HTTP 502 (the UI shows "open failed"), while a launcher that forwards to a single instance (exit 0) still counts as success.

## Limitations

- **Windows only** — relies on `explorer.exe`, `VSCodium.exe`, `git-bash.exe` and PowerShell icon extraction.
- **32px icons** — the `ExtractAssociatedIcon` ceiling without a native addon; fine at the menu's 14px.
- **Desktop profile only** — the `dsh` CLI refuses to manage the `desktop` profile, so the installer edits profile files directly.
- **Document-preview menus narrow too** — replacing the whole `ui-open-in-app` surface also limits the sidebar's "open with" menu to the same four apps. That is intentional: both menus share one catalog.
- **WSL workspaces in VSCodium** — VSCodium lacks Microsoft's WSL extension, so `\\wsl.localhost\...` opens as a plain Windows UNC folder, not a remote WSL workspace.

## License

MIT
