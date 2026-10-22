/**
 * Saves a same-origin file without navigating the WebView.
 *
 * The desktop app runs inside a WKWebView, which ignores `<a download>` and
 * simply navigates to the URL — the image/video then fills the window with no
 * way back. Fetching into a blob and clicking a temporary anchor keeps the
 * current page in place.
 */
export async function downloadFile(url: string, filename: string): Promise<void> {
  const res = await fetch(url)
  if (!res.ok) throw new Error(`下载失败（HTTP ${res.status}）`)
  const blob = await res.blob()
  const href = URL.createObjectURL(blob)
  const anchor = document.createElement('a')
  anchor.href = href
  anchor.download = filename
  document.body.appendChild(anchor)
  anchor.click()
  anchor.remove()
  setTimeout(() => URL.revokeObjectURL(href), 1000)
}
