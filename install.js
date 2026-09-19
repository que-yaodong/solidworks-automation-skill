#!/usr/bin/env node
// Install the downloaded repository, keeping its shared CAD scripts together.
const { spawnSync } = require('node:child_process');
const path = require('node:path');
const args = process.argv.slice(2);
if (args.includes('--help') || args.includes('-h')) {
  console.log('node install.js [--verify-only] [--library-root PATH] [--codex-skills-root PATH] [--codex-home PATH] [--skill-name NAME]');
  process.exit(0);
}
if (process.platform !== 'win32') {
  console.error('This installer targets Windows. See 安装说明.md.');
  process.exit(1);
}
const options = { '--library-root': '-LibraryRoot', '--codex-skills-root': '-CodexSkillsRoot', '--codex-home': '-CodexHome', '--skill-name': '-SkillName' };
const forwarded = [];
for (let i = 0; i < args.length; i++) {
  if (args[i] === '--verify-only') forwarded.push('-VerifyOnly');
  else if (options[args[i]] && args[i + 1] && !args[i + 1].startsWith('-')) forwarded.push(options[args[i]], args[++i]);
  else { console.error('Unknown or incomplete option: ' + args[i]); process.exit(2); }
}
const exe = path.join(process.env.SystemRoot || 'C:\\Windows', 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe');
const result = spawnSync(exe, ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', path.join(__dirname, 'install.ps1'), ...forwarded], { stdio: 'inherit', windowsHide: true });
if (result.error) console.error(result.error.message);
process.exit(result.status === null ? 1 : result.status);
