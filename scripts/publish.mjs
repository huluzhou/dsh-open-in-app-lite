#!/usr/bin/env node
/**
 * Publish the three packages in dependency order.
 *
 *   node scripts/publish.mjs [--tag latest] [--dry-run]
 *
 * Requires an npm credential that may publish this account's packages: a
 * granular access token with "Bypass 2FA" enabled, or a fresh OTP through
 * `npm publish --otp=<code>` (not supported here on purpose — a token is the
 * reproducible route).
 *
 * Preflight stops on: not logged in, a dirty tree, or a version that is
 * already on the registry; a package whose exact version exists is skipped
 * rather than failed, so a partial publish can be resumed by re-running.
 */
import { execFileSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const ORDER = ['host', 'client', 'bundle'];

const args = process.argv.slice(2);
const dryRun = args.includes('--dry-run');
const tagIndex = args.indexOf('--tag');
const tag = tagIndex === -1 ? 'latest' : args[tagIndex + 1];

function run(command, commandArgs, cwd) {
  return execFileSync(command, commandArgs, { cwd, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }).trim();
}

function manifestOf(name) {
  return JSON.parse(readFileSync(join(root, 'packages', name, 'package.json'), 'utf8'));
}

function publishedVersions(packageName) {
  try {
    const raw = run('npm', ['view', packageName, 'versions', '--json']);
    const parsed = JSON.parse(raw);
    return Array.isArray(parsed) ? parsed : [parsed];
  } catch {
    return [];
  }
}

let account;
try {
  account = run('npm', ['whoami']);
} catch (error) {
  console.error('not logged in to npm:', error.stderr?.toString().trim() ?? error.message);
  process.exit(1);
}
console.log(`npm account: ${account}`);
console.log(`dist-tag:    ${tag}${dryRun ? '  (dry run)' : ''}`);

const dirty = run('git', ['status', '--porcelain'], root);
if (dirty !== '' && !dryRun) {
  console.error('working tree is dirty; commit or stash before publishing:');
  console.error(dirty);
  process.exit(1);
}

let failures = 0;
for (const name of ORDER) {
  const manifest = manifestOf(name);
  const existing = publishedVersions(manifest.name);
  const line = `${manifest.name}@${manifest.version}`;

  if (existing.includes(manifest.version)) {
    console.log(`skip   ${line} (already published)`);
    continue;
  }
  if (dryRun) {
    console.log(`would  ${line}`);
    continue;
  }

  console.log(`publish ${line}`);
  try {
    execFileSync('npm', ['publish', '--access', 'public', '--tag', tag], {
      cwd: join(root, 'packages', name),
      stdio: 'inherit',
    });
  } catch {
    failures += 1;
    console.error(`failed ${line}`);
  }
}

process.exit(failures === 0 ? 0 : 1);
