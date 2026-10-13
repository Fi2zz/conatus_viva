// Fails the build if the UI relies on native JS dialogs.
//
// The app runs inside a WKWebView (webview_flutter) that does not surface
// window.confirm/alert/prompt: confirm() silently returns false and alert()
// is dropped, so a dialog-gated flow appears to do nothing. Use in-page UI.
import { readdirSync, readFileSync, statSync } from 'node:fs'
import { join } from 'node:path'

const SRC = new URL('../src', import.meta.url).pathname
const PATTERN = /\bwindow\.(confirm|alert|prompt)\s*\(/

function walk(dir) {
  const out = []
  for (const name of readdirSync(dir)) {
    const p = join(dir, name)
    if (statSync(p).isDirectory()) out.push(...walk(p))
    else if (/\.(ts|tsx)$/.test(p)) out.push(p)
  }
  return out
}

let failed = false
for (const file of walk(SRC)) {
  const lines = readFileSync(file, 'utf8').split('\n')
  lines.forEach((line, i) => {
    if (PATTERN.test(line)) {
      failed = true
      console.error(
        `${file}:${i + 1}: native JS dialog is not supported in the app WebView: ${line.trim()}`,
      )
    }
  })
}

if (failed) {
  console.error('\nUse in-page UI instead of window.confirm/alert/prompt.')
  process.exit(1)
}
console.log('ok: no native JS dialogs in frontend/src')
