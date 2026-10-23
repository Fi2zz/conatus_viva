import { useEffect, useRef, useState } from 'react'
import type { PreviewImage, RefImage } from './imagePicker'

export function PickedImageGrid({
  images,
  max,
  addLabel,
  onAdd,
  onRemove,
  onPreview,
  onDropFiles,
}: {
  images: RefImage[]
  max: number
  addLabel: string
  onAdd: () => void
  onRemove: (index: number) => void
  onPreview: (image: PreviewImage) => void
  onDropFiles: (files: FileList) => void
}) {
  const [dragging, setDragging] = useState(false)
  const dragDepth = useRef(0)

  return (
    <div
      className={dragging ? 'ref-grid dragging' : 'ref-grid'}
      onDragEnter={(e) => {
        e.preventDefault()
        dragDepth.current += 1
        setDragging(true)
      }}
      onDragOver={(e) => e.preventDefault()}
      onDragLeave={() => {
        dragDepth.current -= 1
        if (dragDepth.current <= 0) {
          dragDepth.current = 0
          setDragging(false)
        }
      }}
      onDrop={(e) => {
        e.preventDefault()
        dragDepth.current = 0
        setDragging(false)
        onDropFiles(e.dataTransfer.files)
      }}
    >
      {images.map((image, i) => (
        <div className="ref-tile" key={`${image.name}-${i}`}>
          <button
            type="button"
            className="ref-preview"
            aria-label={`预览 ${image.name}`}
            onClick={() => onPreview({ src: image.dataUrl, name: image.name })}
          >
            <img src={image.dataUrl} alt={image.name} title={image.name} />
          </button>
          <button
            type="button"
            className="ref-remove"
            aria-label={`移除 ${image.name}`}
            onClick={() => onRemove(i)}
          >
            ×
          </button>
        </div>
      ))}
      {images.length < max && (
        <button type="button" className="ref-add" aria-label={addLabel} onClick={onAdd}>
          <span>+</span>
          <small>{addLabel}</small>
        </button>
      )}
    </div>
  )
}

export function ImageLightbox({
  preview,
  onClose,
}: {
  preview: PreviewImage | null
  onClose: () => void
}) {
  useEffect(() => {
    if (!preview) return
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape') onClose()
    }
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  }, [preview, onClose])

  if (!preview) return null
  return (
    <div
      className="ref-lightbox"
      role="dialog"
      aria-modal="true"
      aria-label={`预览 ${preview.name}`}
      onClick={onClose}
    >
      <img src={preview.src} alt={preview.name} onClick={(e) => e.stopPropagation()} />
      <button
        type="button"
        className="ref-lightbox-close"
        aria-label="关闭预览"
        onClick={onClose}
      >
        ×
      </button>
    </div>
  )
}
