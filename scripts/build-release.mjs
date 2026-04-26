#!/usr/bin/env node

import { spawnSync } from 'node:child_process'
import { chmodSync, copyFileSync, existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { rm } from 'node:fs/promises'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { createHash } from 'node:crypto'

const SCRIPT_DIR = dirname(fileURLToPath(import.meta.url))
const REPO_ROOT = resolve(SCRIPT_DIR, '..')
const DIST_ROOT = join(REPO_ROOT, 'dist', 'release')
const VERSION = readVersion()
const CLI_BUNDLE_PATH = join(DIST_ROOT, 'apfelclaw.js')
const PLATFORM = 'darwin-arm64'
const CHAT_BINARY_PATH = join(DIST_ROOT, `apfelclaw-chat-${PLATFORM}`)

await rm(DIST_ROOT, { recursive: true, force: true })
mkdirSync(DIST_ROOT, { recursive: true })

run('bun', ['build', 'apps/cli/src/index.mjs', '--target=node', '--outfile', CLI_BUNDLE_PATH], 'Bundle Node CLI')
run('bun', ['build', 'apps/tui/src/index.tsx', '--compile', '--target=bun-darwin-arm64', '--outfile', CHAT_BINARY_PATH], 'Build arm64 chat binary')
run('swift', ['build', '--package-path', 'packages/apfelclaw-server', '-c', 'release', '--product', 'apfelclaw-backend'], 'Build arm64 backend')

const backendPath = join(REPO_ROOT, 'packages/apfelclaw-server/.build/arm64-apple-macosx/release/apfelclaw-backend')
if (!existsSync(backendPath)) {
  throw new Error(`Missing backend binary: ${backendPath}`)
}

const bundleRoot = join(DIST_ROOT, `apfelclaw-v${VERSION}-${PLATFORM}`)
const binDir = join(bundleRoot, 'bin')
const libexecBinDir = join(bundleRoot, 'libexec', 'bin')
const libexecCliDir = join(bundleRoot, 'libexec', 'cli')

mkdirSync(binDir, { recursive: true })
mkdirSync(libexecBinDir, { recursive: true })
mkdirSync(libexecCliDir, { recursive: true })

writeFileSync(
  join(binDir, 'apfelclaw'),
  [
    '#!/usr/bin/env bash',
    'set -euo pipefail',
    'SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"',
    'exec node "$SCRIPT_DIR/../libexec/cli/apfelclaw.js" "$@"',
    '',
  ].join('\n'),
  'utf8'
)
chmodSync(join(binDir, 'apfelclaw'), 0o755)

copyFileSync(CHAT_BINARY_PATH, join(binDir, 'apfelclaw-chat'))
chmodSync(join(binDir, 'apfelclaw-chat'), 0o755)

copyFileSync(backendPath, join(libexecBinDir, 'apfelclaw-backend'))
chmodSync(join(libexecBinDir, 'apfelclaw-backend'), 0o755)

copyFileSync(CLI_BUNDLE_PATH, join(libexecCliDir, 'apfelclaw.js'))
writeFileSync(join(libexecCliDir, 'package.json'), `${JSON.stringify({ type: 'module' }, null, 2)}\n`, 'utf8')

const archiveName = `apfelclaw-v${VERSION}-${PLATFORM}.tar.gz`
run('tar', ['-czf', join(DIST_ROOT, archiveName), '-C', DIST_ROOT, `apfelclaw-v${VERSION}-${PLATFORM}`], `Create ${archiveName}`)

const checksum = await sha256(join(DIST_ROOT, archiveName))
writeFileSync(join(DIST_ROOT, `${archiveName}.sha256`), `${checksum}  ${archiveName}\n`, 'utf8')

console.log(`Release bundle is ready in ${DIST_ROOT}`)

function run(command, args, label) {
  console.log(label)
  const result = spawnSync(command, args, {
    cwd: REPO_ROOT,
    stdio: 'inherit',
    env: process.env,
  })
  if (result.status !== 0) {
    throw new Error(`${label} failed.`)
  }
}

function readVersion() {
  const source = readFileSync(join(REPO_ROOT, 'packages/apfelclaw-server/Sources/ApfelClawCore/Support/AppVersion.swift'), 'utf8')
  const match = source.match(/current = "([^"]+)"/)
  if (!match) {
    throw new Error('Unable to read app version.')
  }
  return match[1]
}

async function sha256(filePath) {
  const data = readFileSync(filePath)
  return createHash('sha256').update(data).digest('hex')
}
