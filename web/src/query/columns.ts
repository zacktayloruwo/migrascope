// Decodes one series_facts partition (theme x geo_level Parquet file written
// by data-raw/10_export_web.R) into plain column arrays with hyparquet. The
// partition columns (theme, geo_level) aren't stored in the file; callers
// know them from the manifest. Runs the same in the browser and in Node, so
// the parity tests exercise exactly this code.

import { parquetRead } from 'hyparquet'
import { compressors } from 'hyparquet-compressors'

export interface SeriesFactsColumns {
  length: number
  series: (string | null)[]
  facet: (string | null)[]
  breakdown_1: (string | null)[]
  breakdown_2: (string | null)[]
  breakdown_3: (string | null)[]
  geo_1: (string | null)[]
  geo_2: (string | null)[]
  geo_3: (string | null)[]
  period_year: (number | null)[]
  period_quarter: (number | null)[]
  period_month: (number | null)[]
  value: (number | null)[]
  source_table_id: (string | null)[]
}

const STRING_COLUMNS = ['series', 'facet', 'breakdown_1', 'breakdown_2', 'breakdown_3',
  'geo_1', 'geo_2', 'geo_3', 'source_table_id'] as const
const NUMBER_COLUMNS = ['period_year', 'period_quarter', 'period_month', 'value'] as const
const COLUMNS = [...STRING_COLUMNS, ...NUMBER_COLUMNS]

/** hyparquet yields undefined for some nulls and BigInt for 64-bit ints; normalise both. */
function toNumber(x: unknown): number | null {
  if (x == null) return null
  return typeof x === 'bigint' ? Number(x) : (x as number)
}

export async function decodeSeriesFacts(buffer: ArrayBuffer): Promise<SeriesFactsColumns> {
  const chunks: Record<string, { rowStart: number; data: ArrayLike<unknown> }[]> = {}
  await parquetRead({
    file: buffer,
    columns: COLUMNS,
    compressors,
    onChunk: ({ columnName, columnData, rowStart }) => {
      (chunks[columnName] ??= []).push({ rowStart, data: columnData })
    }
  })

  const assemble = (name: string): unknown[] => {
    const parts = (chunks[name] ?? []).sort((a, b) => a.rowStart - b.rowStart)
    const out: unknown[] = []
    for (const p of parts) for (let i = 0; i < p.data.length; i++) out.push(p.data[i])
    return out
  }

  const cols = {} as Record<string, unknown[]>
  for (const name of STRING_COLUMNS) cols[name] = assemble(name).map((x) => (x == null ? null : String(x)))
  for (const name of NUMBER_COLUMNS) cols[name] = assemble(name).map(toNumber)
  return { length: cols.series.length, ...cols } as unknown as SeriesFactsColumns
}
