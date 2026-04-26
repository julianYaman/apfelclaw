#!/usr/bin/env node

import { spawn, spawnSync } from 'node:child_process'
import { existsSync, openSync, readFileSync, realpathSync } from 'node:fs'
import { mkdir, readFile, rm, writeFile } from 'node:fs/promises'
import { homedir } from 'node:os'
import { dirname, join, resolve } from 'node:path'
import process from 'node:process'
import { fileURLToPath } from 'node:url'
import ora from 'ora'

import { runInteractiveOnboarding } from './onboarding.mjs'

const APP_VERSION = '0.2.0'
const API_BASE = process.env.APFELCLAW_API_BASE ?? 'http://127.0.0.1:4242'
const CLI_SOURCE_DIR = dirname(fileURLToPath(import.meta.url))
const REPO_ROOT = resolve(CLI_SOURCE_DIR, '../../..')
const APP_ROOT = join(homedir(), '.apfelclaw')
const CONFIG_PATH = join(APP_ROOT, 'config.json')
const STATE_PATH = join(APP_ROOT, 'state.json')
const PID_PATH = join(APP_ROOT, 'apfelclaw.pid')
const LOG_DIR = join(homedir(), 'Library', 'Logs', 'apfelclaw')
const LOG_PATH = join(LOG_DIR, 'apfelclaw.log')

const DEFAULT_CONFIG = {
  assistantName: 'Apfelclaw',
  userName: 'You',
  approvalMode: 'trusted-readonly',
  debug: false,
  memoryEnabled: true,
  defaultCalendarScope: 'all-visible',
  terminalToolsEnabled: true,
  apfelAutostartEnabled: true,
}

const DEFAULT_STATE = {
  schemaVersion: 1,
  onboardingCompletedAt: null,
  installSource: 'unknown',
  lastRunVersion: null,
}

main()

async function main() {
  try {
    await ensureAppDirs()
    const args = process.argv.slice(2)

    if (args.includes('--help') || args.includes('-h')) {
      printHelp()
      return
    }

    const [command] = args

    switch (command) {
      case 'serve':
        await runServe()
        return
      case 'stop':
        await stopBackgroundBackend()
        console.log('apfelclaw backend stopped.')
        return
      case 'chat':
        await runChat()
        return
      case 'setup':
        await runOnboarding({ force: true })
        return
      case '--status':
        await printStatus()
        return
      case '--update':
        await runUpdate()
        return
      case undefined:
        break
      default:
        throw new Error(`Unknown command: ${command}`)
    }

    const state = await loadState()
    if (!state.onboardingCompletedAt) {
      await runOnboarding({ force: false })
      return
    }

    printHeader()
    printHelp(false)
    await printStatus()
  } catch (error) {
    console.error(formatError(error))
    process.exitCode = 1
  }
}

async function runOnboarding({ force }) {
  const existingState = await loadState()
  if (existingState.onboardingCompletedAt && !force) {
    printHeader()
    printHelp(false)
    await printStatus()
    return
  }

  if (!process.stdin.isTTY || !process.stdout.isTTY) {
    throw new Error('Onboarding requires an interactive terminal. Run `apfelclaw` or `apfelclaw setup` in a normal shell.')
  }

  const currentConfig = await loadConfig()
  const result = await runInteractiveOnboarding({
    currentConfig,
    persistConfig: saveConfig,
    startBackend: startBackgroundBackend,
    setupTelegram: (botToken) => postJson('/remotecontrol/providers/telegram/setup', { botToken }),
    waitForTelegramLink,
  })

  const state = await loadState()
  await saveState({
    ...state,
    onboardingCompletedAt: new Date().toISOString(),
    installSource: detectInstallSource(),
    lastRunVersion: APP_VERSION,
  })

  console.log('')
  console.log('Setup complete.')
  console.log(`Assistant: ${result.assistantName}`)
  console.log(`User: ${result.userName}`)
  console.log(`Approval mode: ${formatApprovalMode(result.approvalMode)}`)
  if (result.telegramConfigured && !result.telegramLinked) {
    console.log('Telegram is configured, but the private chat link will complete after you message the bot.')
  }
  console.log('')
  console.log('Next steps:')
  console.log('  apfelclaw chat')
  console.log('  apfelclaw --status')
}

async function runServe() {
  const backend = resolveBackendCommand()
  const child = spawn(backend.command, backend.args, {
    stdio: 'inherit',
    env: process.env,
  })

  await new Promise((resolvePromise, rejectPromise) => {
    child.on('exit', (code) => {
      if (code === 0) {
        resolvePromise()
      } else {
        rejectPromise(new Error(`apfelclaw-backend exited with status ${code ?? 1}.`))
      }
    })
    child.on('error', rejectPromise)
  })
}

async function runChat() {
  const state = await loadState()
  if (!state.onboardingCompletedAt) {
    throw new Error('Onboarding is not complete yet. Run `apfelclaw` first.')
  }

  if (!(await isBackendHealthy())) {
    throw new Error('Backend is not running. Start it with: apfelclaw serve')
  }

  const chat = resolveChatCommand()
  const child = spawn(chat.command, chat.args, {
    stdio: 'inherit',
    env: process.env,
  })

  await new Promise((resolvePromise, rejectPromise) => {
    child.on('exit', (code) => {
      if (code === 0) {
        resolvePromise()
      } else {
        rejectPromise(new Error(`apfelclaw-chat exited with status ${code ?? 1}.`))
      }
    })
    child.on('error', rejectPromise)
  })
}

async function printStatus() {
  const config = await loadConfig()
  const state = await loadState()
  const backendRunning = await isBackendHealthy()
  let liveStatus = null
  const backendPid = readPidFile()
  const backendCommand = resolveBackendCommand()

  if (backendRunning) {
    try {
      liveStatus = await getJson('/status')
    } catch {
      liveStatus = null
    }
  }

  const lines = [
    ['version', APP_VERSION],
    ['installSource', state.installSource ?? detectInstallSource()],
    ['onboardingCompleted', String(Boolean(state.onboardingCompletedAt))],
    ['onboardingCompletedAt', state.onboardingCompletedAt ?? 'not yet'],
    ['backendRunning', String(backendRunning)],
    ['backendPid', backendPid ? String(backendPid) : 'unknown'],
    ['backendCommand', renderCommand(backendCommand)],
    ['configPath', CONFIG_PATH],
    ['statePath', STATE_PATH],
    ['pidPath', PID_PATH],
    ['logPath', LOG_PATH],
    ['assistantName', config.assistantName],
    ['userName', config.userName],
    ['approvalMode', formatApprovalMode(config.approvalMode)],
    ['apfelAutostartEnabled', String(config.apfelAutostartEnabled)],
  ]

  if (liveStatus) {
    lines.push(
      ['backendStartedAt', liveStatus.startedAt],
      ['backendUptimeSeconds', String(liveStatus.uptimeSeconds)],
      ['sessionCount', String(liveStatus.sessionCount)],
      ['telegramEnabled', String(Boolean(liveStatus.remoteControl.telegram?.enabled))],
      ['telegramBotUsername', liveStatus.remoteControl.telegram?.botUsername ?? 'unverified'],
      ['telegramLinked', String(Boolean(liveStatus.remoteControl.telegram?.approvedChatID != null && liveStatus.remoteControl.telegram?.approvedUserID != null))],
      ['telegramLinking', String(Boolean(liveStatus.remoteControl.telegram?.linking))],
      ['apfelInstalledVersion', liveStatus.apfel?.installedVersion ?? 'unknown'],
      ['apfelLatestVersion', liveStatus.apfel?.latestVersion ?? 'unknown'],
      ['apfelInstallSource', liveStatus.apfel?.installSource ?? 'unknown'],
      ['apfelUpdateAvailable', String(Boolean(liveStatus.apfel?.updateAvailable))],
      ['apfelCanUpgrade', String(Boolean(liveStatus.apfel?.canUpgrade))],
      ['apfelCanRestart', String(Boolean(liveStatus.apfel?.canRestart))],
      ['apfelRestartMode', liveStatus.apfel?.restartMode ?? 'unknown'],
      ['apfelLastError', liveStatus.apfel?.lastError ?? 'none'],
    )
  } else {
    lines.push(
      ['backendStartedAt', 'unavailable while backend is down'],
      ['backendUptimeSeconds', 'unavailable while backend is down'],
      ['sessionCount', 'unavailable while backend is down'],
      ['telegramEnabled', 'unavailable while backend is down'],
      ['telegramBotUsername', 'unavailable while backend is down'],
      ['telegramLinked', 'unavailable while backend is down'],
      ['telegramLinking', 'unavailable while backend is down'],
      ['apfelInstalledVersion', 'unavailable while backend is down'],
      ['apfelLatestVersion', 'unavailable while backend is down'],
      ['apfelInstallSource', 'unavailable while backend is down'],
      ['apfelUpdateAvailable', 'unavailable while backend is down'],
      ['apfelCanUpgrade', 'unavailable while backend is down'],
      ['apfelCanRestart', 'unavailable while backend is down'],
      ['apfelRestartMode', 'unavailable while backend is down'],
      ['apfelLastError', 'unavailable while backend is down'],
    )
  }

  const width = Math.max(...lines.map(([key]) => key.length))
  for (const [key, value] of lines) {
    console.log(`${key.padEnd(width)} : ${value}`)
  }
}

async function runUpdate() {
  const installSource = detectInstallSource()
  if (installSource !== 'homebrew') {
    throw new Error('Automatic update is only supported when apfelclaw is installed with Homebrew.')
  }

  const spinner = ora('Checking Homebrew and updating apfelclaw...').start()
  try {
    runCommandOrThrow('brew', ['update-if-needed'])
    runCommandOrThrow('brew', ['upgrade', 'apfelclaw'])

    if (isBrewFormulaInstalled('apfel')) {
      runCommandOrThrow('brew', ['upgrade', 'apfel'])
      spinner.succeed('Updated apfelclaw and apfel via Homebrew.')
      return
    }

    spinner.succeed('Updated apfelclaw via Homebrew. apfel is not Homebrew-managed, so it was left unchanged.')
  } catch (error) {
    spinner.fail('Update failed.')
    throw error
  }
}

async function startBackgroundBackend() {
  if (await isBackendHealthy()) {
    return
  }

  if (detectInstallSource() === 'homebrew' && isBrewFormulaInstalled('apfelclaw')) {
    runCommandOrThrow('brew', ['services', 'start', 'apfelclaw'])
    await waitForHealth()
    return
  }

  const backend = resolveBackendCommand()
  const out = openSync(LOG_PATH, 'a')
  const child = spawn(backend.command, backend.args, {
    detached: true,
    stdio: ['ignore', out, out],
    env: {
      ...process.env,
      APFELCLAW_PID_FILE: PID_PATH,
    },
  })
  child.unref()
  await waitForHealth()
}

async function stopBackgroundBackend() {
  if (detectInstallSource() === 'homebrew' && isBrewFormulaInstalled('apfelclaw')) {
    runCommandOrThrow('brew', ['services', 'stop', 'apfelclaw'])
    return
  }

  if (!existsSync(PID_PATH)) {
    throw new Error('apfelclaw is not running.')
  }

  const pid = Number(readFileSync(PID_PATH, 'utf8').trim())
  if (!Number.isFinite(pid)) {
    throw new Error('apfelclaw pid file is invalid.')
  }

  process.kill(pid, 'SIGTERM')
  await rm(PID_PATH, { force: true })
}

async function waitForTelegramLink() {
  const deadline = Date.now() + 60_000
  while (Date.now() < deadline) {
    try {
      const status = await getJson('/remotecontrol/providers/telegram')
      if (status.approvedChatID != null && status.approvedUserID != null && status.linking === false) {
        return true
      }
    } catch {
      // Ignore transient backend errors while waiting.
    }

    await sleep(3_000)
  }

  return false
}

async function waitForHealth() {
  const deadline = Date.now() + 60_000
  while (Date.now() < deadline) {
    if (await isBackendHealthy()) {
      return
    }
    await sleep(500)
  }

  throw new Error('apfelclaw backend did not become healthy after startup.')
}

async function isBackendHealthy() {
  try {
    await getJson('/health')
    return true
  } catch {
    return false
  }
}

async function getJson(pathname) {
  const controller = new AbortController()
  const timeout = setTimeout(() => controller.abort(), 5000)
  try {
    const response = await fetch(`${API_BASE}${pathname}`, { signal: controller.signal })
    if (!response.ok) {
      throw new Error(await extractError(response))
    }
    return await response.json()
  } finally {
    clearTimeout(timeout)
  }
}

async function postJson(pathname, payload) {
  const controller = new AbortController()
  const timeout = setTimeout(() => controller.abort(), 10_000)
  try {
    const response = await fetch(`${API_BASE}${pathname}`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify(payload),
      signal: controller.signal,
    })
    if (!response.ok) {
      throw new Error(await extractError(response))
    }
    return await response.json()
  } finally {
    clearTimeout(timeout)
  }
}

async function extractError(response) {
  const text = (await response.text()).trim()
  if (!text) {
    return `Request failed (${response.status} ${response.statusText})`
  }

  try {
    const parsed = JSON.parse(text)
    return parsed.reason ?? parsed.error ?? parsed.message ?? text
  } catch {
    return text
  }
}

function resolveBackendCommand() {
  const envBinary = process.env.APFELCLAW_BACKEND_BIN
  if (envBinary) {
    return { command: envBinary, args: [] }
  }

  const cliRealPath = realpathSafe(process.argv[1])
  if (cliRealPath) {
    const installCandidates = [
      join(dirname(cliRealPath), 'apfelclaw-backend'),
      join(dirname(cliRealPath), '../bin/apfelclaw-backend'),
      join(dirname(cliRealPath), '../libexec/bin/apfelclaw-backend'),
    ]
    for (const candidate of installCandidates) {
      if (existsSync(candidate)) {
        return { command: candidate, args: [] }
      }
    }
  }

  const pathBinary = which('apfelclaw-backend')
  if (pathBinary) {
    return { command: pathBinary, args: [] }
  }

  const repoBinaryCandidates = [
    join(REPO_ROOT, 'packages/apfelclaw-server/.build/arm64-apple-macosx/debug/apfelclaw-backend'),
    join(REPO_ROOT, 'packages/apfelclaw-server/.build/x86_64-apple-macosx/debug/apfelclaw-backend'),
    join(REPO_ROOT, 'packages/apfelclaw-server/.build/debug/apfelclaw-backend'),
  ]
  for (const candidate of repoBinaryCandidates) {
    if (existsSync(candidate)) {
      return { command: candidate, args: [] }
    }
  }

  return {
    command: 'swift',
    args: ['run', '--package-path', join(REPO_ROOT, 'packages/apfelclaw-server'), 'apfelclaw-backend'],
  }
}

function resolveChatCommand() {
  if (process.argv[1]) {
    const cliDir = dirname(realpathSafe(process.argv[1]) ?? process.argv[1])
    const installCandidates = [
      join(cliDir, 'apfelclaw-chat'),
      join(cliDir, '../../bin/apfelclaw-chat'),
      join(cliDir, '../bin/apfelclaw-chat'),
    ]
    for (const candidate of installCandidates) {
      if (existsSync(candidate)) {
        return { command: candidate, args: [] }
      }
    }
  }

  const pathBinary = which('apfelclaw-chat')
  if (pathBinary) {
    return { command: pathBinary, args: [] }
  }

  const repoBinary = join(REPO_ROOT, 'apps/tui/dist/apfelclaw-chat')
  if (existsSync(repoBinary)) {
    return { command: repoBinary, args: [] }
  }

  return {
    command: 'bun',
    args: ['--cwd', join(REPO_ROOT, 'apps/tui'), 'run', 'dev'],
  }
}

async function loadConfig() {
  return await loadJson(CONFIG_PATH, DEFAULT_CONFIG)
}

async function saveConfig(config) {
  await writeJson(CONFIG_PATH, config)
}

async function loadState() {
  return await loadJson(STATE_PATH, { ...DEFAULT_STATE, installSource: detectInstallSource() })
}

async function saveState(state) {
  await writeJson(STATE_PATH, state)
}

async function loadJson(filePath, fallback) {
  try {
    const raw = await readFile(filePath, 'utf8')
    return { ...fallback, ...JSON.parse(raw) }
  } catch {
    return structuredClone(fallback)
  }
}

async function writeJson(filePath, value) {
  await writeFile(filePath, `${JSON.stringify(value, null, 2)}\n`, 'utf8')
}

function detectInstallSource() {
  const scriptPath = realpathSafe(process.argv[1] ?? '') ?? ''
  if (scriptPath.includes('/Cellar/apfelclaw/')) {
    return 'homebrew'
  }
  if (scriptPath) {
    return 'manual'
  }
  return 'unknown'
}

function isBrewFormulaInstalled(formula) {
  const result = spawnSync('brew', ['info', '--json=v2', formula], { encoding: 'utf8' })
  if (result.status !== 0 || !result.stdout) {
    return false
  }

  try {
    const payload = JSON.parse(result.stdout)
    return Boolean(payload.formulae?.[0]?.installed?.length)
  } catch {
    return false
  }
}

function runCommandOrThrow(command, args) {
  const result = spawnSync(command, args, { stdio: 'pipe', encoding: 'utf8' })
  if (result.status !== 0) {
    throw new Error((result.stderr || result.stdout || `Command failed: ${command}`).trim())
  }
  return result
}

function which(binary) {
  const result = spawnSync('/usr/bin/which', [binary], { encoding: 'utf8' })
  if (result.status !== 0) {
    return null
  }
  const value = result.stdout.trim()
  return value || null
}

function readPidFile() {
  if (!existsSync(PID_PATH)) {
    return null
  }

  const value = Number(readFileSync(PID_PATH, 'utf8').trim())
  return Number.isFinite(value) ? value : null
}

function realpathSafe(filePath) {
  try {
    return realpathSync(filePath)
  } catch {
    return null
  }
}

function printHeader() {
  console.log(`apfelclaw ${APP_VERSION}`)
  console.log('')
}

function printHelp(includeHeader = true) {
  if (includeHeader) {
    printHeader()
  }

  console.log('Commands:')
  console.log('  apfelclaw           Run onboarding on first launch, then show help and status')
  console.log('  apfelclaw setup     Re-run the onboarding guide')
  console.log('  apfelclaw serve     Run the Swift backend in the foreground')
  console.log('  apfelclaw chat      Launch the separate chat application')
  console.log('  apfelclaw stop      Stop the managed backend')
  console.log('  apfelclaw --status  Show backend, apfel, and Telegram status')
  console.log('  apfelclaw --update  Update apfelclaw and Homebrew-managed apfel')
  console.log('')
}

function formatApprovalMode(mode) {
  switch (mode) {
    case 'always':
      return 'Always ask'
    case 'ask-once-per-tool-per-session':
      return 'Ask once per tool per session'
    case 'trusted-readonly':
      return 'Trusted read-only'
    default:
      return mode
  }
}

function formatTelegramStatus(status) {
  if (!status) {
    return 'unavailable'
  }
  if (!status.enabled) {
    return 'disabled'
  }
  if (status.approvedChatID != null && status.approvedUserID != null) {
    return `linked to @${status.botUsername ?? 'bot'}`
  }
  if (status.linking) {
    return `waiting for first message to @${status.botUsername ?? 'bot'}`
  }
  return `enabled (${status.botUsername ?? 'bot'})`
}

function renderCommand(resolved) {
  if (!resolved) {
    return 'unknown'
  }
  return [resolved.command, ...(resolved.args ?? [])].join(' ')
}

function formatError(error) {
  if (error instanceof Error) {
    return error.message
  }
  return String(error)
}

function sleep(ms) {
  return new Promise((resolvePromise) => setTimeout(resolvePromise, ms))
}

async function ensureAppDirs() {
  await mkdir(APP_ROOT, { recursive: true })
  await mkdir(LOG_DIR, { recursive: true })
}
