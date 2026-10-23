/**
 * Shared image-picking types and helpers.
 *
 * The Flutter shell (WKWebView) never opens a file input, so the picker
 * components talk to `window.VivaNative` / `window.__vivaPickResult`; in a
 * plain browser they fall back to `<input type="file">`.
 */

/** One image held in the page as a base64 data URL. */
export interface RefImage {
  name: string
  dataUrl: string
}

/** One image chosen in the Flutter shell's NSOpenPanel. */
export interface PickedFile {
  name: string
  mime: string
  base64: string
}

export interface PreviewImage {
  src: string
  name: string
}

export const MAX_REF_BYTES = 10 * 1024 * 1024
export const ACCEPTED_REF_TYPES = ['image/png', 'image/jpeg', 'image/webp']

declare global {
  interface Window {
    /** Injected by the Flutter shell; absent in a plain browser. */
    VivaNative?: { postMessage: (message: string) => void }
    /** Called by the Flutter shell with files chosen in NSOpenPanel. */
    __vivaPickResult?: (files: PickedFile[], error?: string) => void
  }
}

export function readAsDataUrl(file: File): Promise<string> {
  return new Promise((resolve, reject) => {
    const reader = new FileReader()
    reader.onload = () => resolve(String(reader.result))
    reader.onerror = () => reject(reader.error ?? new Error('读取图片失败'))
    reader.readAsDataURL(file)
  })
}

/** Reads browser file picks into the same shape the native panel returns. */
export async function readPickedFiles(files: FileList): Promise<PickedFile[]> {
  const picked: PickedFile[] = []
  for (const file of Array.from(files)) {
    const dataUrl = await readAsDataUrl(file)
    picked.push({
      name: file.name,
      mime: file.type,
      base64: dataUrl.slice(dataUrl.indexOf(',') + 1),
    })
  }
  return picked
}

/** Fails with a message a person can act on, or returns the image. */
export function validatePicked(file: PickedFile): RefImage | string {
  if (!ACCEPTED_REF_TYPES.includes(file.mime)) {
    return `${file.name} 仅支持 PNG / JPEG / WebP`
  }
  if (Math.ceil((file.base64.length * 3) / 4) > MAX_REF_BYTES) {
    return `${file.name} 超过 10MB`
  }
  return {
    name: file.name,
    dataUrl: `data:${file.mime};base64,${file.base64}`,
  }
}
