# dsh-open-in-app-lite

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

- every installed editor / Git GUI / terminal shows up with no way to hide it;
- **VSCodium is not in the catalog**;
- the browser half has no `app.vscodium` label, so even a returned id would be filtered out.

Upstream documents this as a known limitation: extending the list means extending both `OPEN_IN_APP_CATALOG` and the browser dictionary. Hence a plugin instead of a config tweak.

> The npm name `dsh-open-in-app` is already taken by a different plugin with a different UX (its own header control listing every app). This project is deliberately the smaller one — four entries only — so it ships as `-lite`.

## Packages

| Package | Role |
| --- | --- |
| [`packages/bundle`](packages/bundle) `dsh-open-in-app-lite` | **Bundle**: one `cordis.patch.yml` that disables the two upstream rows and inserts the two below. Installing this is the whole job |
| [`packages/host`](packages/host) `dsh-open-in-app-lite-host` | Host plugin: the three `/open-in-app` routes over a fixed catalog, Node built-ins only |
| [`packages/client`](packages/client) `dsh-open-in-app-lite-client` | Browser plugin: the shipped split button plus the `vscodium` label |

## Install

### Standard: the plugin manager

Install `dsh-open-in-app-lite` from the sidebar's plugin page; DSH applies the bundle patch itself — no YAML editing. CLI equivalent:

```bash
dsh plugin --profile <name> add dsh-open-in-app-lite
```

Restart DSH afterwards.

> The `desktop` profile is reserved for Electron and the CLI refuses to manage it; use the in-app plugin page there.

### Offline / desktop fallback: script

```powershell
git clone https://github.com/huluzhou/dsh-open-in-app-lite.git "$env:USERPROFILE\dsh-open-in-app-lite"
cd "$env:USERPROFILE\dsh-open-in-app-lite"
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

It junction-links the three packages, writes the `link:` dependencies and appends `dsh-open-in-app-lite` to `dsh.profile.bundles`. The profile's own `cordis.patch.yml` is left untouched — the patch travels with the bundle.

`-ProfileName` (default `desktop`) and `-DshHome` (default `$env:USERPROFILE\.dsh`) are accepted; `.\uninstall.ps1` reverses it.

> Installed by hand before? Remove the old `local-open-in-app` block from the profile's `cordis.patch.yml` first, otherwise both layers insert the same rows.

## How it works

- **Installed apps only**: executables are probed per request, so an app that is not installed never appears.
- **Icons**: .NET `[System.Drawing.Icon]::ExtractAssociatedIcon` renders a 32px PNG, cached in memory after the first ≈0.8s; failures answer 404 and the client falls back to a generic glyph.
- **Launch**: `spawn` with `detached: true` so an editor is not tied to the host's lifetime.
- **Environment scrubbing** (the subtle one): the Host runs under Electron with `ELECTRON_RUN_AS_NODE=1`, and children inherit it. VS Code / VSCodium then boot as a plain Node interpreter, treat the directory as an entry script and exit 1 — "clicking does nothing". Launches strip `ELECTRON_RUN_AS_NODE`, `ELECTRON_NO_ATTACH_CONSOLE`, `NODE_OPTIONS`, `NODE_PATH`.
- **Visible failures**: the launch is watched for 800ms; an early non-zero exit becomes HTTP 502 (UI shows "open failed"), while a single-instance forward (exit 0) still counts as success.

## Limitations

- **Windows only** — relies on `explorer.exe`, `VSCodium.exe`, `git-bash.exe` and PowerShell icon extraction.
- **32px icons** — the `ExtractAssociatedIcon` ceiling without a native addon.
- **Document-preview menus narrow too** — replacing the whole `ui-open-in-app` surface also limits the sidebar's "open with" menu to the same four apps. Intentional: both share one catalog.
- **WSL workspaces in VSCodium** — no Microsoft WSL extension, so `\\wsl.localhost\...` opens as a plain Windows UNC folder.

## Publishing

Publish in dependency order (host / client first, bundle last):

```bash
node scripts/publish.mjs            # host -> client -> bundle
node scripts/publish.mjs --dry-run  # show what would be published
node scripts/publish.mjs --tag next # mirror the upstream rc dist-tag
```

The script preflights the account, refuses a dirty tree, and skips versions already on the registry, so a partial publish resumes by re-running it.

Publishing needs a **granular access token with "Bypass 2FA" enabled** — this account enforces 2FA on the publish action, and the web-login token does not satisfy it:

```bash
npm config set //registry.npmjs.org/:_authToken npm_xxx
```

Versions track the DSH CLI (`0.2.1-rc.2` currently): the client bundle's release identity is compared against the host version, and `engines.dsh` declares the supported range.

## License

MIT
