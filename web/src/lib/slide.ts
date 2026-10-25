// PNG export of the chart as a 16:9 slide (1920 x 1080): title and subtitle
// at the top, the chart (drawn off screen by Chart.svelte's renderImage) in
// the middle, notes and sources below it, and the MigraScope name and URL at
// the foot. Colours and fonts follow the app (styles/tokens.css).

export const SLIDE_W = 1920
export const SLIDE_H = 1080

const PAD_X = 80
const INK = '#14213D'
const INK_2 = '#3A4558'
const INK_3 = '#5A6578'
const CORAL = '#E8506A'
const SERIF = "'Young Serif', Georgia, serif"
const SANS = "'Noto Sans', system-ui, sans-serif"

/** The header's microscope (Lucide, ISC licence), on a 24-unit grid. */
const MICROSCOPE = ['M6 18h8', 'M3 22h18', 'M14 22a7 7 0 1 0 0-14h-1', 'M9 14h2',
  'M9 12a2 2 0 0 1-2-2V6h6v4a2 2 0 0 1-2 2Z', 'M12 6V3a1 1 0 0 0-1-1H9a1 1 0 0 0-1 1v3']

export interface SlideText {
  title: string
  /** e.g. "Annual, 2015–2026 · Percentage of total". */
  subtitle: string
  /** Caption paragraphs under the chart; the first is drawn darker when `leadNote` is set. */
  notes: string[]
  leadNote: boolean
  /** The app's address, shown at the foot. */
  url: string
}

interface Block { lines: string[]; font: string; lineHeight: number; colour: string }

/** Greedy word wrap to `width` px; a single over-long word is left to overflow. */
function wrap(ctx: CanvasRenderingContext2D, text: string, font: string, width: number, maxLines = Infinity): string[] {
  ctx.font = font
  const lines: string[] = []
  let line = ''
  for (const word of text.split(/\s+/).filter(Boolean)) {
    const next = line ? `${line} ${word}` : word
    if (line && ctx.measureText(next).width > width) {
      lines.push(line)
      line = word
    } else line = next
  }
  if (line) lines.push(line)
  if (lines.length > maxLines) {
    const kept = lines.slice(0, maxLines)
    let last = kept[maxLines - 1]
    while (last && ctx.measureText(`${last}…`).width > width) last = last.replace(/\s*\S+$/, '')
    kept[maxLines - 1] = `${last}…`
    return kept
  }
  return lines
}

function drawBlock(ctx: CanvasRenderingContext2D, b: Block, y: number): number {
  ctx.font = b.font
  ctx.fillStyle = b.colour
  for (const line of b.lines) {
    ctx.fillText(line, PAD_X, y)
    y += b.lineHeight
  }
  return y
}

const loadImage = (src: string) => new Promise<HTMLImageElement>((resolve, reject) => {
  const img = new Image()
  img.onload = () => resolve(img)
  img.onerror = () => reject(new Error('Could not draw the chart image'))
  img.src = src
})

/**
 * Lays out the slide, asks `renderChart` for a chart image of the space left
 * between the header and the caption, and returns the finished PNG.
 */
export async function renderSlide(text: SlideText,
                                  renderChart: (width: number, height: number) => Promise<string>): Promise<Blob> {
  await Promise.all([document.fonts.load(`44px ${SERIF}`), document.fonts.load(`20px ${SANS}`),
    document.fonts.load(`600 20px ${SANS}`)])
  const canvas = document.createElement('canvas')
  canvas.width = SLIDE_W
  canvas.height = SLIDE_H
  const ctx = canvas.getContext('2d')!
  ctx.textBaseline = 'top'
  const width = SLIDE_W - 2 * PAD_X

  const title: Block = { lines: wrap(ctx, text.title, `44px ${SERIF}`, width, 2), font: `44px ${SERIF}`, lineHeight: 54, colour: INK }
  const subtitle: Block = { lines: [text.subtitle], font: `24px ${SANS}`, lineHeight: 32, colour: INK_2 }
  const notes: Block[] = text.notes.map((n, i) => {
    const font = i === 0 && text.leadNote ? `600 17px ${SANS}` : `17px ${SANS}`
    return { lines: wrap(ctx, n, font, width), font, lineHeight: 23, colour: i === 0 && text.leadNote ? INK : INK_3 }
  })
  const height = (b: Block) => b.lines.length * b.lineHeight

  const top = 64
  const footer = 40 // the MigraScope line
  const bottom = 44
  const chartTop = top + height(title) + 6 + height(subtitle) + 28
  const notesHeight = notes.reduce((a, b) => a + height(b) + 6, 0)
  const chartBottom = SLIDE_H - bottom - footer - 20 - notesHeight - 24
  const chart = await loadImage(await renderChart(width, chartBottom - chartTop))

  ctx.fillStyle = '#FFFFFF'
  ctx.fillRect(0, 0, SLIDE_W, SLIDE_H)
  ctx.fillStyle = CORAL
  ctx.fillRect(0, 0, SLIDE_W, 12)

  let y = drawBlock(ctx, title, top)
  drawBlock(ctx, subtitle, y + 6)
  ctx.drawImage(chart, PAD_X, chartTop, width, chartBottom - chartTop)

  y = chartBottom + 24
  for (const b of notes) y = drawBlock(ctx, b, y) + 6

  // Foot: a rule, the microscope and logotype in coral, then the address.
  const footY = SLIDE_H - bottom - footer
  ctx.fillStyle = '#E3E7EC'
  ctx.fillRect(PAD_X, footY - 12, width, 1)
  ctx.save()
  ctx.translate(PAD_X, footY + 4)
  ctx.scale(32 / 24, 32 / 24)
  ctx.strokeStyle = CORAL
  ctx.lineWidth = 2
  ctx.lineCap = 'round'
  ctx.lineJoin = 'round'
  for (const d of MICROSCOPE) ctx.stroke(new Path2D(d))
  ctx.restore()
  ctx.font = `30px ${SERIF}`
  ctx.fillStyle = CORAL
  ctx.textBaseline = 'middle'
  const mid = footY + 20
  ctx.fillText('MigraScope', PAD_X + 44, mid)
  const after = PAD_X + 44 + ctx.measureText('MigraScope').width + 18
  ctx.font = `20px ${SANS}`
  ctx.fillStyle = INK_2
  ctx.fillText(text.url, after, mid + 2)

  return new Promise((resolve, reject) =>
    canvas.toBlob((b) => (b ? resolve(b) : reject(new Error('Could not create the PNG'))), 'image/png'))
}
