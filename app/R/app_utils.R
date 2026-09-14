# Query + aggregation helpers for app.R. Kept separate from the app file so
# the aggregation logic (in particular the stock-vs-flow handling) can be
# reasoned about and tested independently of Shiny reactivity.

#' Canonical west-to-east ordering for Canada's provinces and territories,
#' used for the legend/stack order when the displayed category is a
#' province/territory breakdown (instead of the usual by-value order).
PROVINCE_ORDER_WEST_TO_EAST <- c(
  "British Columbia", "Yukon", "Alberta", "Northwest Territories",
  "Saskatchewan", "Manitoba", "Nunavut", "Ontario", "Quebec",
  "New Brunswick", "Prince Edward Island", "Nova Scotia",
  "Newfoundland and Labrador"
)

#' Fixed colour used for the residual "Other" category, regardless of
#' which palette is otherwise in use.
OTHER_COLOR <- "#8c8c8c"

#' Fixed colour for a literal "NA" category (missing/unstated dimension
#' value in the source data, distinct from the real "Not stated" category
#' text some tables use) - light grey, lighter than OTHER_COLOR since it
#' represents missingness rather than a deliberate residual bucket.
NA_COLOR <- "#d9d9d9"

#' Standard two-letter postal abbreviations, used to disambiguate Census
#' Division/Subdivision names that recur across provinces (e.g. more than
#' one "Windsor") - see fetch_leaf_rows().
PROVINCE_ABBR <- c(
  "British Columbia" = "BC", "Alberta" = "AB", "Saskatchewan" = "SK",
  "Manitoba" = "MB", "Ontario" = "ON", "Quebec" = "QC",
  "New Brunswick" = "NB", "Prince Edward Island" = "PE",
  "Nova Scotia" = "NS", "Newfoundland and Labrador" = "NL",
  "Yukon" = "YT", "Northwest Territories" = "NT", "Nunavut" = "NU"
)

#' Fixed colour for the "Suppressed Residual" pseudo-category (see
#' build_plot_data()) - black, so it reads as categorically different from
#' every real/"Other"/"NA" category rather than just another palette hue;
#' this segment represents values IRCC/IRB never published at all.
SUPPRESSED_COLOR <- "#000000"

#' Ordered regex -> geographic-rank lookup, most-specific-first (mirrors
#' GENERAL_ABBREV's "(CMA)" before bare "Census Metropolitan Area"
#' ordering below). A level's label rarely matches a concept's canonical
#' spelling exactly - the catalog has 10+ variants of "Province/Territory"
#' alone (slash/no-slash/spaced-slash, "of Intended Destination"/"of
#' Claim" suffixes, the "P/T" abbreviation, ...) - so this is substring/
#' regex matching, not exact lookup. "Census Division" is never a
#' substring of "Census Subdivision" (no space before "Division" in
#' "Subdivision"), so CD and CSD don't need special-casing against each
#' other.
#'
#' The PT pattern also matches bare "Province" with no "Territory"/"P/T"
#' nearby - found via a user report: `rpd_1997_2021`'s level_1 is titled
#' "Province of Residence at the Time of the Refugee Claim Decision" (real
#' data: Ontario, Alberta, Yukon, ... - a genuine PT column), but never says
#' "Territory" or "P/T" anywhere, so the stricter pattern missed it entirely
#' and it fell through to being classified as an ordinary Break down by
#' facet instead of real geography - drilling into "Alberta" as if it were a
#' breakdown *value* rather than picking Alberta via the Geographic unit
#' selector like every other province-level series. Confirmed safe to
#' broaden: across every level label in this catalog, this is the only one
#' that contains "province" without also containing "territory" or "P/T",
#' so no other label's classification changes.
GEO_RANK_PATTERNS <- c(
  "Census Subdivision" = "CSD",
  "Census Division" = "CD",
  "Census Metropolitan Area|\\bCMA\\b" = "CMA",
  "Province\\s*/?\\s*Territory|\\bP/T\\b|\\bProvince\\b" = "PT"
)

#' Vectorized: which geographic rank (if any) a level_N_label describes.
#' NA for non-geographic labels (Gender, Immigration Category, ...) and for
#' generic filler labels (see FILLER_LEVEL_REGEX) - those never contain any
#' of the patterns above.
classify_geo_rank <- function(label) {
  rank <- rep(NA_character_, length(label))
  for (i in seq_along(GEO_RANK_PATTERNS)) {
    hit <- is.na(rank) & grepl(names(GEO_RANK_PATTERNS)[i], label, ignore.case = TRUE, perl = TRUE)
    rank[hit] <- GEO_RANK_PATTERNS[i]
  }
  rank
}

#' guess_level_labels()'s (R/duckdb_utils.R) own positional fallback text,
#' used whenever a table's title doesn't name enough dimensions to cover
#' every level_N it actually has. Ambiguous by construction: it's what a
#' truly meaningless padding column looks like (no title text left to
#' describe it because there's nothing real there), but it's *also* what a
#' real, deeply-nested dimension looks like when the title names it once but
#' the data nests it several levels deeper than that (see
#' reports/database_coverage_report.qmd #2.4, e.g. a "Program" hierarchy 4
#' levels deep, titled only "... and Program"). Because the label text can't
#' tell those two cases apart, `table_shape()`'s facet detection
#' (data-raw/08_build_series_facts.R) checks the real column content before
#' trusting a position matching only this pattern as filler - see
#' level_has_real_data() below. Deliberately narrower than FILLER_LEVEL_REGEX
#' (excludes "... Rank" - see that constant) precisely so that
#' content-based override never applies to a column that's filler for a
#' reason *other* than "no title text left", where being non-empty doesn't
#' make it a real category.
GENERIC_FALLBACK_LABEL_REGEX <- "^(Category|Program) Level \\d+$"

#' Generic, semantically-empty level labels, excluded entirely from the
#' "Break down by" selector - picking one would produce a real data split
#' with no way to explain what it actually represents. Two different kinds:
#' GENERIC_FALLBACK_LABEL_REGEX (see above - ambiguous, content can override
#' it) and "... Rank", a purely ordinal position column some source tables
#' publish alongside a genuine breakdown (IRCC's "Top 25 Countries of
#' Citizenship" family: level_2 is a literal 1-25 rank number, not a category
#' in its own right - the real breakdown, Country of Citizenship, is one
#' level deeper). Unlike the generic-fallback case, a rank column is always
#' filler regardless of how much real (numeric) data it holds - the numbers
#' are real, but they're a position, not a category - so it's never subject
#' to the content-based override table_shape() applies to
#' GENERIC_FALLBACK_LABEL_REGEX matches.
FILLER_LEVEL_REGEX <- paste0(GENERIC_FALLBACK_LABEL_REGEX, "|\\bRank$")

#' Classify a table's level_N_label vector (in level order, NAs already
#' dropped by the caller) for the Geographic Aggregation / Break down by
#' selectors: for each label, is it geographic (and at what rank), or a
#' meaningless filler, or a real non-geographic category. Returns a
#' data.frame aligned by position with the input.
classify_level <- function(label) {
  data.frame(
    label = label,
    geo_rank = classify_geo_rank(label),
    is_filler = grepl(FILLER_LEVEL_REGEX, label, ignore.case = TRUE),
    stringsAsFactors = FALSE
  )
}

#' Separator joining a Geographic unit's ancestor prefix values into one
#' selectize option value (see list_geo_units()/parse_geo_unit()) - the
#' Unicode "unit separator" control character, chosen because it will never
#' appear in a real place name.
GEO_UNIT_SEP <- "␟"

#' Split a Geographic unit selectize value back into its ancestor-prefix
#' values (see list_series_geo_units() in the series_facts query layer
#' below). "All"/NULL/empty means no unit filter is in effect.
parse_geo_unit <- function(geo_unit) {
  if (is.null(geo_unit) || identical(geo_unit, "All") || !nzchar(geo_unit)) {
    character(0)
  } else {
    strsplit(geo_unit, GEO_UNIT_SEP, fixed = TRUE)[[1]]
  }
}

#' True leaf rows for one table: rows with no deeper *child* row sharing
#' their exact level_1..level_k prefix - not simply `row_level == n_levels`
#' (what fetch_leaf_rows() used to filter on directly). Some pivot tables
#' are ragged: one branch of the hierarchy is broken down further than
#' others (e.g. IMP "Agreements" permits get a further FTA-type split
#' that "Canadian Interests"/"Vulnerable workers" permits never do), so
#' the *deepest available* row for a branch can sit at a row_level well
#' short of the table's overall n_levels. Naively requiring
#' `row_level == n_levels` silently drops every such shallower branch
#' entirely - this was discovered via a Suppressed Residual close to 100%
#' of the published total: the "missing" data wasn't suppressed at all,
#' it was sitting at a row_level the query never looked at.
#'
#' Built bottom-up: row_level == n_levels rows are always leaves (no
#' deeper level exists); for each shallower row_level k (from n_levels-1
#' down to 1), a real (non-grand-total - level_1 is never NA for a
#' genuine group's own subtotal) subtotal row is promoted to a leaf only
#' if no row at row_level == k+1 shares its exact level_1..level_k
#' prefix. Excluding the grand-total row (level_1 IS NA) from promotion
#' matters: its own "children" are the level_1 subtotals via a NULL-vs-
#' NULL comparison SQL never treats as a match, which would otherwise
#' promote the entire-table grand total into the leaf set and massively
#' double-count everything.
#'
#' `n_levels` (from `catalog`) is a table's true nominal nesting depth and
#' can exceed `MAX_LEVELS_IN_FACTS` - `facts` itself only ever stores
#' level_1..level_5 (data-raw/R/duckdb_utils.R's own MAX_LEVELS, padding
#' shallower tables and truncating deeper ones to that width so every
#' table shares one column set). A row nested past that depth still has a
#' real row_level (row_level isn't truncated, only the level_N text
#' columns are) but no level_6+ text to tell it apart from a same-prefix
#' intermediate subtotal - so instead of the exact `row_level == n_levels`
#' match that works for every ordinarily-shaped table, anything at or past
#' the physical cap is treated as a leaf outright. Capping `n_levels`
#' itself first also keeps the loop below from requesting a level_N
#' column that was never kept for such a table.
MAX_LEVELS_IN_FACTS <- 5

true_leaf_rows <- function(con, table_id, n_levels) {
  n_levels <- min(n_levels, MAX_LEVELS_IN_FACTS)
  base <- dplyr::tbl(con, "facts") |> dplyr::filter(.data$table_id == !!table_id)
  leaves <- base |> dplyr::filter(.data$row_level >= !!n_levels)

  if (n_levels > 1) {
    for (k in seq(n_levels - 1, 1)) {
      level_cols <- paste0("level_", seq_len(k))
      rows_k <- base |>
        dplyr::filter(.data$row_level == !!k, !is.na(.data[[level_cols[1]]]))
      children_prefixes <- base |>
        dplyr::filter(.data$row_level == !!(k + 1)) |>
        dplyr::select(dplyr::all_of(level_cols)) |>
        dplyr::distinct()
      uncovered <- rows_k |> dplyr::anti_join(children_prefixes, by = level_cols)
      leaves <- dplyr::union_all(leaves, uncovered)
    }
  }
  leaves
}

#' Cap on how many nested breakdown levels `series_facts` keeps per facet
#' (`breakdown_1`, `breakdown_2`, `breakdown_3`) - matches every nested
#' example found in this catalog so far (the deepest, the French-Speaking
#' PR Immigration Category family, nests 3 deep). A table with more real
#' levels than this past its own geography has the extra depth folded into
#' `breakdown_3` (summed away), not dropped silently -
#' data-raw/08_build_series_facts.R logs when that happens.
MAX_BREAKDOWN_LEVELS <- 3

#' One table's own published subtotal rows at a specific geographic depth -
#' EVERY entity at that depth, not just one (generalizes
#' fetch_published_total()'s single-prefix lookup for use in
#' data-raw/08_build_series_facts.R, which combines sibling tables' totals
#' across an entire geographic level rather than one specific place).
#' `geo_level_idx` 0 means the grand total (the row where `level_1` is
#' `NA`); k >= 1 means the subtotal row at that many leading geo levels
#' (`level_1..level_k`), returned as `geo_1..geo_k`. Kept at the finest
#' period grain available (month if `has_month`, else year) - granularity
#' rollup (and, for stock tables, "latest month in period") happens later,
#' the same way it already does for any other entity-grouped series (see
#' aggregate_series()).
#'
#' A geo rank's own row is only ever marked `is_row_subtotal` when
#' something narrower is nested beneath it *within this same table* (a
#' province row is a subtotal because CD/CSD sit under it; a CD row is a
#' subtotal only when this table also goes on to CSD). CMA and CSD never
#' have a finer census geography nested under them, so whenever one of
#' them is a table's own deepest published level, its rows are ordinary
#' leaf facts (`is_row_subtotal == FALSE`), not subtotals of anything -
#' the `has_deeper` branch below reads those leaf rows directly as this
#' level's own totals instead. Only taken when nothing at all sits deeper
#' for this table (checked directly, not inferred from the geo rank
#' itself), so a level that's merely missing its subtotal rows for some
#' other, genuine data reason isn't silently reinterpreted this way.
table_geo_subtotals <- function(con, table_id, geo_level_idx, has_month) {
  period_type_filter <- if (isTRUE(has_month)) "month" else "year"
  row_level_needed <- max(geo_level_idx, 1)
  geo_cols <- if (geo_level_idx >= 1) paste0("level_", seq_len(geo_level_idx)) else character(0)

  base <- dplyr::tbl(con, "facts") |>
    dplyr::filter(
      .data$table_id == !!table_id,
      .data$row_level == !!row_level_needed,
      .data$period_type == !!period_type_filter
    )
  # row_level == geo_level_idx also matches the grand-total row itself
  # (level_1 IS NA, always sits at row_level 1) whenever geo_level_idx is
  # 1 - excluded here, not just for the geo_level_idx == 0 grand-total
  # case, or it would double up as an extra bogus "place" alongside every
  # real province/CMA/etc. subtotal
  base <- if (geo_level_idx == 0) {
    base |> dplyr::filter(.data$is_row_subtotal == TRUE, is.na(.data$level_1))
  } else {
    base <- base |> dplyr::filter(!is.na(.data$level_1))
    subtotal_rows <- base |> dplyr::filter(.data$is_row_subtotal == TRUE)
    n_subtotal <- subtotal_rows |> dplyr::count() |> dplyr::pull(.data$n)
    if (n_subtotal > 0) {
      subtotal_rows
    } else {
      has_deeper <- dplyr::tbl(con, "facts") |>
        dplyr::filter(.data$table_id == !!table_id, .data$row_level > !!row_level_needed) |>
        dplyr::count() |> dplyr::pull(.data$n) > 0
      if (has_deeper) subtotal_rows else base |> dplyr::filter(.data$is_row_subtotal == FALSE)
    }
  }

  d <- base |>
    dplyr::select(dplyr::all_of(geo_cols), "period_year", "period_quarter", "period_month", "value") |>
    dplyr::collect()
  if (geo_level_idx >= 1) names(d)[seq_along(geo_cols)] <- paste0("geo_", seq_along(geo_cols))
  d
}

#' Whether a level_N column genuinely carries real category data, as opposed
#' to being an empty structural placeholder - used to override a generic
#' ("Category Level N"/"Program Level N") title-derived label's filler
#' classification (FILLER_LEVEL_REGEX) when the column it labels isn't
#' actually empty. Found via reports/database_coverage_report.qmd (#2.4):
#' guess_level_labels() (R/duckdb_utils.R) falls back to that same generic
#' text whenever a table's title names a dimension once but the source data
#' nests it deeper than the title says (e.g. a "Program" hierarchy 4 levels
#' deep, titled only "... and Program") - indistinguishable from true filler
#' by label text alone, but not by content: true filler columns are always
#' entirely NA (padding past a table's real depth), while an under-named
#' real level has real, populated values. `>= 1` distinct non-blank value is
#' enough - even a single real category is more informative than treating
#' the level as nonexistent.
level_has_real_data <- function(con, table_id, level_col) {
  n <- dplyr::tbl(con, "facts") |>
    dplyr::filter(.data$table_id == !!table_id, !is.na(.data[[level_col]]), .data[[level_col]] != "") |>
    dplyr::distinct(.data[[level_col]]) |>
    dplyr::count() |>
    dplyr::pull(.data$n)
  length(n) > 0 && n[1] >= 1
}

#' Which of a table's `classify_level()` rows are truly filler (not real
#' breakdown facets) - a label-only `cl$is_filler` isn't enough for a
#' *generic-fallback* label (GENERIC_FALLBACK_LABEL_REGEX): that same text
#' also appears whenever a table's title under-names how deep its row
#' hierarchy actually nests (e.g. temporary_workers/520ac8e1 - see
#' GENERIC_FALLBACK_LABEL_REGEX's own comment), so it's re-checked against
#' real data (level_has_real_data()) before being trusted as filler. Kept
#' as one function so this decision can't drift apart between
#' data-raw/06_build_label_lookups.R (which decides which levels get an
#' editable row in label_overrides.xlsx) and data-raw/08_build_series_facts.R
#' (which decides which levels become a real, mergeable facet) - those two
#' must agree, or a level content-overridden into a real facet by 08 has no
#' way to ever get a human-readable label from 06's spreadsheet, and two
#' tables' same real-world dimension can end up under two different
#' generic-fallback label strings ("Program" vs "Program Level 2") that 08's
#' exact-string facet grouping then never recognizes as siblings to merge.
really_filler_levels <- function(cl, con, table_id) {
  is_generic_fallback <- grepl(GENERIC_FALLBACK_LABEL_REGEX, cl$label, ignore.case = TRUE)
  cl$is_filler & !(is_generic_fallback & vapply(seq_len(nrow(cl)), function(i) {
    if (!is_generic_fallback[i]) return(FALSE)
    level_has_real_data(con, table_id, paste0("level_", cl$level_index[i]))
  }, logical(1)))
}

#' One table's own true leaf rows (see true_leaf_rows()), reshaped into
#' `series_facts`'s two-part column scheme: `geo_1..geo_{length(geo_positions)}`
#' for whatever geographic levels this table has (possibly none), and
#' `breakdown_1..breakdown_k` (k capped at MAX_BREAKDOWN_LEVELS) for the
#' rest - this table's own real (non-geo, non-filler) dimension level(s),
#' positionally, whether that's a genuine parent/child hierarchy
#' (Immigration Category -> sub-program) or two independently-published
#' dimensions the source nonetheless nests as subtotal rows (e.g. Country of
#' Citizenship with an Immigration Category drill-down) - see
#' data-raw/08_build_series_facts.R for why both are treated the same way
#' here. `geo_positions`/`facet_positions` (from table_shape() there) are
#' explicit level_N *positions*, not just leading counts, because a filler
#' column (see FILLER_LEVEL_REGEX - e.g. a literal "Country Rank" ordinal)
#' can sit between a table's geography and its real facet and must be
#' dropped entirely rather than folded into either. Levels past
#' MAX_BREAKDOWN_LEVELS are summed away into `breakdown_3` rather than
#' silently dropped.
table_facet_leaf_rows <- function(con, table_id, n_levels, geo_positions, facet_positions, has_month) {
  period_type_filter <- if (isTRUE(has_month)) "month" else "year"
  # paste0() recycles a zero-length argument as "" instead of returning
  # character(0) when the other argument is non-empty (here, the constant
  # "level_" prefix) - explicit length checks avoid a bogus single "level_"
  # column name when a table has no geo levels (geo_positions empty) or,
  # in principle, no facet levels at all.
  geo_cols <- if (length(geo_positions) > 0) paste0("level_", geo_positions) else character(0)
  n_breakdown <- length(facet_positions)
  breakdown_src_cols <- if (n_breakdown > 0) paste0("level_", facet_positions) else character(0)

  d <- true_leaf_rows(con, table_id, n_levels) |>
    dplyr::filter(.data$period_type == !!period_type_filter) |>
    dplyr::select(dplyr::all_of(c(geo_cols, breakdown_src_cols)), "period_year", "period_quarter",
                   "period_month", "value") |>
    dplyr::collect()

  if (length(geo_cols) >= 1) names(d)[seq_along(geo_cols)] <- paste0("geo_", seq_along(geo_cols))

  n_keep <- min(n_breakdown, MAX_BREAKDOWN_LEVELS)
  for (i in seq_len(n_keep)) {
    names(d)[names(d) == breakdown_src_cols[i]] <- paste0("breakdown_", i)
  }
  if (n_breakdown > MAX_BREAKDOWN_LEVELS) {
    # fold every level past the cap into the deepest kept column by
    # dropping the extra source columns and summing over them
    extra_cols <- breakdown_src_cols[(MAX_BREAKDOWN_LEVELS + 1):n_breakdown]
    d <- d |>
      dplyr::select(-dplyr::all_of(extra_cols)) |>
      dplyr::group_by(dplyr::across(dplyr::any_of(c(paste0("geo_", seq_along(geo_cols)),
                                                      paste0("breakdown_", seq_len(MAX_BREAKDOWN_LEVELS)),
                                                      "period_year", "period_quarter", "period_month")))) |>
      dplyr::summarise(value = sum(.data$value, na.rm = TRUE), .groups = "drop")
  }
  for (i in seq_len(MAX_BREAKDOWN_LEVELS)) {
    col <- paste0("breakdown_", i)
    if (!col %in% names(d)) d[[col]] <- NA_character_
  }
  for (i in seq_len(3)) {
    col <- paste0("geo_", i)
    if (!col %in% names(d)) d[[col]] <- NA_character_
  }

  # A source table's own branch can terminate before the table's nominal
  # depth without an explicit narrower row (see true_leaf_rows()'s "ragged
  # hierarchy" comment) - but some IRCC pivot tables instead pad every
  # branch to one uniform depth, rather than leaving a shallower branch's
  # row genuinely shorter. That padding isn't always a literal repeat of
  # the parent text - it can just as well be table-specific placeholder
  # text ("Unknown", "Program not stated", ...) that differs level to
  # level but still conveys nothing, since it's the ONLY value that branch
  # ever takes. Left alone, that reads as a real, distinct breakdown_2/3
  # value - which especially matters when facet-merging siblings across
  # tables (data-raw/08_build_series_facts.R): a sibling table whose own
  # hierarchy doesn't pad this deep has breakdown_2/3 = NA for the exact
  # same real category, so the two tables' otherwise-identical rows fail
  # to match on the merge key and BOTH survive, double-counting a value
  # that's actually one cell (found via temporary_workers/520ac8e1's
  # "Other IMP Participants" branch, padded down through "Unknown
  # International Mobility Program" -> "Unknown" -> "Program not stated",
  # doubling that category once merged with temporary_workers/d5779439's
  # shallower sibling row, which stops at "Other IMP Participants" alone).
  #
  # Detected structurally rather than by matching specific placeholder
  # text (different tables pad differently): for each breakdown level,
  # from deepest to shallowest, collapse it to NA wherever it never takes
  # more than one distinct value for its exact parent-category combination
  # anywhere in this table - such a "split" never actually splits anything,
  # regardless of what text fills it. A level that genuinely varies for a
  # branch elsewhere in the table (even if only one value shows up for a
  # specific geo/period slice) is left alone.
  for (i in MAX_BREAKDOWN_LEVELS:2) {
    parent_cols <- paste0("breakdown_", seq_len(i - 1))
    col <- paste0("breakdown_", i)
    n_children <- d |>
      dplyr::filter(!is.na(.data[[col]])) |>
      dplyr::distinct(dplyr::across(dplyr::all_of(c(parent_cols, col)))) |>
      dplyr::count(dplyr::across(dplyr::all_of(parent_cols)), name = "n")
    single_child <- n_children[n_children$n == 1, parent_cols, drop = FALSE]
    if (nrow(single_child) == 0) next
    branch_key <- function(x) do.call(paste, c(x[parent_cols], sep = "␟"))
    is_pad <- !is.na(d[[col]]) & branch_key(d) %in% branch_key(single_child)
    if (any(is_pad)) {
      for (j in i:MAX_BREAKDOWN_LEVELS) d[[paste0("breakdown_", j)]][is_pad] <- NA_character_
    }
  }
  d
}

#' Roll the finest-grain leaf rows up to the requested granularity.
#'
#' Flow tables (permits that "became effective") are summed directly by
#' category. Stock tables (e.g. "with a valid permit" snapshots) aren't
#' additive across months - see R/validate_utils.R::reclassify_stock_tables()
#' and the data quality report for how this was discovered - so instead,
#' for each *true leaf entity* (not the coarser display category) the
#' latest available month within the target quarter/year is taken first,
#' and only then summed up to the display category. Resolving "latest
#' month" directly on the category would keep just one entity per category
#' and silently discard the rest.
aggregate_series <- function(raw, granularity, is_stock) {
  if (nrow(raw) == 0) return(raw)

  if (granularity == "Monthly") {
    out <- raw |>
      dplyr::group_by(.data$category, .data$period_year, .data$period_month) |>
      dplyr::summarise(value = sum(.data$value, na.rm = TRUE), .groups = "drop") |>
      dplyr::mutate(
        # same NA-safety as the Quarterly branch below - a year with no
        # monthly data at all (only an annual figure) still needs to sort
        # and display sensibly on this axis
        period_display = dplyr::if_else(is.na(.data$period_month), as.character(.data$period_year),
                                          sprintf("%d-%02d", .data$period_year, .data$period_month)),
        period_sort = .data$period_year * 100 + dplyr::coalesce(.data$period_month, 0L)
      )
  } else if (granularity == "Quarterly" && "period_quarter" %in% names(raw) && !all(is.na(raw$period_quarter))) {
    if (isTRUE(is_stock)) {
      out <- raw |>
        dplyr::group_by(.data$entity_id, .data$category, .data$period_year, .data$period_quarter) |>
        dplyr::slice_max(.data$period_month, n = 1, with_ties = FALSE) |>
        dplyr::ungroup() |>
        dplyr::group_by(.data$category, .data$period_year, .data$period_quarter) |>
        dplyr::summarise(value = sum(.data$value, na.rm = TRUE), .groups = "drop")
    } else {
      out <- raw |>
        dplyr::group_by(.data$category, .data$period_year, .data$period_quarter) |>
        dplyr::summarise(value = sum(.data$value, na.rm = TRUE), .groups = "drop")
    }
    out <- out |>
      dplyr::mutate(
        # a year with no real quarterly breakdown at all (only an annual
        # figure is published for it) still needs to appear on this same
        # axis in chronological order - "2000 QNA" reads as if annual and
        # quarterly data got jumbled together, and an NA period_quarter
        # would otherwise sort after every real quarter regardless of
        # year (dplyr::arrange() puts NA last), scrambling the whole
        # pre-2015 range to the end of the x-axis
        period_display = dplyr::if_else(is.na(.data$period_quarter), as.character(.data$period_year),
                                          sprintf("%d Q%d", .data$period_year, .data$period_quarter)),
        period_sort = .data$period_year * 10 + dplyr::coalesce(.data$period_quarter, 0L)
      )
  } else { # Annual
    if (isTRUE(is_stock)) {
      out <- raw |>
        dplyr::group_by(.data$entity_id, .data$category, .data$period_year) |>
        dplyr::slice_max(.data$period_month, n = 1, with_ties = FALSE) |>
        dplyr::ungroup() |>
        dplyr::group_by(.data$category, .data$period_year) |>
        dplyr::summarise(value = sum(.data$value, na.rm = TRUE), .groups = "drop")
    } else {
      out <- raw |>
        dplyr::group_by(.data$category, .data$period_year) |>
        dplyr::summarise(value = sum(.data$value, na.rm = TRUE), .groups = "drop")
    }
    out <- out |>
      dplyr::mutate(period_display = as.character(.data$period_year), period_sort = .data$period_year)
  }

  out |>
    dplyr::select("category", "period_display", "period_sort", "value") |>
    dplyr::arrange(.data$period_sort)
}

#' Cap the number of distinct categories shown, folding the smallest ones
#' into "Other" so a bar chart with e.g. 200 countries stays readable.
collapse_to_top_n <- function(d, top_n) {
  if (nrow(d) == 0) return(d)
  totals <- d |>
    dplyr::group_by(.data$category) |>
    dplyr::summarise(total = sum(.data$value, na.rm = TRUE), .groups = "drop") |>
    dplyr::arrange(dplyr::desc(.data$total))

  if (nrow(totals) <= top_n) return(d)

  keep <- totals$category[seq_len(top_n)]
  d |>
    dplyr::mutate(category = ifelse(.data$category %in% keep, .data$category, "Other")) |>
    dplyr::group_by(.data$category, .data$period_display, .data$period_sort) |>
    dplyr::summarise(value = sum(.data$value, na.rm = TRUE), .groups = "drop")
}

#' A category label that names an ordinal cohort/bucket range - age groups
#' ("0 to 14 years old", "60 to 74 years of age"), years-since-arrival
#' buckets, etc - starts with a number. Sorting these by size scrambles
#' the bucket order entirely (and sorting as plain text would put "15 to
#' 29" before "0 to 14"). Matched on the LEADING number only, so
#' e.g. "0 to 14 years old" and "60 to 74 years of age" both match.
#' Matches (and captures) the leading number, consuming the rest of the
#' string too - sub() only replaces what the pattern matches, not
#' match-to-end, so extracting just the number via sub(..., "\\1") needs
#' the trailing `.*$` or the replacement leaves the rest of the label
#' stuck onto the captured digits.
ORDINAL_COHORT_REGEX <- "^\\s*(\\d+).*$"

#' Is this set of (non-"Other"/"NA") category labels an ordinal cohort
#' breakdown? A majority match is enough - a stray non-numeric value like
#' "Age not stated" alongside real buckets shouldn't disqualify the whole
#' set from being kept in ordinal order.
is_ordinal_cohort <- function(labels) {
  length(labels) > 0 &&
    sum(grepl(ORDINAL_COHORT_REGEX, labels)) >= max(2, ceiling(length(labels) / 2))
}

#' Determine category display/stack order:
#'  - low-to-high if the categories look like an ordinal cohort/age-group
#'    breakdown (see is_ordinal_cohort()) - sorting these by size would
#'    scramble a sequence readers expect to see in order; any non-
#'    numeric-leading stragglers sort alphabetically after the numeric
#'    ones (so they end up nearest the bottom, closest to "Other"/"NA");
#'  - otherwise by total value, largest at the bottom of the stack,
#'    smallest at the top. ggplot2's default position_stack() puts a
#'    factor's *first* level at the top of the bar and its *last* level
#'    at the bottom, so `cat_totals_desc` (already sorted largest-to-
#'    smallest, see build_series_plot_data() below) is reversed to get
#'    that top-to-bottom = smallest-to-largest layout.
#' "NA" (a literal missing-value category) and "Other" (the residual
#' bucket from collapse_to_top_n()) are never sorted among the "real"
#' categories above - they're always moved to the very end (the very
#' bottom of the stack), in that fixed relative order, regardless of
#' their own size.
order_categories <- function(cat_totals_desc) {
  all_cats <- cat_totals_desc$category
  trailing <- intersect(c("NA", "Other"), all_cats)
  non_other <- all_cats[!all_cats %in% trailing]

  if (is_ordinal_cohort(non_other)) {
    is_numeric <- grepl(ORDINAL_COHORT_REGEX, non_other)
    numeric_part <- non_other[is_numeric]
    numeric_part <- numeric_part[order(as.numeric(sub(ORDINAL_COHORT_REGEX, "\\1", numeric_part, perl = TRUE)))]
    ordered <- c(numeric_part, sort(non_other[!is_numeric]))
  } else {
    # non_other is already sorted largest-to-smallest (from
    # cat_totals_desc); reverse it so the smallest ends up first (top of
    # stack) and the largest ends up last (bottom, just above "Other"/"NA").
    ordered <- rev(non_other)
  }

  c(ordered, trailing)
}

#' Build a name -> colour mapping for a set of ordered category factor
#' levels: "Other" is always OTHER_COLOR, "NA" is always NA_COLOR, and
#' "Suppressed Residual" is always SUPPRESSED_COLOR regardless of
#' position, the rest are drawn from a fixed gradient in level order.
category_colors <- function(levels_in_order) {
  non_other <- setdiff(levels_in_order, c("Other", "Suppressed Residual", "NA"))
  pal <- grDevices::colorRampPalette(
    c("#0b4f6c", "#1d7874", "#679436", "#a5be00", "#e2c044", "#e58606", "#cc503e")
  )(length(non_other))
  colors <- stats::setNames(pal, non_other)
  if ("Other" %in% levels_in_order) colors[["Other"]] <- OTHER_COLOR
  if ("NA" %in% levels_in_order) colors[["NA"]] <- NA_COLOR
  if ("Suppressed Residual" %in% levels_in_order) colors[["Suppressed Residual"]] <- SUPPRESSED_COLOR
  colors[levels_in_order]
}

#' `%||%` isn't loaded from any of app.R's libraries here - a tiny local
#' null-coalesce is simpler than adding a dependency for one operator.
`%||%` <- function(a, b) if (is.null(a)) b else a

#' Decorator suffixes that dress up an otherwise-identical non-geographic
#' category label across different tables of the same theme (found during
#' the per-theme dimension map research - e.g. "Immigration Category — Pr
#' Pt Immcat" vs plain "Immigration Category"). Stripped so the "Break down
#' by" selector can treat both as the same category. Deliberately
#' conservative: this does NOT attempt to merge differently-worded concepts
#' (e.g. "Country of Birth" is never treated as the same thing as "Country
#' of Citizenship") - only known decorative noise is removed.
CATEGORY_LABEL_DECORATORS <- c(
  # trailing "— Pr Pt X"/"— Pr X" (X spanning 1+ words) always runs to the
  # end of the label in every observed case (e.g. "Immigration Category —
  # Pr Pt Immcat", "Immigration Category — Pr Immcat g") - safe to strip
  # from "Pr" onward rather than trying to match the variable word count
  "\\s*[—-]\\s*Pr\\s+.*$" = "",
  "\\s+Main Category\\s*$" = ""
)

#' Normalize a non-geographic category label for cross-table matching
#' within a theme (see build_theme_dimension_map()) - strips
#' CATEGORY_LABEL_DECORATORS, case preserved (matching is done
#' case-insensitively by callers).
normalize_category_label <- function(label) {
  x <- label
  for (i in seq_along(CATEGORY_LABEL_DECORATORS)) {
    x <- gsub(names(CATEGORY_LABEL_DECORATORS)[i], CATEGORY_LABEL_DECORATORS[i], x, ignore.case = TRUE, perl = TRUE)
  }
  trimws(x)
}

#' Derive a short "Series" label distinguishing tables that otherwise share
#' the same theme/geography/category signature (see
#' build_theme_dimension_map()) - drops the breakdown text (now surfaced
#' via separate selectors) and keeps whatever's left - population/program
#' qualifiers ("French-Speaking", "Humanitarian & Compassionate"),
#' precomputed-metric qualifiers ("Percentage of..."), or snapshot
#' qualifiers ("on December 31st") that make it a genuinely different
#' series. Returns "" when nothing distinguishing survives (the common
#' case - most tables need no Series label at all, see `series_needed` in
#' app.R). A human-curated "Series (custom)" column in
#' data/series_names.xlsx (keyed by table_id) overrides this per-table
#' when the automatic result reads awkwardly - see the
#' `series_label_lookup` param of build_theme_dimension_map() below.
derive_series_label <- function(table_title, dataset, level_labels) {
  x <- table_title

  # Strips the leading subject boilerplate ("Canada -"/"Quebec -"/etc) but
  # deliberately keeps population/program qualifiers ("French-Speaking
  # Permanent Residents", "Percentage of...") - they're what makes a
  # Series option distinguishable; only the dimension text now surfaced
  # via Geographic Aggregation/Break down by gets stripped below.
  #
  # Also deliberately does NOT strip a trailing "— Pr Pt X"-style
  # multi-sheet disambiguator - it's frequently the *only* thing
  # distinguishing several same-hash sheets of one source workbook at
  # different drill-down depths (e.g. permanent_residents/d839c522's four
  # sheets - "— Pr Pt Immcat", "— Pr Immcat", "— Pr Immcat g", "— Pr
  # Immcat m" - three of which share an identical geo+category signature
  # and would otherwise all derive the exact same series_label, making
  # them indistinguishable in the Series selector).
  x <- sub("^Open Dataset Request \\d+ (ENG|FRA)\\s*-?\\s*", "", x)
  x <- sub("^Canada\\s*\\(excluding Quebec\\)\\s*[-–]\\s*", "", x)
  x <- sub("^Canada\\s+ex-QC\\s*[-–]\\s*", "", x)
  x <- sub("^Canada\\s*[-–]\\s*", "", x)
  x <- sub("^Quebec\\s*[-–]\\s*", "", x)

  # GENERAL_ABBREV is dataset-independent connector/phrase cleanup (e.g.
  # "and year in which permit(s) became effective" -> "", "on December
  # 31st" -> "(Dec 31)") - safe to run since it doesn't touch population
  # qualifiers, only makes what's left more compact.
  for (i in seq_along(GENERAL_ABBREV)) {
    x <- gsub(names(GENERAL_ABBREV)[i], GENERAL_ABBREV[i], x, ignore.case = TRUE, perl = TRUE)
  }

  # Strip the *normalized* (normalize_category_label(), decorator-free)
  # form of each level label, not the raw form - a raw label like
  # "Immigration Category — Pr Pt Immcat" appears in the title verbatim
  # (title_for_slug() appended that exact decorator when building the
  # title for this sheet), so stripping the raw label would remove the
  # decorator suffix right along with the dimension name - exactly the
  # bit that's needed to tell same-signature sibling sheets apart in the
  # Series selector (see the derive_series_label() doc comment above).
  # Also strip the GENERAL_ABBREV-abbreviated form (e.g. "Province/
  # Territory" -> "P/T"), since the title may already be abbreviated.
  normalized_labels <- vapply(level_labels, normalize_category_label, character(1), USE.NAMES = FALSE)
  abbreviated_labels <- normalized_labels
  for (i in seq_along(GENERAL_ABBREV)) {
    abbreviated_labels <- gsub(names(GENERAL_ABBREV)[i], GENERAL_ABBREV[i], abbreviated_labels,
                                ignore.case = TRUE, perl = TRUE)
  }
  strip_labels <- unique(c(normalized_labels, abbreviated_labels))
  strip_labels <- strip_labels[!is.na(strip_labels) & nzchar(strip_labels)]
  for (lbl in strip_labels) {
    # ignore.case + fixed can't be combined in base R (fixed silently wins,
    # case-sensitively) - escape regex metacharacters instead so this can
    # run case-insensitively via perl=TRUE
    escaped <- gsub("([.\\|()\\[\\]{}^$*+?])", "\\\\\\1", lbl, perl = TRUE)
    x <- gsub(escaped, "", x, ignore.case = TRUE, perl = TRUE)
  }

  x <- sub("^\\s*By\\s+", "", x, ignore.case = TRUE)
  x <- gsub("\\bby\\b", "", x, ignore.case = TRUE, perl = TRUE)
  x <- gsub("\\band\\b", "", x, ignore.case = TRUE, perl = TRUE)
  x <- gsub("[,()]", " ", x)
  x <- gsub("\\s+", " ", x)
  x <- trimws(x)
  x <- sub("\\.$", "", x)
  if (nchar(x) > 0) substr(x, 1, 1) <- toupper(substr(x, 1, 1))

  if (nchar(x) < 3) "" else x
}

#' Separator joining a Breakdown item override's composite
#' `(table_id, "Breakdown item (auto)")` key into one named-vector name (see
#' read_custom_name_lookup()'s `key_col2` and
#' derive_theme_dimension_map()'s breakdown_label_lookup application) - a
#' plain label-only key can't tell two tables' uses of the same raw label
#' apart, which is exactly the "mislabelled in some series but not others"
#' case this pairing fixes. "::" is safe here (table_ids use "/", labels
#' don't use "::").
BREAKDOWN_KEY_SEP <- "::"

#' Read one of the hand-editable "(custom)" name-override columns out of
#' `app/data/label_overrides.xlsx` (see derive_theme_dimension_map()'s
#' series_label_lookup/breakdown_label_lookup params) - `key_col = "table_id"`
#' for Series (custom), or `key_col = "table_id"` + `key_col2 = "Breakdown
#' item (auto)"` for Breakdown item (custom) (composite-keyed so the same
#' raw label can be corrected differently per table - see
#' BREAKDOWN_KEY_SEP). Only non-blank values become overrides; a missing
#' file (e.g. a fresh checkout before the pipeline's been run once) just
#' means no overrides are active, not an error. Used only by
#' data-raw/06_build_label_lookups.R now - overrides are baked into
#' `catalog` at database-creation time (see that script and
#' derive_theme_dimension_map()), so app.R and
#' data-raw/07_build_series_reference.R no longer read this file at all.
read_custom_name_lookup <- function(path, key_col, custom_col, key_col2 = NULL) {
  if (!file.exists(path)) return(character())
  d <- readxl::read_excel(path, sheet = 1)
  custom <- trimws(as.character(d[[custom_col]]))
  keep <- !is.na(custom) & nzchar(custom)
  keys <- if (is.null(key_col2)) d[[key_col]] else paste(d[[key_col]], d[[key_col2]], sep = BREAKDOWN_KEY_SEP)
  stats::setNames(custom[keep], keys[keep])
}

#' Compute a theme dimension map straight from *raw, uncurated* `catalog`
#' data (table_title/level_N_label exactly as data-raw/05_build_duckdb.R
#' wrote them) - i.e. before any hand-typed correction is applied. This is
#' the pipeline-only counterpart to build_theme_dimension_map() below: it
#' always re-derives `series_label`/`categories` from scratch via
#' derive_series_label()/normalize_category_label(), applies
#' `series_label_lookup`/`breakdown_label_lookup` on top, and is used
#' exactly once, by data-raw/06_build_label_lookups.R, to work out what the
#' final baked-in values in `catalog` should be. It never reads back
#' anything `catalog` may already have baked in from a previous 06 run -
#' see that script's header comment for why 05 must run first for a true
#' "auto" baseline.
#'
#' `series_label_lookup` (keyed by table_id) and `breakdown_label_lookup`
#' (keyed by the composite `(table_id, auto label)` - see
#' read_custom_name_lookup()'s `key_col2`/BREAKDOWN_KEY_SEP) are the
#' "(custom)" columns of app/data/label_overrides.xlsx. The composite key
#' for breakdowns matters: it lets the same raw label be corrected
#' differently in different tables, instead of one global rename - a label
#' can read correctly in most tables and be wrong in just one.
#'
#' Returns one row per surviving table_id (genuinely-redundant duplicates
#' are already dropped upstream - see data-raw/05_build_duckdb.R's
#' EXCLUDED_DUPLICATE_TABLE_IDS) with `geo_ranks`, `categories`,
#' `classification` (label/geo_rank/is_filler/level_index/label_normalized),
#' and `series_label` - the same shape build_theme_dimension_map() produces,
#' since 06 uses this shape to work out what to write into `catalog`.
derive_theme_dimension_map <- function(catalog, series_label_lookup = character(),
                                        breakdown_label_lookup = character()) {
  level_label_cols <- c("level_1_label", "level_2_label", "level_3_label", "level_4_label", "level_5_label")

  rows <- lapply(seq_len(nrow(catalog)), function(i) {
    row <- catalog[i, , drop = FALSE]
    labels <- unlist(row[, level_label_cols])
    idx <- which(!is.na(labels))
    cl <- classify_level(unname(labels[idx]))
    cl$level_index <- idx
    cl$label_normalized <- normalize_category_label(cl$label)
    if (length(breakdown_label_lookup) > 0) {
      keys <- paste(row$table_id, cl$label_normalized, sep = BREAKDOWN_KEY_SEP)
      overridden <- unname(breakdown_label_lookup[keys])
      cl$label_normalized <- ifelse(!is.na(overridden) & nzchar(overridden), overridden, cl$label_normalized)
    }

    cat_rows <- cl[is.na(cl$geo_rank) & !cl$is_filler, , drop = FALSE]

    series_label <- unname(series_label_lookup[row$table_id])
    if (is.na(series_label) || !nzchar(trimws(series_label))) {
      series_label <- derive_series_label(row$table_title, row$dataset, unname(labels[idx]))
    }

    data.frame(
      dataset = row$dataset, table_id = row$table_id, table_title = row$table_title,
      n_levels = row$n_levels, has_month = row$has_month, is_stock = row$is_stock,
      min_year = row$min_year, max_year = row$max_year,
      geo_ranks = I(list(unique(stats::na.omit(cl$geo_rank)))),
      categories = I(list(unique(cat_rows$label_normalized))),
      classification = I(list(cl)),
      series_label = series_label,
      stringsAsFactors = FALSE
    )
  })

  do.call(rbind, rows)
}

#' Build the per-table dimension map every Geo/Category/Series selector in
#' app.R is driven from - one row per table_id in `catalog`. Unlike
#' derive_theme_dimension_map() (the pipeline-only function that works out
#' what corrections *should* be), this is the plain app-facing reader: by
#' the time the app sees it, `catalog$level_N_label` and
#' `catalog$series_label` are already final - hand corrections were baked
#' in at database-creation time by data-raw/06_build_label_lookups.R - so
#' this just classifies/groups what's already there. No lookup files, no
#' derive_series_label() fallback. `categories`/`classification` still run
#' normalize_category_label()/classify_level() for their generic
#' decorator-stripping and geo/filler classification (harmless to redo -
#' idempotent on already-clean text), not to correct anything.
#'
#'  - `geo_ranks`: list-column, the set of geographic ranks (CSD/CD/CMA/PT)
#'    this table has (via classify_geo_rank())
#'  - `categories`: list-column, the set of normalized non-geographic,
#'    non-filler category labels this table has
#'  - `classification`: list-column, this table's full classify_level()
#'    output (label/geo_rank/is_filler) with `level_index` attached - the
#'    same shape app.R's old level_classification() reactive used to
#'    compute per-table on every reactive tick; precomputed once here
#'  - `series_label`: straight from `catalog$series_label`
#'
#' Computed once at app startup (like `catalog` itself), not per-session.
build_theme_dimension_map <- function(catalog) {
  level_label_cols <- c("level_1_label", "level_2_label", "level_3_label", "level_4_label", "level_5_label")

  rows <- lapply(seq_len(nrow(catalog)), function(i) {
    row <- catalog[i, , drop = FALSE]
    labels <- unlist(row[, level_label_cols])
    idx <- which(!is.na(labels))
    cl <- classify_level(unname(labels[idx]))
    cl$level_index <- idx
    cl$label_normalized <- normalize_category_label(cl$label)

    cat_rows <- cl[is.na(cl$geo_rank) & !cl$is_filler, , drop = FALSE]

    data.frame(
      dataset = row$dataset, table_id = row$table_id, table_title = row$table_title,
      n_levels = row$n_levels, has_month = row$has_month, is_stock = row$is_stock,
      min_year = row$min_year, max_year = row$max_year,
      geo_ranks = I(list(unique(stats::na.omit(cl$geo_rank)))),
      categories = I(list(unique(cat_rows$label_normalized))),
      classification = I(list(cl)),
      series_label = row$series_label,
      stringsAsFactors = FALSE
    )
  })

  do.call(rbind, rows)
}

#' Note on why series_label is deliberately left un-deduplicated: an
#' earlier version forced every series_label unique per theme, appending a
#' geo_ranks/categories-derived qualifier on collision (e.g. "Permanent
#' Residents (Age Group)" vs "... (Gender)") - reverted because it
#' re-encoded exactly the information the Geographic Aggregation/Break
#' down by selectors already convey (a user who'd already picked "Break
#' down by = Age" then saw "(Age)" baked into the Series name too,
#' redundantly), and a bare numeric fallback ("All admissions (2)") was no
#' better once match_candidates() below started collapsing raw candidates
#' to one row per distinct series_label itself - a uniqueness-forcing
#' suffix there just defeated that collapse by making the text different
#' again. Two tables sharing a series_label because they're genuinely the
#' same series in different breakdown shapes (e.g. a dozen "Permanent
#' Residents" tables, each with a different single category dimension) are
#' *supposed* to look identical - match_candidates() is what keeps them
#' from ever surfacing as separate, confusingly-identical Series options at
#' once. A human editor typing an identical "Series (custom)" value across
#' several tables (see data-raw/06_build_label_lookups.R) is making exactly
#' that "these are one series" call on purpose; app/data/label_overrides.xlsx's
#' `Source table title` column is there so they can spot and fix an
#' accidental collision themselves if two rows sharing a label turn out
#' not to actually belong together.

#' Split the single "temporary_workers" catalog dataset into two themes -
#' International Mobility Program (IMP) and Temporary Foreign Worker
#' Program (TFWP) - so each gets its own tab instead of forcing users to
#' pick the program via an IMP/TFWP-prefixed label within one dropdown.
#' Humanitarian & Compassionate work permits are classified under IMP: in
#' IRCC's own program structure they're LMIA-exempt and administered under
#' the International Mobility Program, even though the source table titles
#' don't say "IMP" outright.
split_temporary_workers <- function(catalog) {
  is_tw <- catalog$dataset == "temporary_workers"
  is_tfwp <- is_tw & grepl("Temporary Foreign Worker Program|\\(TFWP\\)",
                           catalog$table_title, ignore.case = TRUE)
  catalog$dataset[is_tw & !is_tfwp] <- "temporary_workers_imp"
  catalog$dataset[is_tfwp] <- "temporary_workers_tfwp"
  catalog
}

#' General phrase -> abbreviation map, used by derive_series_label() to
#' compact whatever population/program qualifier text survives its
#' boilerplate-stripping. Matched case-insensitively (source titles mix
#' "Province/Territory" and "province/territory" for the same concept) but
#' the replacement text is always used verbatim, so output stays consistent
#' (always "P/T", never a mix of "P/T" and "p/t").
GENERAL_ABBREV <- c(
  "and year in which permit\\(s\\) became effective" = "",
  "in which permit\\(s\\) became effective" = "",
  "and calendar year" = "(Cal. Yr)",
  "on December 31st" = "(Dec 31)",
  "Census Metropolitan Area \\(CMA\\)" = "CMA",
  "Census Metropolitan Area" = "CMA",
  "Census Subdivision" = "CSD",
  "Census Division" = "CD",
  "Province\\s*/\\s*Territory" = "P/T",
  "Intended Occupation \\([^)]*NOC[^)]*\\)" = "Occupation (NOC)",
  "Country of Citizenship" = "Citizenship",
  "Country of Birth" = "Birth Country",
  "Designated Learning Institution" = "DLI",
  "Immigration Category" = "Imm. Category",
  "of Intended Destination" = "",
  "of the Intended Destination" = "",
  "\\((for )?[Ww]ork [Pp]urposes?( only)?\\)" = "(Work)",
  "Work Permit Holder Status" = "Work Permit",
  "work permit holders" = "permits",
  "Work Permit Holders" = "Permits"
)

#' Convert absolute values to % of total per period, for Display as =
#' "Percentage of Total". No special-casing needed for whether a
#' Suppressed Residual segment is present: by the time this runs, the
#' residual (when computable) has already been folded into `d` as its own
#' row (see build_plot_data()), so summing everything currently in `d` for
#' a period already gives the right denominator either way - the real
#' published total when the residual is present, or just the visible sum
#' when it isn't.
to_percent_of_total <- function(d) {
  if (nrow(d) == 0) return(d)
  # base ifelse()'s result length follows its *condition*, not its "yes"
  # branch - with a per-group scalar condition (sum(...) > 0) that
  # silently truncates the whole vectorized division to one recycled
  # value. dplyr::if_else() doesn't have that gotcha, but still needs the
  # group total materialized as its own (per-row-recycled) column first,
  # not recomputed inline, so both branches stay properly elementwise.
  d |>
    dplyr::group_by(.data$period_display) |>
    dplyr::mutate(
      period_total = sum(.data$value, na.rm = TRUE),
      value = dplyr::if_else(.data$period_total > 0, 100 * .data$value / .data$period_total, 0)
    ) |>
    dplyr::select(-"period_total") |>
    dplyr::ungroup()
}

# ---------------------------------------------------------------------------
# series_facts query layer (data-raw/08_build_series_facts.R builds the
# table these read from - one canonical, deduplicated row per series/
# facet/geography/period, already merged across every contributing source
# table, so none of the functions below need to know about `table_id` or
# do any cross-table merging themselves - that already happened upstream).
# ---------------------------------------------------------------------------

#' One row per (theme, series, facet, geo_level) combination actually
#' present in `series_facts`, with just enough summary info to drive the
#' UI without re-querying the full (multi-million-row) table on every
#' input change: whether deeper breakdown_2/3 data exists, whether monthly
#' data exists, whether it's a stock series, and its year range. Computed
#' once at app startup (like `catalog`/`theme_dim_map` before it).
build_series_summary <- function(con) {
  dplyr::tbl(con, "series_facts") |>
    dplyr::group_by(.data$theme, .data$series, .data$facet, .data$geo_level) |>
    dplyr::summarise(
      # how many geo_N columns are actually meaningful at this geo_level for
      # this series - not a fixed per-rank constant, since e.g. a CMA-only
      # source table has geo_depth 1 for "CMA" while another series' CMA
      # rank is nested under its own PT level (geo_depth 2)
      geo_depth = (as.integer(max(!is.na(.data$geo_1), na.rm = TRUE)) +
                     as.integer(max(!is.na(.data$geo_2), na.rm = TRUE)) +
                     as.integer(max(!is.na(.data$geo_3), na.rm = TRUE))),
      has_breakdown_2 = max(!is.na(.data$breakdown_2), na.rm = TRUE) == 1,
      has_breakdown_3 = max(!is.na(.data$breakdown_3), na.rm = TRUE) == 1,
      has_month = max(.data$period_type == "month", na.rm = TRUE) == 1,
      is_stock = max(.data$is_stock, na.rm = TRUE) == 1,
      min_year = min(.data$period_year, na.rm = TRUE),
      max_year = max(.data$period_year, na.rm = TRUE),
      .groups = "drop"
    ) |>
    dplyr::collect()
}

#' Distinct places available at one geo_level, for a specific facet's own
#' rows (Geographic unit picker) - the series_facts analogue of
#' list_geo_units(). `geo_depth` is how many geo_N columns are populated at
#' this geo_level (1 for PT/CMA, 2 for CD, 3 for CSD). CD/CSD names recur
#' across provinces, so for those the option *value* encodes the full
#' geo_1..geo_depth ancestor prefix (GEO_UNIT_SEP-joined, same convention
#' as list_geo_units()) and the *display* label gets a ", <province
#' abbreviation>" suffix.
list_series_geo_units <- function(con, theme, series, facet, geo_level, geo_depth) {
  geo_cols <- paste0("geo_", seq_len(geo_depth))
  d <- dplyr::tbl(con, "series_facts") |>
    dplyr::filter(.data$theme == !!theme, .data$series == !!series, .data$facet == !!facet,
                   .data$geo_level == !!geo_level) |>
    dplyr::select(dplyr::all_of(geo_cols)) |>
    dplyr::distinct() |>
    dplyr::collect()
  d <- d[stats::complete.cases(d), , drop = FALSE]
  if (nrow(d) == 0) return(c("All" = "All"))

  unit_value <- do.call(paste, c(as.list(d[geo_cols]), sep = GEO_UNIT_SEP))
  place <- d[[geo_depth]]
  display <- if (geo_depth == 1) {
    place
  } else {
    abbr <- PROVINCE_ABBR[d[["geo_1"]]]
    ifelse(!is.na(abbr), paste0(place, ", ", abbr), place)
  }

  ord <- if (identical(geo_level, "PT")) {
    order(match(display, PROVINCE_ORDER_WEST_TO_EAST, nomatch = length(PROVINCE_ORDER_WEST_TO_EAST) + 1L))
  } else {
    order(display)
  }
  c("All" = "All", stats::setNames(unit_value[ord], display[ord]))
}

#' Distinct `breakdown_1` (or, filtered to one `breakdown_1` value,
#' `breakdown_2`) values available for a series/facet/geo_level - choices
#' for the cascading "drill into..." selectors (see app.R) that only
#' appear when a facet's own nesting actually goes that deep
#' (`has_breakdown_2`/`has_breakdown_3` in build_series_summary()).
list_series_breakdown_values <- function(con, theme, series, facet, geo_level, drill_1 = NULL) {
  q <- dplyr::tbl(con, "series_facts") |>
    dplyr::filter(.data$theme == !!theme, .data$series == !!series, .data$facet == !!facet,
                   .data$geo_level == !!geo_level)
  col <- if (is.null(drill_1)) "breakdown_1" else {
    q <- q |> dplyr::filter(.data$breakdown_1 == !!drill_1)
    "breakdown_2"
  }
  q |> dplyr::filter(!is.na(.data[[col]])) |> dplyr::distinct(.data[[col]]) |>
    dplyr::collect() |> dplyr::pull(1) |> sort()
}

#' Whether `con` has a `category_translations` table yet - populated by
#' data-raw/09_build_translations.R (flat-CSV FR_ pairs) and
#' data-raw/09_harvest_fr_translations.R (pivot Excel/IRB pairs), neither of
#' which need to have run for the app to work: translate_vec() below falls
#' back to the original English text wherever no translation row exists, so
#' bilingual coverage can grow incrementally without an app code change.
has_category_translations <- function(con) {
  "category_translations" %in% DBI::dbListTables(con)
}

#' Translate a vector of series_facts display text (series/facet/breakdown
#' category values) to French via `category_translations`, falling back to
#' the original English text wherever no translation exists - never blank,
#' never an error. `context` narrows the lookup to the right kind of text
#' (e.g. "breakdown_1"); `table_id`, when given, prefers a translation scoped
#' to that one source table (the same reason label_overrides.xlsx keys
#' breakdown-item overrides by `(table_id, label)` rather than by label
#' alone - the same English text can mean different things in different
#' tables), falling back to a table-agnostic match, then to English.
#' No-ops entirely (returns `x` unchanged) when `lang` is "en" or the
#' `category_translations` table doesn't exist yet.
translate_vec <- function(con, x, context, lang, table_id = NULL) {
  if (!identical(lang, "fr") || length(x) == 0) return(x)

  # series/facet display names come from a table's own *title* text, which
  # has no automatic French-derivation step (unlike breakdown_1/2/3 values,
  # bulk-harvested from source-data row content) - SERIES_FACET_LABELS_FR
  # (app/R/i18n.R) is a small, hand-maintained lookup for exactly these two
  # contexts, checked first; anything it doesn't cover still falls through
  # to category_translations below (harmless no-op there for series/facet
  # today, but keeps the door open if that ever gets an auto source).
  if (context %in% c("series", "facet")) {
    hit <- unname(SERIES_FACET_LABELS_FR[x])
    covered <- !is.na(hit)
    if (all(covered)) return(hit)
    x_remaining <- x
    x_remaining[covered] <- hit[covered]
    x <- x_remaining
  }

  if (!has_category_translations(con)) return(x)

  lookup <- dplyr::tbl(con, "category_translations") |>
    dplyr::filter(.data$context == !!context, .data$en_text %in% !!unique(x)) |>
    dplyr::collect()
  if (nrow(lookup) == 0) return(x)

  scoped <- if (!is.null(table_id)) {
    lookup[!is.na(lookup$table_id) & lookup$table_id == table_id, , drop = FALSE]
  } else {
    lookup[0, , drop = FALSE]
  }
  unscoped <- lookup[is.na(lookup$table_id), , drop = FALSE]

  fr_for <- function(en) {
    hit <- scoped$fr_text[scoped$en_text == en]
    if (length(hit) == 0) hit <- unscoped$fr_text[unscoped$en_text == en]
    if (length(hit) == 0 || is.na(hit[1]) || !nzchar(hit[1])) en else hit[1]
  }
  vapply(x, fr_for, character(1), USE.NAMES = FALSE)
}

#' Pull one (theme, series, facet, geo_level) view's rows out of
#' `series_facts`, shaped for aggregate_series(): `entity_id` (every
#' geo_N/breakdown_N column concatenated - the true leaf grain, needed so
#' a stock series' "latest available month" resolution (aggregate_series())
#' works the same way it always has, whichever grain these rows happen to
#' be at), `category` (whichever column is the current display axis),
#' `period_year/quarter/month`, `value`.
#'
#' `geo_unit_prefix`: optional exact geo_1..k ancestor values (a specific
#' Geographic unit chosen) - narrows to one place instead of showing every
#' place at `geo_level` as its own category.
#' `drill_1`/`drill_2`: optional breakdown_1/breakdown_2 *values* chosen
#' via the cascading sub-breakdown selectors (see app.R) - when set, the
#' category becomes the next-deeper breakdown column, filtered to that
#' value, instead of breakdown_1 itself.
fetch_series_rows <- function(con, theme, series, facet, geo_level, geo_depth, year_range,
                               geo_unit_prefix = character(0), drill_1 = NULL, drill_2 = NULL) {
  q <- dplyr::tbl(con, "series_facts") |>
    dplyr::filter(
      .data$theme == !!theme, .data$series == !!series, .data$facet == !!facet,
      .data$geo_level == !!geo_level,
      .data$period_year >= !!year_range[1], .data$period_year <= !!year_range[2]
    )
  for (i in seq_along(geo_unit_prefix)) {
    col <- paste0("geo_", i)
    q <- q |> dplyr::filter(.data[[col]] == !!geo_unit_prefix[i])
  }
  if (!is.null(drill_1)) q <- q |> dplyr::filter(.data$breakdown_1 == !!drill_1)
  if (!is.null(drill_2)) q <- q |> dplyr::filter(.data$breakdown_2 == !!drill_2)

  d <- q |>
    dplyr::select("geo_1", "geo_2", "geo_3", "breakdown_1", "breakdown_2", "breakdown_3",
                   "period_year", "period_quarter", "period_month", "value") |>
    dplyr::collect()
  if (nrow(d) == 0) return(d[0, ])

  d$entity_id <- do.call(paste, c(lapply(d[c("geo_1", "geo_2", "geo_3", "breakdown_1", "breakdown_2", "breakdown_3")],
                                          function(x) ifelse(is.na(x), "", x)), sep = "␟"))

  if (identical(facet, "Total")) {
    if (identical(geo_level, "National") || length(geo_unit_prefix) >= geo_depth) {
      d$category <- "Total"
    } else {
      place_col <- paste0("geo_", geo_depth)
      place <- d[[place_col]]
      d$category <- if (geo_depth > 1) {
        abbr <- PROVINCE_ABBR[d$geo_1]
        ifelse(!is.na(abbr), paste0(place, ", ", abbr), place)
      } else {
        place
      }
    }
  } else if (!is.null(drill_2)) {
    d$category <- d$breakdown_3
  } else if (!is.null(drill_1)) {
    d$category <- d$breakdown_2
  } else {
    d$category <- d$breakdown_1
  }

  d[c("entity_id", "category", "period_year", "period_quarter", "period_month", "value")]
}

#' The canonical "published total" for this same (theme, series, geo_level,
#' geo unit) scope, for the Suppressed Residual - series_facts's own
#' facet = "Total" rows, already the least-suppressed value available
#' across every contributing source table (see
#' data-raw/08_build_series_facts.R) - not one table's own subtotal, so a
#' Sex breakdown and an Occupation breakdown of the same series reconcile
#' to the exact same total instead of each table's own slightly different
#' published figure.
fetch_series_published_total <- function(con, theme, series, geo_level, geo_depth, year_range,
                                          geo_unit_prefix = character(0)) {
  d <- fetch_series_rows(con, theme, series, "Total", geo_level, geo_depth, year_range, geo_unit_prefix)
  if (nrow(d) == 0) return(NULL)
  d |>
    dplyr::group_by(.data$period_year, .data$period_quarter, .data$period_month) |>
    dplyr::summarise(value = sum(.data$value, na.rm = TRUE), .groups = "drop")
}

#' End-to-end series_facts equivalent of build_plot_data(): fetch, roll up
#' to the requested granularity (aggregate_series() - unchanged, already
#' generic over whatever "entity"/"category" mean), cap categories, append
#' the Suppressed Residual against the canonical series-wide total (not a
#' single table's own subtotal - see fetch_series_published_total()),
#' convert to percentages if requested, and order both axes.
#'
#' The residual is only ever computed at the *top* breakdown level (no
#' `drill_1`/`drill_2`) - `fetch_series_published_total()` always returns the
#' series' whole grand total, with no way to narrow it to "just the Economic
#' category" or similar, since `series_facts`'s `facet = "Total"` rows are
#' only ever the overall total, never a per-breakdown_1-value subtotal. Once
#' a drill is active, `raw`/`agg` are already filtered down to that one
#' breakdown_1 (and maybe breakdown_2) value, so comparing their sum against
#' the *whole-series* total would count everything outside the current drill
#' as "suppressed" - not a real suppression signal, just every other category
#' the user isn't currently looking at (found from a user report: British
#' Columbia / Immigration Category / Economic / Business showed as almost
#' entirely Suppressed Residual, because the comparison was against all of
#' BC's admissions, not just its Economic-category ones).
build_series_plot_data <- function(con, theme, series, facet, geo_level, geo_depth, granularity,
                                    year_range, is_stock, top_n, display_as = "absolute",
                                    geo_unit_prefix = character(0), drill_1 = NULL, drill_2 = NULL) {
  raw <- fetch_series_rows(con, theme, series, facet, geo_level, geo_depth, year_range,
                            geo_unit_prefix, drill_1, drill_2)
  agg <- aggregate_series(raw, granularity, is_stock)

  residual_rows <- NULL
  if (nrow(agg) > 0 && is.null(drill_1)) {
    published_raw <- fetch_series_published_total(con, theme, series, geo_level, geo_depth,
                                                    year_range, geo_unit_prefix)
    if (!is.null(published_raw) && nrow(published_raw) > 0) {
      published_raw$entity_id <- "total"
      published_raw$category <- "total"
      published <- aggregate_series(published_raw, granularity, is_stock) |>
        dplyr::transmute(.data$period_display, published_total = .data$value)

      visible_totals <- agg |>
        dplyr::group_by(.data$period_display, .data$period_sort) |>
        dplyr::summarise(visible_total = sum(.data$value, na.rm = TRUE), .groups = "drop")
      residual_rows <- dplyr::inner_join(published, visible_totals, by = "period_display") |>
        dplyr::mutate(value = pmax(0, .data$published_total - .data$visible_total)) |>
        dplyr::filter(.data$value > 0) |>
        dplyr::transmute(category = "Suppressed Residual", .data$period_display, .data$period_sort, .data$value)
    }
  }

  capped <- collapse_to_top_n(agg, top_n)
  if (!is.null(residual_rows) && nrow(residual_rows) > 0) {
    capped <- dplyr::bind_rows(capped, residual_rows)
  }
  if (nrow(capped) == 0) return(capped)

  period_levels <- capped |>
    dplyr::distinct(.data$period_display, .data$period_sort) |>
    dplyr::arrange(.data$period_sort) |>
    dplyr::pull(.data$period_display)

  cat_totals_desc <- capped |>
    dplyr::filter(.data$category != "Suppressed Residual") |>
    dplyr::group_by(.data$category) |>
    dplyr::summarise(total = sum(.data$value, na.rm = TRUE), .groups = "drop") |>
    dplyr::arrange(dplyr::desc(.data$total))
  level_order <- order_categories(cat_totals_desc)
  if ("Suppressed Residual" %in% capped$category) level_order <- c(level_order, "Suppressed Residual")

  out <- capped |>
    dplyr::mutate(
      period_display = factor(.data$period_display, levels = period_levels),
      category = factor(.data$category, levels = level_order)
    )

  if (identical(display_as, "percent")) out <- to_percent_of_total(out)
  out
}

#' Every raw table_id that actually contributed at least one row to a
#' (theme, series, geo_level[, geo unit]) view - for the citation, which
#' now potentially spans several source tables since a "Total" view merges
#' across every sibling that offers that geography (see
#' data-raw/08_build_series_facts.R). Falls back to every source_table_id
#' for the whole series if the specific geo scope has no rows (e.g. a
#' still-loading selection).
series_source_table_ids <- function(con, theme, series, facet = NULL, geo_level = NULL) {
  q <- dplyr::tbl(con, "series_facts") |>
    dplyr::filter(.data$theme == !!theme, .data$series == !!series)
  if (!is.null(facet)) q <- q |> dplyr::filter(.data$facet == !!facet)
  if (!is.null(geo_level)) q <- q |> dplyr::filter(.data$geo_level == !!geo_level)
  ids <- q |> dplyr::distinct(.data$source_table_id) |> dplyr::collect() |> dplyr::pull(.data$source_table_id)
  if (length(ids) == 0) {
    ids <- dplyr::tbl(con, "series_facts") |>
      dplyr::filter(.data$theme == !!theme, .data$series == !!series) |>
      dplyr::distinct(.data$source_table_id) |> dplyr::collect() |> dplyr::pull(.data$source_table_id)
  }
  ids
}

#' Pull the 8-char hash prefix out of a table_id ("dataset/hash__slug") -
#' used to join back to data-raw/manifest.csv, which is keyed by the full
#' CKAN resource_id (hash = substr(resource_id, 1, 8)). Synthetic/derived
#' table_ids (e.g. the merged refugees table built by build_refugees_table())
#' don't have this shape and return NA - callers fall back to citing that
#' table's sibling source tables instead (see table_citation_ui() in app.R).
extract_table_hash <- function(table_id) {
  m <- regmatches(table_id, regexpr("(?<=/)[0-9a-f]{8}(?=__)", table_id, perl = TRUE))
  if (length(m) == 0) NA_character_ else m
}

#' Build a hash -> source-resource lookup from data-raw/manifest.csv, for
#' citing each catalog table's original CKAN resource in the app: agency
#' (IRCC vs IRB), file format, direct download URL, CKAN dataset landing
#' page, and the date CKAN last reported the resource as modified
#' ("Last updated" in the citation - `last_modified_ckan`, the same
#' timestamp the download pipeline uses to detect changed resources; see
#' data-raw/02_download_data.R).
build_source_lookup <- function(manifest) {
  manifest |>
    dplyr::mutate(
      hash = substr(.data$resource_id, 1, 8),
      agency = ifelse(
        .data$dataset %in% c("rpd_decisions", "rpd_1997_2021"),
        "Immigration and Refugee Board of Canada (IRB)",
        "Immigration, Refugees and Citizenship Canada (IRCC)"
      ),
      dataset_url = paste0("https://open.canada.ca/data/en/dataset/", .data$dataset_id),
      updated_at = format(as.Date(.data$last_modified_ckan), "%Y-%m-%d")
    ) |>
    dplyr::select("hash", "agency", "table_name", "format", "url", "dataset_url", "updated_at") |>
    dplyr::distinct(.data$hash, .keep_all = TRUE)
}

#' The full, uncut citation title for one table - plain text, not the HTML
#' `table_citation_ui()` (app.R) renders. Same hash/sibling-fallback lookup
#' against `source_lookup` (see build_source_lookup()) as that function
#' uses, so a report built from this reflects exactly what the app's own
#' citation shows - not `catalog$table_title`, which can carry an internal
#' multi-sheet suffix (see title_for_slug() in data-raw/05_build_duckdb.R)
#' the citation never displays. Shared by data-raw/06_build_label_lookups.R
#' (so `label_overrides.xlsx` shows editors which real source table a
#' table_id corresponds to) and data-raw/07_build_series_reference.R.
citation_title_for <- function(table_id, sibling_ids, source_lookup) {
  hash <- extract_table_hash(table_id)
  hashes <- if (!is.na(hash)) {
    hash
  } else {
    sibling_hashes <- vapply(sibling_ids, extract_table_hash, character(1))
    unique(sibling_hashes[!is.na(sibling_hashes)])
  }
  rows <- source_lookup[source_lookup$hash %in% hashes, , drop = FALSE]
  if (nrow(rows) == 0) return(NA_character_)
  paste(unique(rows$table_name), collapse = "; ")
}
