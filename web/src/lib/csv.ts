// CSV export of exactly what the chart shows: one row per period, one column
// per visible category (legend order), values as displayed (counts, or
// percentages in "% of total" mode). Notes - title, partial periods, source,
// a link back to the view - follow the data after a blank line, so the table
// itself stays clean for spreadsheets and scripts.

import type { PlotData } from '../query/plotData'

export interface CsvOptions {
  /** Category keys to export, in column order (null = the missing-category bucket). */
  columns: (string | null)[]
  /** Display name for each column header. */
  header: (category: string | null) => string
  periodLabel: string
  percent: boolean
  notes: string[]
}

const quote = (v: string) => (/[",\n\r]/.test(v) ? `"${v.replace(/"/g, '""')}"` : v)

export function buildCsv(data: PlotData, o: CsvOptions): string {
  const key = (c: string | null) => c ?? '\u0000NA'
  const cells = new Map<string, number>()
  for (const r of data.rows) {
    const k = `${key(r.category)}␟${r.period}`
    cells.set(k, (cells.get(k) ?? 0) + r.value)
  }
  const fmt = (v: number | undefined) =>
    v === undefined ? '' : o.percent ? v.toFixed(2) : String(Math.round(v * 100) / 100)

  const lines = [[o.periodLabel, ...o.columns.map(o.header)].map(quote).join(',')]
  for (const period of data.periodOrder) {
    lines.push([period, ...o.columns.map((c) => fmt(cells.get(`${key(c)}␟${period}`)))].map(quote).join(','))
  }
  if (o.notes.length) {
    lines.push('')
    for (const n of o.notes) lines.push(quote(n))
  }
  // Byte-order mark so Excel opens the file as UTF-8 (accents, "→").
  return '﻿' + lines.join('\r\n') + '\r\n'
}

export function downloadText(filename: string, text: string, type = 'text/csv;charset=utf-8') {
  const url = URL.createObjectURL(new Blob([text], { type }))
  const a = document.createElement('a')
  a.href = url
  a.download = filename
  document.body.append(a)
  a.click()
  a.remove()
  setTimeout(() => URL.revokeObjectURL(url), 1000)
}

/** "Permanent Residents → All admissions" -> "permanent-residents_all-admissions" (ASCII, filesystem-safe). */
export function slug(parts: string[]): string {
  return parts
    .map((p) => p.normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase().replace(/[^a-z0-9]+/g, '-')
      .replace(/^-|-$/g, ''))
    .filter(Boolean)
    .join('_')
    .slice(0, 120)
}
