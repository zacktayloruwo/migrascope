# Normalizes every tidy long table in data/processed/ into one unified
# schema and loads it into a DuckDB database (data/immigration.duckdb) for
# the Shiny app to query.
#
# The 89 processed tables come in two shapes (see R/process_utils.R):
#  - "pivot" tables already have level_1..level_k / row_level /
#    is_row_subtotal columns describing a nested row category.
#  - "flat" tables (IRCC flat CSVs, both IRB tables) have plain named
#    dimension columns instead, with no hierarchy (is_row_subtotal is
#    always FALSE).
#
# Both are normalized into the same shape: level_1..level_5 (padded with
# NA), row_level, is_row_subtotal - so the app can treat every table
# identically. A companion `catalog` table records, per table_id, what its
# levels actually mean (real dimension names for flat tables; a
# best-effort guess parsed from the table title for pivot tables) and
# which temporal granularities it supports.

MAX_LEVELS <- 5

# Title-text signature for point-in-time "stock" tables that publish only
# annual rows (e.g. "on December 31st", "with a valid permit") - these have
# no month/quarter data at all, so the ratio-based structural stock
# detection below can never run for them; this is the only signal
# available in that case. Kept in sync with R/validate_utils.R::reclassify_stock_tables().
STOCK_TITLE_PATTERN <- "on December 31st|as of December 31|with a valid permit"

period_meta_cols <- c("period_year", "period_quarter", "period_month", "period_type",
                       "period_label", "is_period_subtotal")
value_cols <- c("value", "suppressed", "is_percent")

#' Best-effort extraction of dimension labels from a table title, e.g.
#' "Canada - Admissions of Permanent Residents by Province/Territory and
#' Immigration Category, January 2015 - April 2026" -> c("Province/Territory",
#' "Immigration Category"). Falls back to generic "Category Level N" labels
#' for any level beyond what the title spells out (deep sub-categories, e.g.
#' Immigration Category > Group > Component, are rarely fully named in the
#' title).
#'
#' Purely textual, and purely positional - it has no way to notice when the
#' title's own word order doesn't match the table's real column order (the
#' CKAN catalog title for permanent_residents/840a3387 reads "by Country of
#' Birth and Gender", but the source file's actual columns are ordered
#' Gender-then-Country - the title-writer and the spreadsheet just don't
#' agree). classify_level_content()/resolve_level_labels() below correct
#' for that by checking the real data instead of trusting title order.
guess_level_labels <- function(title, n_levels) {
  by_part <- sub("^.*?\\bby\\b\\s*", "", title, ignore.case = TRUE)
  by_part <- sub(",?\\s*\\(.*?ranking\\).*$", "", by_part)
  by_part <- sub(",?\\s*(January|February|March|April|May|June|July|August|September|October|November|December)\\s+\\d{4}.*$", "", by_part)
  by_part <- sub(",?\\s*\\d{4}\\s*-\\s*\\d{4}.*$", "", by_part)
  by_part <- trimws(sub("\\.$", "", by_part))

  parts <- unlist(strsplit(by_part, ",|\\band\\b"))
  parts <- trimws(parts)
  parts <- parts[nzchar(parts)]

  labels <- character(n_levels)
  for (i in seq_len(n_levels)) {
    labels[i] <- if (i <= length(parts)) tools::toTitleCase(parts[i]) else paste("Category Level", i)
  }
  labels
}

#' Canada's 13 provinces/territories - a small, closed, universal
#' vocabulary, so a level column whose real values are mostly drawn from
#' this list can be identified as "Province/Territory" directly from its
#' content, independent of anything the title says.
PROVINCE_TERRITORY_NAMES <- c(
  "Alberta", "British Columbia", "Manitoba", "New Brunswick",
  "Newfoundland and Labrador", "Northwest Territories", "Nova Scotia",
  "Nunavut", "Ontario", "Prince Edward Island", "Quebec", "Saskatchewan",
  "Yukon"
)

#' Generic catch-all values ("Not stated", "Unknown", ...) show up across
#' many different dimensions (Gender, Age, Citizenship, ...), so on their
#' own they don't distinguish one dimension from another - excluded
#' entirely from CONTENT_LABEL_MATCHERS' match fraction (neither counted
#' as a match nor a mismatch) rather than either penalizing or crediting
#' whichever vocabulary happens to be tested first.
GENERIC_CATCHALL_VALUES <- c("not stated", "unknown", "n/a", "na")

#' Content-based classifiers for the handful of dimension types that are
#' both (a) small/closed/universal vocabularies, so real column values can
#' be checked against a known list or shape, and (b) common enough sources
#' of the title/column-order mismatch bug (see guess_level_labels()) to be
#' worth the trouble. Each function takes one level_N column's raw values
#' and returns the fraction (0-1) that plausibly belong to that dimension,
#' after stripping GENERIC_CATCHALL_VALUES and requiring at least 2
#' distinct remaining values (so a single-value column, most often already
#' filtered down to one entity, can't false-positive at 100%).
CONTENT_LABEL_MATCHERS <- list(
  # Unlike Gender/Age Group below, a single-value Province/Territory column
  # is still trusted at full confidence (min length 1, not 2) - discovered
  # in permanent_residents/2d5c04fe ("Quebec - English-Speaking Permanent
  # Residents by Immigration Category"): the table's own level_1 is a
  # constant "Quebec" (the whole table is pre-filtered to one province, so
  # there's only ever one distinct value), and the length>=2 guard existing
  # matchers use to avoid a coincidental single-value false-positive was
  # silently starving this column of any content signal at all, letting the
  # title's misattributed "Immigration Category" label stick to it instead
  # (see resolve_level_labels()'s generic-placeholder promotion below for
  # how the real "Immigration Category" label then correctly flows to
  # level_2 once this position is confidently reclassified). A single value
  # that happens to be an exact match against this small, closed, 13-name
  # vocabulary is a strong enough signal on its own; the false-positive risk
  # the length-2 guard defends against doesn't really apply to a vocabulary
  # this specific.
  "Province/Territory" = function(vals) {
    vals <- unique(trimws(vals[!is.na(vals)]))
    vals <- vals[!tolower(vals) %in% GENERIC_CATCHALL_VALUES]
    if (length(vals) < 1) return(0)
    mean(vals %in% PROVINCE_TERRITORY_NAMES)
  },
  "Gender" = function(vals) {
    vals <- unique(tolower(trimws(vals[!is.na(vals)])))
    vals <- vals[!vals %in% GENERIC_CATCHALL_VALUES]
    if (length(vals) < 2) return(0)
    mean(vals %in% c("male", "female", "another gender", "gender not stated", "gender x"))
  },
  "Age Group" = function(vals) {
    vals <- unique(trimws(vals[!is.na(vals)]))
    vals <- vals[!tolower(vals) %in% GENERIC_CATCHALL_VALUES]
    if (length(vals) < 2) return(0)
    mean(grepl("years?\\s*old|^\\d+\\s*(to|-)\\s*\\d+$", vals, ignore.case = TRUE))
  }
)

#' A content match has to be this confident (fraction of distinct values
#' recognized) before it's trusted to override/supply a label - loose
#' enough to tolerate an odd extra catch-all category slipping through the
#' GENERIC_CATCHALL_VALUES filter, strict enough that an unrelated
#' dimension with a couple of coincidentally-matching values won't
#' misfire.
CONTENT_MATCH_THRESHOLD <- 0.8

#' Classify one level_N column's actual values against
#' CONTENT_LABEL_MATCHERS, returning the best-matching label name if it
#' clears CONTENT_MATCH_THRESHOLD, else NA (most dimensions - Immigration
#' Category, Program, Occupation, Country, ... - have no small universal
#' vocabulary to check against and always return NA here, falling back to
#' guess_level_labels()'s title-based guess via resolve_level_labels()).
classify_level_content <- function(values) {
  scores <- vapply(CONTENT_LABEL_MATCHERS, function(f) f(values), numeric(1))
  best <- which.max(scores)
  if (scores[best] >= CONTENT_MATCH_THRESHOLD) names(CONTENT_LABEL_MATCHERS)[best] else NA_character_
}

#' Which single closed vocabulary (if any) one *individual* value belongs
#' to - the per-value counterpart to CONTENT_LABEL_MATCHERS (which score a
#' whole column at once). Used by drop_cross_vocabulary_rows() below to
#' tell apart a column's real, majority dimension from a smaller stray one
#' that happens to share the column.
value_vocab <- function(v) {
  if (v %in% PROVINCE_TERRITORY_NAMES) return("Province/Territory")
  vl <- tolower(v)
  if (vl %in% c("male", "female", "another gender", "gender not stated", "gender x")) return("Gender")
  if (grepl("years?\\s*old|^\\d+\\s*(to|-)\\s*\\d+$", v, ignore.case = TRUE)) return("Age Group")
  NA_character_
}

#' Detect and drop rows whose value in a level_N column belongs to a
#' different closed vocabulary (PROVINCE_TERRITORY_NAMES/Gender/Age Group
#' - see value_vocab()) than the vocabulary the rest of that column's rows
#' overwhelmingly belong to. Discovered in
#' temporary_workers/08d3441d ("...by gender, age and year..."): its
#' level_1 is genuinely the Gender axis (with Age nested under it at
#' level_2 for the real leaf rows), but the source sheet *also* publishes
#' a second, independent "by Age" marginal as more subtotal rows in that
#' same level_1 column - true_leaf_rows() (app/R/app_utils.R) has no way
#' to tell those apart from a genuine ragged branch and promotes them as
#' bogus extra "Gender" categories (literal age ranges alongside Male/
#' Female/...). Only the minority vocabulary's rows are dropped - that
#' content is redundant anyway (derivable by summing the table's own real
#' nested breakdown), so nothing is lost; the majority vocabulary, and any
#' value matching no closed vocabulary at all (most dimensions - the
#' overwhelming majority of columns are untouched), are left alone.
drop_cross_vocabulary_rows <- function(long, level_cols, table_id) {
  for (col in level_cols) {
    vals_all <- long[[col]]
    distinct_vals <- unique(trimws(vals_all[!is.na(vals_all)]))
    checkable <- distinct_vals[!tolower(distinct_vals) %in% GENERIC_CATCHALL_VALUES]
    if (length(checkable) < 2) next

    voc <- vapply(checkable, value_vocab, character(1), USE.NAMES = FALSE)
    if (length(unique(stats::na.omit(voc))) < 2) next

    voc_lookup <- stats::setNames(voc, checkable)
    row_voc <- unname(voc_lookup[trimws(vals_all)])
    majority <- names(which.max(table(row_voc)))
    drop_vals <- checkable[!is.na(voc) & voc != majority]
    if (length(drop_vals) == 0) next

    n_dropped <- sum(trimws(vals_all) %in% drop_vals, na.rm = TRUE)
    cli::cli_alert_warning(
      "{table_id}: dropping {n_dropped} row(s) from {col} where the value belongs to a different closed vocabulary than the column's real ({majority}) axis: {paste(drop_vals, collapse = ', ')}"
    )
    long <- long[is.na(vals_all) | !(trimws(vals_all) %in% drop_vals), , drop = FALSE]
  }
  long
}

#' Literal category values that are actually a mislabeled grand total, not a
#' real member of the dimension they sit in - discovered in the four "by
#' Country of Citizenship" tables (study_permit_holders/b505b9bc,
#' study_permit_holders/3897ef92, temporary_workers/f2696d77,
#' temporary_workers/2e910f7d), each of which publishes a "Total unique
#' persons" row at row_level 1 alongside every real country, with
#' is_row_subtotal FALSE - i.e. not flagged as a subtotal at all, just one
#' more "country" as far as row_level/is_row_subtotal can tell. Confirmed
#' via direct value comparison (2020, study_permit_holders/b505b9bc): the
#' "Total unique persons" row (798,425) is within suppression-noise of the
#' sum of every real country row that year (796,870) - i.e. it really is
#' the table's own grand total, not a genuine "unique persons" breakdown
#' category. Left in, it inflates any query that sums leaf categories
#' (double-counting the whole table's total on top of its real countries)
#' and would itself show up as a bogus "country" in the Break down by
#' selector.
BOGUS_TOTAL_ROW_VALUES <- c("total unique persons")

#' Drop rows whose value in a level_N column is one of BOGUS_TOTAL_ROW_VALUES
#' - a grand total published as if it were a real category value (see that
#' constant's comment). Unlike drop_cross_vocabulary_rows(), this isn't about
#' two real vocabularies sharing a column; it's a single always-wrong literal
#' value.
drop_bogus_total_rows <- function(long, level_cols, table_id) {
  for (col in level_cols) {
    vals_all <- trimws(long[[col]])
    is_bogus <- !is.na(vals_all) & tolower(vals_all) %in% BOGUS_TOTAL_ROW_VALUES
    if (!any(is_bogus)) next
    cli::cli_alert_warning(
      "{table_id}: dropping {sum(is_bogus)} row(s) from {col} where the value ({paste(unique(vals_all[is_bogus]), collapse = ', ')}) is a mislabeled grand total, not a real category"
    )
    long <- long[!is_bogus, , drop = FALSE]
  }
  long
}

#' Cheap keyword check for whether a title-derived label already
#' plausibly refers to the same dimension a content match found - e.g.
#' "Province/Territory of Intended Destination" and "P/T of Designated
#' Learning Institution Type" both contain a province/territory keyword,
#' so a content match of "Province/Territory" doesn't necessarily mean
#' the title got the *position* wrong, just that it's more (or less)
#' descriptive than the generic content label. Only titles that don't
#' even mention the right keyword at all are genuinely inconsistent -
#' i.e., actually pointing at the wrong dimension.
CONTENT_LABEL_KEYWORDS <- list(
  "Province/Territory" = "province|territory",
  "Gender" = "gender|\\bsex\\b",
  "Age Group" = "\\bage\\b"
)

label_matches_keyword <- function(text, content_label) {
  kw <- CONTENT_LABEL_KEYWORDS[[content_label]]
  !is.null(kw) && grepl(kw, text, ignore.case = TRUE)
}

#' Reconcile guess_level_labels()'s title-derived labels (positional, but
#' can be wrong when the source title's word order doesn't match the
#' table's real column order) against classify_level_content()'s
#' content-derived labels (reads the real level_N values, always right
#' when confident, but only recognizes a few closed vocabularies so most
#' positions come back NA and still need the title guess).
#'
#' Deliberately conservative: a position's title label is only touched at
#' all when there's a genuine, detected conflict - never just because
#' content has *an* opinion. Concretely:
#'  1. A position is "self-consistent" (left completely alone) when
#'     content has no opinion (NA) or content's opinion agrees with what
#'     the title already implies there via CONTENT_LABEL_KEYWORDS - this
#'     is what keeps a more descriptive title phrase ("Province/Territory
#'     of Intended Destination") from being needlessly flattened to the
#'     generic content label it's consistent with, and what stops an
#'     otherwise-correct table from having an unrelated position's label
#'     silently reassigned or dropped (an earlier version of this
#'     function had exactly that bug: it unconditionally removed any
#'     title phrase matching a content label from a shared pool, which
#'     both flattened descriptive-but-consistent titles AND, worse, could
#'     silently drop or shift a *different*, perfectly correct label at
#'     another position once the pool ran out).
#'  2. A position is genuinely conflicted when content disagrees outright
#'     (case: guess_level_labels() attached the wrong phrase to it), or -
#'     the knock-on case - when some *other* conflicted position's
#'     content match is what this position's own title phrase actually
#'     describes (case: this position's rightful phrase got attached to
#'     the wrong position instead, e.g. the classic swap in
#'     permanent_residents/840a3387, "by Country of Birth and Gender"
#'     describing data that's really Gender-then-Country - position 1's
#'     content conflicts with "Country of Birth", *and* position 2's own
#'     phrase, "Gender", is exactly what position 1's content says is
#'     there, so position 2 is conflicted too even though its own content
#'     signal alone was NA).
#'  3. Only conflicted positions get replaced: a confident content match
#'     wins outright at its own position; any other conflicted position
#'     is filled from whatever's left in the *conflicted set's own* pool
#'     of original title phrases (excluding whichever ones content already
#'     claimed elsewhere), in their original relative order. Untouched,
#'     self-consistent positions are never pulled into this pool at all,
#'     so they can never be emptied out from under an unrelated position.
resolve_level_labels <- function(title_labels, content_labels) {
  n <- length(title_labels)

  self_consistent <- vapply(seq_len(n), function(i) {
    is.na(content_labels[i]) || label_matches_keyword(title_labels[i], content_labels[i])
  }, logical(1))

  conflicted <- !self_consistent
  for (i in which(!self_consistent)) {
    for (j in seq_len(n)) {
      # only pull in a position with no content opinion of its own
      # (is.na(content_labels[j])) - one that already has its own
      # independent, consistent content match doesn't need "donating"
      # just because its title phrase also happens to mention the same
      # keyword as a different position's conflict.
      if (j != i && !conflicted[j] && is.na(content_labels[j]) &&
          label_matches_keyword(title_labels[j], content_labels[i])) {
        conflicted[j] <- TRUE
      }
    }
  }

  # A position still holding guess_level_labels()'s generic "Category Level
  # N" fallback (the title's by-phrase didn't name this many dimensions)
  # and with no independent content opinion of its own has nothing of its
  # own to lose - if some OTHER position's real title phrase is being
  # displaced by a confident content match elsewhere, this position should
  # be first in line to receive it, rather than staying stuck with a
  # meaningless placeholder while the real phrase goes unclaimed (case:
  # permanent_residents/2d5c04fe, a "Quebec"-only table whose title says
  # just "by Immigration Category" - guess_level_labels() attaches that one
  # real phrase to level_1 positionally, leaving level_2 with "Category
  # Level 2"; content correctly reclassifies level_1 as Province/Territory
  # from its literal "Quebec" values, but level_2's own placeholder text
  # mentions no keyword at all, so the keyword-donor check above never
  # marks it conflicted on its own - without this rule "Immigration
  # Category" would be stranded at the reclaimed level_1 position instead
  # of flowing to level_2, where it belongs). Only applied when something
  # is already conflicted (an actual displaced phrase exists to redistribute
  # in the first place) - a table with no conflicts at all is left alone.
  if (any(conflicted)) {
    is_generic <- grepl("^Category Level \\d+$", title_labels)
    conflicted <- conflicted | (is_generic & is.na(content_labels))
  }

  if (!any(conflicted)) return(title_labels)

  final <- title_labels
  final[conflicted] <- NA_character_
  for (i in which(conflicted)) {
    if (!is.na(content_labels[i])) final[i] <- content_labels[i]
  }

  pool <- title_labels[conflicted]
  claimed <- tolower(content_labels[conflicted][!is.na(content_labels[conflicted])])
  for (txt in claimed) {
    hit <- which(tolower(pool) == txt)[1]
    if (!is.na(hit)) pool <- pool[-hit]
  }

  li <- 1
  for (i in which(conflicted)) {
    if (is.na(final[i])) {
      final[i] <- if (li <= length(pool)) pool[li] else paste("Category Level", i)
      li <- li + 1
    }
  }
  final
}

#' Normalize one processed long table into the unified schema, returning
#' the reshaped facts and a one-row catalog entry.
normalize_table <- function(long, table_id, dataset, table_title) {
  is_pivot <- "level_1" %in% names(long)

  if (is_pivot) {
    level_cols <- grep("^level_[0-9]+$", names(long), value = TRUE)
    long <- drop_cross_vocabulary_rows(long, level_cols, table_id)
    long <- drop_bogus_total_rows(long, level_cols, table_id)
    n_levels <- length(level_cols)
    title_labels <- guess_level_labels(table_title, n_levels)
    # Check the real data before trusting the title's word order - see
    # resolve_level_labels()/classify_level_content() above.
    content_labels <- vapply(level_cols, function(col) classify_level_content(long[[col]]), character(1))
    labels <- resolve_level_labels(title_labels, content_labels)

    facts <- long |>
      dplyr::select(dplyr::all_of(level_cols), "row_level", "is_row_subtotal",
                     dplyr::all_of(period_meta_cols), dplyr::all_of(value_cols))
  } else {
    dim_cols <- setdiff(names(long), c(period_meta_cols, value_cols, "is_row_subtotal"))
    n_levels <- length(dim_cols)
    labels <- tools::toTitleCase(gsub("_", " ", dim_cols))

    facts <- long |>
      dplyr::rename_with(~ paste0("level_", seq_along(dim_cols)), dplyr::all_of(dim_cols)) |>
      dplyr::mutate(row_level = n_levels, is_row_subtotal = FALSE) |>
      dplyr::select(dplyr::starts_with("level_"), "row_level", "is_row_subtotal",
                     dplyr::all_of(period_meta_cols), dplyr::all_of(value_cols))
  }

  # some flat tables' dimension columns are numeric (e.g. a country rank) -
  # force every level_N to character so tables combine cleanly regardless
  facts <- facts |>
    dplyr::mutate(dplyr::across(dplyr::starts_with("level_"), as.character))

  # pad up to MAX_LEVELS so every table's facts share one column set - a
  # table nested deeper than MAX_LEVELS (n_levels > MAX_LEVELS) needs no
  # padding at all (its levels get truncated to 1:MAX_LEVELS by the
  # select() below instead); the guard matters because `:` counts downward
  # when its left side exceeds its right (e.g. `(9):5` is `9,8,7,6,5`, not
  # empty), which would otherwise overwrite real level_5 (and beyond)
  # content with NA for every such table.
  if (n_levels < MAX_LEVELS) {
    for (i in (n_levels + 1):MAX_LEVELS) {
      facts[[paste0("level_", i)]] <- NA_character_
    }
  }
  facts <- facts |>
    dplyr::mutate(table_id = table_id) |>
    dplyr::select("table_id", paste0("level_", 1:MAX_LEVELS), "row_level", "is_row_subtotal",
                   dplyr::all_of(period_meta_cols), dplyr::all_of(value_cols))

  has_month <- any(facts$period_type == "month")
  has_quarter <- any(facts$period_type == "quarter_total")
  has_year <- any(facts$period_type == "year")
  years <- facts$period_year[!is.na(facts$period_year)]

  # "stock" tables (e.g. "with a valid permit" snapshots) aren't additive
  # across months - same detection as R/validate_utils.R::reclassify_stock_tables()
  is_stock <- FALSE
  if (has_month && has_quarter) {
    ratio_check <- facts |>
      dplyr::filter(.data$period_type %in% c("month", "quarter_total")) |>
      dplyr::group_by(dplyr::across(dplyr::starts_with("level_")), .data$period_year, .data$period_quarter) |>
      dplyr::summarise(
        total = sum(.data$value[.data$period_type == "quarter_total"], na.rm = TRUE),
        parts = sum(.data$value[.data$period_type == "month"], na.rm = TRUE),
        .groups = "drop"
      ) |>
      dplyr::filter(.data$total > 0)
    if (nrow(ratio_check) > 20) {
      is_stock <- (mean(ratio_check$parts / ratio_check$total, na.rm = TRUE) > 2)
    }
  } else {
    # No month+quarter data at all (e.g. an annual-only "on December 31st"
    # snapshot) - the ratio check above can never run, so title text is
    # the only signal available for these.
    is_stock <- grepl(STOCK_TITLE_PATTERN, table_title, ignore.case = TRUE)
  }

  catalog_row <- tibble::tibble(
    table_id = table_id, dataset = dataset, table_title = table_title,
    n_levels = n_levels,
    level_1_label = labels[1], level_2_label = if (n_levels >= 2) labels[2] else NA_character_,
    level_3_label = if (n_levels >= 3) labels[3] else NA_character_,
    level_4_label = if (n_levels >= 4) labels[4] else NA_character_,
    level_5_label = if (n_levels >= 5) labels[5] else NA_character_,
    has_month = has_month, has_quarter = has_quarter, has_year = has_year,
    is_stock = is_stock,
    min_year = if (length(years) > 0) min(years) else NA_integer_,
    max_year = if (length(years) > 0) max(years) else NA_integer_,
    n_rows = nrow(facts)
  )

  list(facts = facts, catalog_row = catalog_row)
}

#' Merge the two RPD (refugee decision) source tables into one continuous
#' "Refugees" theme table, spanning 1997-2026 with a single Outcome
#' breakdown (province-of-residence vs country-of-persecution are
#' different kinds of dimension across the two sources and can't be
#' unified, so the merge keeps only what both share: outcome by year).
#'
#' `rpd_decisions` (2013-2026, by country of persecution) uses
#' Positive/Negative/Other; `rpd_1997_2021` (1997-2021, by province of
#' residence) already uses Accepted/Rejected/Other - normalized here to
#' the latter vocabulary.
#'
#' For the years both sources cover (2013-2021), their outcome totals
#' don't match exactly - `rpd_decisions`' much finer country-level
#' breakdown (~200 categories) suppresses many more small cells than
#' `rpd_1997_2021`'s 13-province breakdown, and suppressed cells are
#' excluded from sums (same convention as everywhere else in this app -
#' see app.R's suppression caveat), so `rpd_decisions` totals run
#' systematically a few percent to ~30% below `rpd_1997_2021` for the same
#' year/outcome. That's an expected suppression artifact, not a data
#' error, but it means the two can't just be summed for the overlap
#' period. The merge instead takes `rpd_1997_2021` (fewer suppressed
#' cells, more complete) through 2021, and `rpd_decisions` (the only
#' source with newer data) from 2022 on - each year appears exactly once.
#' The year-by-outcome comparison is written to
#' data-raw/refugees_merge_overlap_check.csv for review.
build_refugees_table <- function(rpd_decisions_slug, rpd_1997_2021_slug) {
  col_types <- readr::cols(
    is_row_subtotal = "l", is_period_subtotal = "l",
    suppressed = "l", is_percent = "l", value = "d",
    period_year = "i", period_quarter = "i", period_month = "i",
    period_label = "c"
  )

  recent <- readr::read_csv(
    fs::path("data", "processed", "rpd_decisions", paste0(rpd_decisions_slug, "_long.csv")),
    show_col_types = FALSE, col_types = col_types
  ) |>
    dplyr::mutate(outcome = dplyr::recode(outcome, Positive = "Accepted", Negative = "Rejected"))

  historical <- readr::read_csv(
    fs::path("data", "processed", "rpd_1997_2021", paste0(rpd_1997_2021_slug, "_long.csv")),
    show_col_types = FALSE, col_types = col_types
  )

  overlap_years <- intersect(recent$period_year, historical$period_year)
  overlap_check <- dplyr::full_join(
    recent |> dplyr::filter(.data$period_year %in% overlap_years) |>
      dplyr::group_by(.data$period_year, .data$outcome) |>
      dplyr::summarise(total_rpd_decisions = sum(.data$value, na.rm = TRUE), .groups = "drop"),
    historical |> dplyr::filter(.data$period_year %in% overlap_years) |>
      dplyr::group_by(.data$period_year, .data$outcome) |>
      dplyr::summarise(total_rpd_1997_2021 = sum(.data$value, na.rm = TRUE), .groups = "drop"),
    by = c("period_year", "outcome")
  ) |>
    dplyr::mutate(
      pct_diff = round(100 * (.data$total_rpd_decisions - .data$total_rpd_1997_2021) /
                          pmax(.data$total_rpd_1997_2021, 1), 1)
    ) |>
    dplyr::arrange(.data$period_year, .data$outcome)

  readr::write_csv(overlap_check, "data-raw/refugees_merge_overlap_check.csv")
  cli::cli_alert_info(
    "Refugees merge: {nrow(overlap_check)} year x outcome rows compared for {min(overlap_years)}-{max(overlap_years)} overlap, pct_diff range [{min(overlap_check$pct_diff)}, {max(overlap_check$pct_diff)}]% (see data-raw/refugees_merge_overlap_check.csv)"
  )

  historical_max_year <- max(historical$period_year)
  combined <- dplyr::bind_rows(
    historical,
    recent |> dplyr::filter(.data$period_year > historical_max_year)
  ) |>
    dplyr::mutate(is_row_subtotal = FALSE) |>
    dplyr::select("outcome", "value", "suppressed", "is_percent", dplyr::all_of(period_meta_cols), "is_row_subtotal")

  out_dir <- fs::path("data", "processed", "refugees")
  fs::dir_create(out_dir)
  readr::write_csv(combined, fs::path(out_dir, "rpd_decisions_1997_2026_long.csv"))

  normalize_table(
    combined, "refugees/rpd_decisions_1997_2026", "refugees",
    "Refugee Protection Division (RPD) Decisions by Outcome, 1997-2026"
  )
}
