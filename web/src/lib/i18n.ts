// English/French text, ported from app/R/i18n.R (chrome strings, exported to
// strings.json) and app.R (theme labels, translate_vec(), translate_category).

import type { Meta } from './meta'

export type Lang = 'en' | 'fr'

/** app.R: DATASET_LABELS / DATASET_LABELS_FR, in the Theme picker's order (npr_population is Statistics Canada's). */
export const THEMES: { id: string; en: string; fr: string }[] = [
  { id: 'permanent_residents', en: 'Permanent Residents', fr: 'Résidents permanents' },
  { id: 'temporary_workers_imp', en: 'International Mobility Program', fr: 'Programme de mobilité internationale' },
  { id: 'temporary_workers_tfwp', en: 'Temporary Foreign Worker Program', fr: 'Programme des travailleurs étrangers temporaires' },
  { id: 'study_permit_holders', en: 'Study Permit Holders', fr: "Titulaires d'un permis d'études" },
  { id: 'tr_to_pr_transition', en: 'TR → PR Transition', fr: 'Transition de résident temporaire à résident permanent' },
  { id: 'asylum_claimants', en: 'Asylum Claimants', fr: "Demandeurs d'asile" },
  { id: 'refugees', en: 'Refugees', fr: 'Réfugiés' },
  { id: 'npr_population', en: 'Non-Permanent Resident Population', fr: 'Population de résidents non permanents' },
  { id: 'express_entry', en: 'Express Entry', fr: 'Entrée express' }
]

export function themeLabel(id: string, lang: Lang): string {
  const t = THEMES.find((x) => x.id === id)
  return t ? t[lang] : id
}

export class I18n {
  constructor(private meta: Meta) {}

  /** A chrome string (R: tr()); `%s` placeholders are filled in order. */
  t(key: string, lang: Lang, ...args: string[]): string {
    const s = this.meta.strings.strings[key]
    let text = s ? s[lang] : key
    for (const a of args) text = text.replace('%s', a)
    return text
  }

  /**
   * R: translate_vec() - series/facet names from the hand-maintained list
   * first, then category_translations for the given context, falling back to
   * the English text. Never blank.
   */
  translate(value: string, context: string, lang: Lang): string {
    if (lang === 'en' || !value) return value
    if (context === 'series' || context === 'facet') {
      const hit = this.meta.strings.series_facet_fr[value]
      if (hit) return hit
    }
    return this.meta.translations.get(context)?.get(value) ?? value
  }

  /**
   * app.R's translate_category(): the fixed labels, else try each breakdown
   * context in turn, each one translating whatever the last left in English.
   */
  category(value: string | null, lang: Lang): string {
    if (value === null) return this.t('na_category', lang)
    if (lang === 'en') return value
    const known: Record<string, string> = {
      Other: this.t('other_category', lang),
      'Suppressed Residual': this.t('suppressed_residual', lang),
      NA: this.t('na_category', lang)
    }
    if (value in known) return known[value]
    let out = value
    for (const ctx of ['breakdown_1', 'breakdown_2', 'breakdown_3', 'facet']) out = this.translate(out, ctx, lang)
    return out
  }
}

const formatters = { en: new Intl.NumberFormat('en-CA'), fr: new Intl.NumberFormat('fr-CA') }

/** R: scales::comma / label_number(big.mark = " ", decimal.mark = ",") */
export function formatNumber(n: number, lang: Lang, decimals = 0): string {
  if (decimals === 0) return formatters[lang].format(Math.round(n))
  return new Intl.NumberFormat(lang === 'fr' ? 'fr-CA' : 'en-CA', {
    minimumFractionDigits: decimals, maximumFractionDigits: decimals
  }).format(n)
}

/** "2026-09-12" -> "September 12, 2026" / "12 septembre 2026" (parsed as a local date, no timezone shift). */
export function formatDate(iso: string, lang: Lang): string {
  const [y, m, d] = iso.split('-').map(Number)
  return new Intl.DateTimeFormat(lang === 'fr' ? 'fr-CA' : 'en-CA', { dateStyle: 'long' }).format(new Date(y, m - 1, d ?? 1))
}

/** "2026-06" -> "June 2026" / "juin 2026" */
export function formatMonth(ym: string, lang: Lang): string {
  const [y, m] = ym.split('-').map(Number)
  return new Intl.DateTimeFormat(lang === 'fr' ? 'fr-CA' : 'en-CA', { month: 'long', year: 'numeric' }).format(new Date(y, m - 1, 1))
}

export function formatPercent(n: number, lang: Lang): string {
  return lang === 'fr' ? `${formatNumber(n, lang, 1)} %` : `${formatNumber(n, lang, 1)}%`
}
