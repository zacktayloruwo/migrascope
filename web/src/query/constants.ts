// Constants shared with the R implementation (app/R/app_utils.R). Keep these
// in step with their R originals - the parity tests catch drift in behaviour,
// not in display-only constants.

/** Separator between geo_1..geo_k ancestors in a Geographic unit value (R: GEO_UNIT_SEP). */
export const GEO_UNIT_SEP = '␟'

/** R: PROVINCE_ABBR - suffixes CD/CSD place names, which recur across provinces. */
export const PROVINCE_ABBR: Record<string, string> = {
  'British Columbia': 'BC', Alberta: 'AB', Saskatchewan: 'SK', Manitoba: 'MB', Ontario: 'ON',
  Quebec: 'QC', 'New Brunswick': 'NB', 'Prince Edward Island': 'PE', 'Nova Scotia': 'NS',
  'Newfoundland and Labrador': 'NL', Yukon: 'YT', 'Northwest Territories': 'NT', Nunavut: 'NU'
}

/** R: PROVINCE_ORDER_WEST_TO_EAST - Province/Territory picker order. */
export const PROVINCE_ORDER_WEST_TO_EAST = [
  'British Columbia', 'Yukon', 'Alberta', 'Northwest Territories', 'Saskatchewan', 'Manitoba',
  'Nunavut', 'Ontario', 'Quebec', 'New Brunswick', 'Prince Edward Island', 'Nova Scotia',
  'Newfoundland and Labrador'
]

/** Category labels with fixed meaning (and fixed position in the stack). */
export const OTHER = 'Other'
export const SUPPRESSED_RESIDUAL = 'Suppressed Residual'
/** A literal "NA" label some source tables use; distinct from a missing (null) category. */
export const NA_LABEL = 'NA'

/** R: ORDINAL_COHORT_REGEX - a label naming an ordinal bucket starts with a number. */
export const ORDINAL_COHORT_REGEX = /^\s*(\d+)/
