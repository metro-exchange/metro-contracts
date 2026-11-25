#!/usr/bin/env node
import { execFileSync } from 'node:child_process';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const xmetroRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const run = (command, args, { cwd = xmetroRoot, profile } = {}) => {
  console.log(`\n> ${profile ? `FOUNDRY_PROFILE=${profile} ` : ''}${command} ${args.join(' ')}`);
  execFileSync(command, args, {
    cwd,
    stdio: 'inherit',
    env: profile ? { ...process.env, FOUNDRY_PROFILE: profile } : process.env,
  });
};

run('forge', ['build'], { cwd: path.join(xmetroRoot, '../commission') });
run('forge', ['build'], { profile: 'core' });
run('forge', ['build'], { profile: 'adapter' });
for (const script of ['build-qa-core.mjs', 'preflight.mjs', 'deploy.mjs', 'v2-pools.mjs']) {
  run('node', [path.join('script/base-qa', script)]);
}
