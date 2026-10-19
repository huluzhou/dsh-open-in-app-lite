/**
 * Host half of dsh-open-in-app: a fixed four-application catalog
 * (Explorer · VS Code · Git Bash · VSCodium).
 *
 * Self-contained on purpose: only Node built-ins, so it resolves correctly
 * when linked into the profile's node_modules without the DSH packages being
 * importable from that path. Implements the same three routes the built-in
 * plugin serves, so the browser half can stay a thin variant of the shipped
 * split button.
 */
import { spawn } from 'node:child_process';
import { existsSync, statSync } from 'node:fs';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { isAbsolute, join } from 'node:path';

export const name = 'open-in-app-fixed';
export const inject = ['webServer', 'connection'];

const APPS_PATH = '/open-in-app/apps';
const ICON_PREFIX = '/open-in-app/icon';
const OPEN_PATH = '/open-in-app/open';

const MAX_BODY_BYTES = 64 * 1024;
const ICON_TIMEOUT_MS = 10_000;
const LAUNCH_WATCH_MS = 800;

const env = process.env;
const localAppData = env.LOCALAPPDATA ?? '';
const programFiles = env.ProgramFiles ?? 'C:\\Program Files';
const systemRoot = env.SystemRoot ?? 'C:\\Windows';
const powershell = join(systemRoot, 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe');

/**
 * Environment for launched desktop applications.
 *
 * The Host itself runs under Electron with `ELECTRON_RUN_AS_NODE=1` (the
 * bundled `node.cmd` sets it), and child processes inherit it. Any Electron
 * application — VS Code, VSCodium — then starts as a bare Node interpreter,
 * tries to resolve the directory argument as a module, and exits 1 before
 * creating a window. Strip the injection so launched apps behave as they do
 * from Explorer.
 */
const CHILD_ENV = (() => {
  const scrubbed = { ...env };
  for (const key of [
    'ELECTRON_RUN_AS_NODE',
    'ELECTRON_NO_ATTACH_CONSOLE',
    'ELECTRON_ENABLE_LOGGING',
    'ELECTRON_ENABLE_STACK_DUMPING',
    'NODE_OPTIONS',
    'NODE_PATH',
  ]) {
    delete scrubbed[key];
  }
  return scrubbed;
})();

/** The four allowed applications, in menu order. */
const CATALOG = [
  {
    id: 'explorer',
    args: ['{path}'],
    candidates: [join(systemRoot, 'explorer.exe')],
  },
  {
    id: 'vscode',
    args: ['{path}'],
    candidates: [
      join(localAppData, 'Programs', 'Microsoft VS Code', 'Code.exe'),
      join(programFiles, 'Microsoft VS Code', 'Code.exe'),
    ],
  },
  {
    id: 'gitbash',
    args: ['--cd={path}'],
    candidates: [join(programFiles, 'Git', 'git-bash.exe')],
  },
  {
    id: 'vscodium',
    args: ['{path}'],
    candidates: [
      join(localAppData, 'Programs', 'VSCodium', 'VSCodium.exe'),
      join(programFiles, 'VSCodium', 'VSCodium.exe'),
    ],
  },
];

function executableOf(app) {
  for (const candidate of app.candidates) {
    if (candidate.length > 0 && existsSync(candidate)) return candidate;
  }
  return undefined;
}

function availableApps() {
  const found = [];
  for (const app of CATALOG) {
    const executable = executableOf(app);
    if (executable !== undefined) found.push({ ...app, executable });
  }
  return found;
}

/**
 * The associated-icon extraction script. `-File` with positional args keeps
 * paths out of the command line's parsing surface. `ExtractAssociatedIcon`
 * yields 32px — the most the stock .NET surface gives without a native addon.
 */
const EXTRACT_ICON_PS1 = [
  'param([string]$Source, [string]$Target)',
  '$ErrorActionPreference = "Stop"',
  'Add-Type -AssemblyName System.Drawing',
  '$icon = [System.Drawing.Icon]::ExtractAssociatedIcon($Source)',
  'if ($null -eq $icon) { exit 1 }',
  '$bitmap = $icon.ToBitmap()',
  '$bitmap.Save($Target, [System.Drawing.Imaging.ImageFormat]::Png)',
  '',
].join('\n');

/** Run the extractor; resolves true only for a clean exit inside the deadline. */
function runExtractor(script, source, target) {
  return new Promise((resolve) => {
    let settled = false;
    let timer;
    const finish = (value) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      resolve(value);
    };
    const child = spawn(powershell, [
      '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', script, source, target,
    ], { windowsHide: true, stdio: 'ignore' });
    timer = setTimeout(() => {
      child.kill();
      finish(false);
    }, ICON_TIMEOUT_MS);
    child.once('error', () => finish(false));
    child.once('exit', (code) => finish(code === 0));
  });
}

async function extractIcon(executable) {
  let workDir;
  try {
    workDir = await mkdtemp(join(tmpdir(), 'dsh-local-open-in-'));
    const script = join(workDir, 'extract-icon.ps1');
    const outPng = join(workDir, 'icon.png');
    await writeFile(script, EXTRACT_ICON_PS1, 'utf8');
    if (!(await runExtractor(script, executable, outPng))) return null;
    const bytes = await readFile(outPng);
    return bytes.length === 0 ? null : { bytes, contentType: 'image/png' };
  } catch {
    return null;
  } finally {
    if (workDir !== undefined) await rm(workDir, { recursive: true, force: true }).catch(() => {});
  }
}

/** Extract once per application per plugin life; failures keep the null. */
const icons = new Map();
function iconOf(app) {
  let pending = icons.get(app.id);
  if (pending === undefined) {
    pending = extractIcon(app.executable);
    icons.set(app.id, pending);
  }
  return pending;
}

function sendJson(res, status, payload) {
  res.statusCode = status;
  res.setHeader('content-type', 'application/json; charset=utf-8');
  res.setHeader('cache-control', 'no-store');
  res.end(JSON.stringify(payload));
}

function sendMethodNotAllowed(res, allow) {
  res.statusCode = 405;
  res.setHeader('allow', allow);
  res.end();
}

/** Answer an untrusted/unauthenticated request; true when it was rejected. */
function rejected(ctx, req, res) {
  const connection = Reflect.get(ctx, 'connection');
  const rejection = connection?.requestRejection?.(req);
  if (rejection === undefined) return false;
  res.statusCode = rejection;
  res.end();
  return true;
}

/** Collect a bounded request body as UTF-8 text; null past the ceiling. */
function readBoundedBody(req) {
  return new Promise((resolve, reject) => {
    let size = 0;
    const chunks = [];
    req.on('data', (chunk) => {
      size += chunk.length;
      if (size > MAX_BODY_BYTES) {
        chunks.length = 0;
        resolve(null);
        req.resume();
        return;
      }
      chunks.push(chunk);
    });
    req.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')));
    req.on('error', reject);
  });
}

function parseOpenBody(text) {
  let value;
  try {
    value = JSON.parse(text);
  } catch {
    return null;
  }
  if (typeof value !== 'object' || value === null) return null;
  const { app, path } = value;
  if (typeof app !== 'string' || typeof path !== 'string') return null;
  return { app, path };
}

function isDirectory(path) {
  try {
    return statSync(path).isDirectory();
  } catch {
    return false;
  }
}

/**
 * Spawn detached so a long-lived editor never ties the host to exit.
 *
 * `spawn` alone only proves the launcher started: an app that dies immediately
 * (bad environment, missing runtime) would answer "opened" and leave the user
 * with nothing. Watch the first `LAUNCH_WATCH_MS`; a launcher still alive then
 * counts as opened, and an early non-zero exit becomes a visible failure.
 */
function launch(app, directory) {
  return new Promise((resolve, reject) => {
    const args = app.args.map((arg) => arg.split('{path}').join(directory));
    const child = spawn(app.executable, args, { detached: true, stdio: 'ignore', env: CHILD_ENV });
    let settled = false;
    let timer;
    const settle = (error) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      if (error === undefined) {
        child.unref();
        resolve();
      } else {
        reject(error);
      }
    };
    timer = setTimeout(() => settle(), LAUNCH_WATCH_MS);
    child.once('error', (error) => settle(error));
    child.once('exit', (code) => settle(code === 0 ? undefined : new Error(`launcher exited ${code}`)));
  });
}

export function apply(ctx) {
  ctx.effect(() => ctx.webServer.register({
    kind: 'exact',
    path: APPS_PATH,
    handler: async (req, res) => {
      if (rejected(ctx, req, res)) return;
      if (req.method !== 'GET') {
        sendMethodNotAllowed(res, 'GET');
        return;
      }
      sendJson(res, 200, { apps: availableApps().map((app) => app.id) });
    },
  }), `local-open-in-app: GET ${APPS_PATH}`);

  ctx.effect(() => ctx.webServer.register({
    kind: 'prefix',
    path: ICON_PREFIX,
    handler: async (req, res) => {
      if (rejected(ctx, req, res)) return;
      if (req.method !== 'GET') {
        sendMethodNotAllowed(res, 'GET');
        return;
      }
      const noIcon = () => sendJson(res, 404, { code: 'not-found', message: 'no icon' });
      const { pathname } = new URL(String(req.url), 'http://localhost');
      const id = pathname.slice(ICON_PREFIX.length).replace(/^\//, '');
      const app = availableApps().find((entry) => entry.id === id);
      if (app === undefined) {
        noIcon();
        return;
      }
      const icon = await iconOf(app);
      if (icon === null) {
        noIcon();
        return;
      }
      res.statusCode = 200;
      res.setHeader('content-type', icon.contentType);
      res.setHeader('cache-control', 'public, max-age=3600');
      res.end(icon.bytes);
    },
  }), `local-open-in-app: GET ${ICON_PREFIX}/<id>`);

  ctx.effect(() => ctx.webServer.register({
    kind: 'exact',
    path: OPEN_PATH,
    handler: async (req, res) => {
      if (rejected(ctx, req, res)) return;
      if (req.method !== 'POST') {
        sendMethodNotAllowed(res, 'POST');
        return;
      }
      if (String(req.headers['content-type']).split(';', 1)[0]?.trim().toLowerCase() !== 'application/json') {
        sendJson(res, 415, { code: 'unsupported-media-type', message: 'content-type must be application/json' });
        return;
      }
      let text;
      try {
        text = await readBoundedBody(req);
      } catch {
        sendJson(res, 400, { code: 'bad-request', message: 'request body unreadable' });
        return;
      }
      if (text === null) {
        sendJson(res, 413, { code: 'payload-too-large', message: 'request body is too large' });
        return;
      }
      const parsed = parseOpenBody(text);
      if (parsed === null) {
        sendJson(res, 400, { code: 'bad-request', message: 'request body must be JSON with string "app" and "path"' });
        return;
      }
      const app = availableApps().find((entry) => entry.id === parsed.app);
      if (app === undefined) {
        sendJson(res, 400, { code: 'bad-request', message: `unknown or unavailable app: ${parsed.app}` });
        return;
      }
      if (parsed.path === '' || !isAbsolute(parsed.path)) {
        sendJson(res, 400, { code: 'bad-request', message: 'path must be an absolute directory path' });
        return;
      }
      if (!isDirectory(parsed.path)) {
        sendJson(res, 404, { code: 'not-found', message: `directory does not exist: ${parsed.path}` });
        return;
      }
      try {
        await launch(app, parsed.path);
        sendJson(res, 200, { ok: true });
      } catch {
        sendJson(res, 502, { code: 'launch-failed', message: `failed to launch ${app.id}` });
      }
    },
  }), `local-open-in-app: POST ${OPEN_PATH}`);
}
