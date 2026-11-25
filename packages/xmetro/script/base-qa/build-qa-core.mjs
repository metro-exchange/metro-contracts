#!/usr/bin/env node
import { execFileSync } from 'node:child_process';
import { cpSync, mkdtempSync, rmSync, symlinkSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const xmetroRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const outDir = path.join(xmetroRoot, 'out-testbed');
const scratch = mkdtempSync(path.join(tmpdir(), 'xmetro-qa-core-'));
const removeScratch = () => rmSync(scratch, { recursive: true, force: true });
for (const signal of ['SIGINT', 'SIGTERM']) {
  process.on(signal, () => {
    removeScratch();
    process.exit(1);
  });
}

try {
  for (const entry of ['src', 'script', 'foundry.toml', 'remappings.txt', 'foundry.lock']) {
    cpSync(path.join(xmetroRoot, entry), path.join(scratch, entry), { recursive: true });
  }
  symlinkSync(path.join(xmetroRoot, 'lib'), path.join(scratch, 'lib'));
  execFileSync('git', ['apply', path.join(xmetroRoot, 'script/base-qa/qa-timers.patch')], {
    cwd: scratch,
    stdio: 'inherit',
  });
  execFileSync('forge', ['build', '--root', scratch, '--out', outDir], {
    stdio: 'inherit',
    env: { ...process.env, FOUNDRY_PROFILE: 'deploy' },
  });
  console.log(`Short-timer artifacts written to ${outDir}`);
} finally {
  removeScratch();
}
