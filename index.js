/**
 * Host half of dsh-status-box.
 *
 * The Client half owns the in-frame status pill and reports status to the
 * native companion over the loopback bridge (127.0.0.1:59421). This Host half
 * exists for one thing only: making the macOS menu-bar companion installable
 * from the Settings page, without asking the user for Xcode command line tools.
 *
 * It registers two local routes on the Harness web server:
 *
 *   GET  /dsh-status-box/status   -> { installed, running, port }
 *   POST /dsh-status-box/install  -> copies the bundled universal binary into
 *                                    ~/Library/Application Support/DSHStatusBox,
 *                                    writes the LaunchAgent and bootstraps it.
 *
 * The bundled binary lives at menubar/bin/dshstatusbox (arm64 + x86_64).
 */

import { spawn } from 'node:child_process'
import { chmod, copyFile, mkdir, readFile, stat, writeFile } from 'node:fs/promises'
import { homedir } from 'node:os'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const PACKAGE_DIR = dirname(fileURLToPath(import.meta.url))
const APP_DIR_NAME = 'DSHStatusBox'
const APP_NAME = 'DSHStatusBox.app'
const LAUNCH_AGENT = 'com.dsh.statusbox.menubar'
const BRIDGE_PORT = 59421
const ROUTE_PREFIX = '/dsh-status-box'

const BUNDLE_ID = 'com.dsh.statusbox.menubar'
const BUNDLE_NAME = '状态盒'

function supportDir() {
  return join(homedir(), 'Library', 'Application Support', APP_DIR_NAME)
}

function appPath() {
  return join(supportDir(), APP_NAME)
}

function executablePath() {
  return join(appPath(), 'Contents', 'MacOS', 'dshstatusbox')
}

function launchAgentPath() {
  return join(homedir(), 'Library', 'LaunchAgents', `${LAUNCH_AGENT}.plist`)
}

const INFO_PLIST = `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
  <key>CFBundleExecutable</key><string>dshstatusbox</string>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>${BUNDLE_NAME}</string>
  <key>CFBundleDisplayName</key><string>${BUNDLE_NAME}</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.2.1</string>
  <key>CFBundleVersion</key><string>1.2.1</string>
  <key>LSMinimumSystemVersion</key><string>11.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
`

function launchAgentPlist() {
  const logDir = supportDir()
  return `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>${LAUNCH_AGENT}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${executablePath()}</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key>
  <dict>
    <key>SuccessfulExit</key><false/>
  </dict>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>ProcessType</key><string>Interactive</string>
  <key>LimitLoadToSessionType</key><string>Aqua</string>
  <key>StandardOutPath</key><string>${join(logDir, 'companion.log')}</string>
  <key>StandardErrorPath</key><string>${join(logDir, 'companion.log')}</string>
</dict>
</plist>
`
}

function run(command, args, options = {}) {
  return new Promise((resolve) => {
    const child = spawn(command, args, { stdio: ['ignore', 'pipe', 'pipe'], ...options })
    let stdout = ''
    let stderr = ''
    child.stdout.on('data', (chunk) => { stdout += String(chunk) })
    child.stderr.on('data', (chunk) => { stderr += String(chunk) })
    child.on('error', (error) => resolve({ code: -1, stdout, stderr: String(error && error.message) }))
    child.on('close', (code) => resolve({ code, stdout, stderr }))
  })
}

async function exists(path) {
  try {
    await stat(path)
    return true
  } catch {
    return false
  }
}

async function pingBridge(timeoutMs = 3000) {
  const controller = new AbortController()
  const timer = setTimeout(() => controller.abort(), timeoutMs)
  try {
    const response = await fetch(`http://127.0.0.1:${BRIDGE_PORT}/ping`, { signal: controller.signal })
    return response.ok
  } catch {
    return false
  } finally {
    clearTimeout(timer)
  }
}

async function waitForBridge(deadlineMs = 6000) {
  const deadline = Date.now() + deadlineMs
  while (Date.now() < deadline) {
    if (await pingBridge(600)) return true
    await new Promise((resolve) => setTimeout(resolve, 250))
  }
  return false
}

async function installCompanion() {
  if (process.platform !== 'darwin') {
    return { ok: false, error: 'macos-only' }
  }

  const binarySource = join(PACKAGE_DIR, 'menubar', 'bin', 'dshstatusbox')
  if (!(await exists(binarySource))) {
    return { ok: false, error: 'bundled-binary-missing' }
  }

  const app = appPath()
  const contents = join(app, 'Contents')
  await mkdir(join(contents, 'MacOS'), { recursive: true })
  await mkdir(join(contents, 'Resources'), { recursive: true })
  await mkdir(join(homedir(), 'Library', 'LaunchAgents'), { recursive: true })
  await mkdir(supportDir(), { recursive: true })

  await copyFile(binarySource, executablePath())
  await chmod(executablePath(), 0o755)

  const whale = join(PACKAGE_DIR, 'menubar', 'whale.png')
  if (await exists(whale)) {
    await copyFile(whale, join(contents, 'Resources', 'whale.png'))
  }

  const plistMarker = join(contents, 'Info.plist')
  const previous = (await exists(plistMarker)) ? await readFile(plistMarker, 'utf8').catch(() => '') : ''
  if (previous !== INFO_PLIST) {
    await writeFile(plistMarker, INFO_PLIST, 'utf8')
  }

  // Ad-hoc signature so Gatekeeper does not kill the helper and the Carbon
  // global hotkey keeps being delivered (macOS only routes hot keys to apps).
  await run('/usr/bin/codesign', ['--force', '--sign', '-', '--deep', app])

  const plist = launchAgentPath()
  if (!(await exists(plist)) || (await readFile(plist, 'utf8').catch(() => '')) !== launchAgentPlist()) {
    await writeFile(plist, launchAgentPlist(), 'utf8')
  }

  const domain = `gui/${process.getuid()}`
  await run('/bin/launchctl', ['bootout', `${domain}/${LAUNCH_AGENT}`])
  // bootout is asynchronous: give launchd a moment before bootstrapping.
  for (let i = 0; i < 40; i += 1) {
    const printed = await run('/bin/launchctl', ['print', `${domain}/${LAUNCH_AGENT}`])
    if (printed.code !== 0) break
    await new Promise((resolve) => setTimeout(resolve, 250))
  }
  let result = await run('/bin/launchctl', ['bootstrap', domain, plist])
  if (result.code !== 0) {
    await new Promise((resolve) => setTimeout(resolve, 800))
    result = await run('/bin/launchctl', ['bootstrap', domain, plist])
  }
  await run('/bin/launchctl', ['kickstart', '-k', `${domain}/${LAUNCH_AGENT}`])

  const running = await waitForBridge()
  return running
    ? { ok: true, installed: true, running: true, port: BRIDGE_PORT, app }
    : { ok: false, error: 'companion-not-responding', installed: true, running: false, port: BRIDGE_PORT, app }
}

/**
 * CORS and method headers for one request. The Harness page fetches these
 * routes same-origin (dsh-app://app is forwarded to this server by the shell),
 * so a missing Origin is fine and only a foreign Origin is refused.
 */
function responseHeaders(origin) {
  const allowed = !origin
    || origin === 'dsh-app://app'
    || /^http:\/\/(127\.0\.0\.1|localhost)(:\d+)?$/.test(origin)
  const headers = {
    'content-type': 'application/json; charset=utf-8',
    'cache-control': 'no-store',
    vary: 'Origin',
    'access-control-allow-methods': 'GET, POST, OPTIONS',
    'access-control-allow-headers': 'Content-Type, X-Dsh-Status-Box, Access-Control-Request-Private-Network',
    'access-control-allow-private-network': 'true',
  }
  if (allowed) headers['access-control-allow-origin'] = origin || '*'
  return { headers, allowed }
}

/** Send one JSON response on the raw node exchange this handler owns. */
function sendJson(req, res, body, status = 200) {
  const { headers, allowed } = responseHeaders(req.headers.origin)
  if (!allowed) {
    res.writeHead(403, headers)
    res.end(JSON.stringify({ ok: false, error: 'origin' }))
    return
  }
  res.writeHead(status, headers)
  res.end(JSON.stringify(body))
}

async function companionState() {
  const installed = await exists(executablePath())
  const running = installed ? await pingBridge(600) : false
  return { ok: true, installed, running, port: BRIDGE_PORT, app: appPath() }
}

async function writeClientProbe(req, url) {
  try {
    await mkdir(supportDir(), { recursive: true })
    await writeFile(
      join(supportDir(), 'client-probe.json'),
      JSON.stringify({
        at: new Date().toISOString(),
        method: req.method,
        url,
        origin: req.headers.origin,
        userAgent: req.headers['user-agent'],
      }, null, 2),
      'utf8'
    )
  } catch {
    // diagnostics only
  }
}

/**
 * Route table entry point. A resource route only ever answers GET/HEAD (the
 * web server replies 405 to everything else before matching), so the prefix is
 * registered as a raw handler that owns the whole exchange and can accept the
 * installer's POST.
 */
async function handle(req, res) {
  const url = new URL(req.url || '/', 'http://127.0.0.1')
  const pathname = url.pathname

  if (req.method === 'OPTIONS') {
    const { headers } = responseHeaders(req.headers.origin)
    res.writeHead(204, headers)
    res.end()
    return
  }

  if (url.searchParams.get('probe') === 'client') {
    await writeClientProbe(req, url.pathname + url.search)
  }

  if (pathname === `${ROUTE_PREFIX}/status` && req.method === 'GET') {
    sendJson(req, res, await companionState())
    return
  }

  if (pathname === `${ROUTE_PREFIX}/install` && req.method === 'POST') {
    // A custom header cannot be forged by a cross-site form post: simple
    // requests cannot set one, and the preflight for it is refused for any
    // foreign origin.
    if (req.headers['x-dsh-status-box'] !== 'install') {
      sendJson(req, res, { ok: false, error: 'forbidden' }, 403)
      return
    }
    try {
      const state = await installCompanion()
      sendJson(req, res, state, state.ok ? 200 : 500)
    } catch (error) {
      sendJson(req, res, { ok: false, error: String((error && error.message) || error) }, 500)
    }
    return
  }

  sendJson(req, res, { ok: false, error: 'not-found' }, 404)
}

async function packageVersion() {
  try {
    const manifest = JSON.parse(await readFile(join(PACKAGE_DIR, 'package.json'), 'utf8'))
    return typeof manifest.version === 'string' ? manifest.version : 'unknown'
  } catch {
    return 'unknown'
  }
}

async function markHostLoaded() {
  try {
    await mkdir(supportDir(), { recursive: true })
    await writeFile(
      join(supportDir(), 'host-loaded.json'),
      JSON.stringify({ at: new Date().toISOString(), pid: process.pid, version: await packageVersion() }),
      'utf8'
    )
  } catch {
    // diagnostics only
  }
}

export function apply(ctx) {
  void markHostLoaded()
  const webServer = ctx.get('webServer')
  if (!webServer) {
    ctx.logger?.warn?.('[dsh-status-box] webServer unavailable: the one-click installer stays disabled')
    return
  }

  // One route per path: GET status and POST install are registered as a single
  // prefix route because the route table keys on (kind, path).
  try {
    const dispose = webServer.register({
      kind: 'prefix',
      path: ROUTE_PREFIX,
      handler: (req, res) => {
        handle(req, res).catch((error) => {
          try {
            if (!res.headersSent) {
              res.writeHead(500, { 'content-type': 'application/json; charset=utf-8' })
            }
            res.end(JSON.stringify({ ok: false, error: String((error && error.message) || error) }))
          } catch {
            // the socket is already gone
          }
        })
      },
    })
    ctx.effect(() => dispose)
  } catch (error) {
    try {
      ctx.logger?.warn?.('[dsh-status-box] could not register the installer route: ' + String((error && error.message) || error))
    } catch {
      // logging is best effort
    }
  }
}
