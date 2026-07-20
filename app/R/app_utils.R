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

#' Table labels for which the leaf category should get a ", <province
#' abbreviation>" suffix - Census Division/Subdivision names aren't unique
#' across provinces, and in these tables level_1 is always the
#' Province/Territory (checked against the catalog when this was written).
CENSUS_GEO_LABELS <- c("Census Division", "Census Subdivision")

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
GEO_RANK_PATTERNS <- c(
  "Census Subdivision" = "CSD",
  "Census Division" = "CD",
  "Census Metropolitan Area|\\bCMA\\b" = "CMA",
  "Province\\s*/?\\s*Territory|\\bP/T\\b" = "PT"
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

#' Generic, semantically-empty level labels produced when the title-parsing
#' fallback (guess_level_labels() in R/duckdb_utils.R) or a flat table's own
#' literal column names (e.g. "program_level_2") run out of real dimension
#' names to report. Excluded entirely from the "Break down by" selector -
#' picking one would produce a real data split with no way to explain what
#' it actually represents.
FILLER_LEVEL_REGEX <- "^(Category|Program) Level \\d+$"

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

#' List the distinct places available at one geographic rank for a table,
#' for the "Geographic unit" selectize in app.R. Always includes "All"
#' first. CMA/CD/CSD names recur across provinces (e.g. more than one
#' "Division No. 1"), so for those ranks the option *value* encodes the
#' full level_1..level_<geo_level_idx> ancestor prefix (joined with
#' GEO_UNIT_SEP) rather than the bare name alone - both to disambiguate
#' same-named places in the picker itself and so the value round-trips
#' straight into an exact-prefix filter (parse_geo_unit(), used by
#' fetch_leaf_rows()/fetch_published_total()). The *display* label gets
#' the same ", <province abbreviation>" treatment fetch_leaf_rows() already
#' applies when showing CD/CSD as the chart's category, for the same
#' disambiguation reason. Provinces are ordered west-to-east
#' (PROVINCE_ORDER_WEST_TO_EAST) when geo_rank == "PT"; other ranks sort by
#' display label.
list_geo_units <- function(con, table_id, n_levels, geo_rank, geo_level_idx) {
  level_cols <- paste0("level_", seq_len(geo_level_idx))
  d <- dplyr::tbl(con, "facts") |>
    dplyr::filter(.data$table_id == !!table_id, .data$row_level == !!n_levels) |>
    dplyr::select(dplyr::all_of(level_cols)) |>
    dplyr::distinct() |>
    dplyr::collect()
  d <- d[stats::complete.cases(d), , drop = FALSE]
  if (nrow(d) == 0) return(c("All" = "All"))

  unit_value <- do.call(paste, c(as.list(d[level_cols]), sep = GEO_UNIT_SEP))
  place <- d[[geo_level_idx]]
  display <- if (geo_level_idx == 1) {
    place
  } else {
    abbr <- PROVINCE_ABBR[d[[1]]]
    ifelse(!is.na(abbr), paste0(place, ", ", abbr), place)
  }

  ord <- if (identical(geo_rank, "PT")) {
    order(match(display, PROVINCE_ORDER_WEST_TO_EAST, nomatch = length(PROVINCE_ORDER_WEST_TO_EAST) + 1L))
  } else {
    order(display)
  }
  c("All" = "All", stats::setNames(unit_value[ord], display[ord]))
}

#' Split a Geographic unit selectize value back into its level_1..level_k
#' ancestor prefix values (see list_geo_units()). "All"/NULL/empty means no
#' unit filter is in effect.
parse_geo_unit <- function(geo_unit) {
  if (is.null(geo_unit) || identical(geo_unit, "All") || !nzchar(geo_unit)) {
    character(0)
  } else {
    strsplit(geo_unit, GEO_UNIT_SEP, fixed = TRUE)[[1]]
  }
}

#' TRUE if this table has any IRCC/IRB-published subtotal rows at all
#' (pivot-shaped tables only - flat tables never carry them, see
#' fetch_published_total()). Checked live per table switch; cheap given
#' the existing idx_facts_table_id index.
table_has_subtotals <- function(con, table_id) {
  hit <- dplyr::tbl(con, "facts") |>
    dplyr::filter(.data$table_id == !!table_id, .data$is_row_subtotal == TRUE) |>
    utils::head(1) |>
    dplyr::collect()
  nrow(hit) > 0
}

#' Pull the finest-grain leaf rows for one table from DuckDB: the deepest
#' row level (no double-counting from subtotal rows) and the finest
#' available time grain (month if the table has one, else year). Keeps
#' `entity_id` - the true leaf identity (every level column concatenated) -
#' distinct from `category` (the level the user chose to group/display by),
#' because for stock tables "latest month" has to be resolved per true leaf
#' entity *before* summing up to the display category (see
#' aggregate_series()); resolving it directly on the coarser category would
#' silently drop every entity but one within each category.
#'
#' When `level_label` is a Census Division/Subdivision (CENSUS_GEO_LABELS),
#' the category gets a ", <province abbreviation>" suffix from level_1 -
#' these names recur across provinces (more than one "Windsor"), so without
#' this, same-named places in different provinces would silently merge
#' into one category.
#'
#' `filter_level`/`filter_values` (optional) narrow the query to one exact
#' geographic ancestor prefix - the "Geographic unit" picker in app.R
#' turning geography into a *filter* rather than the display category (see
#' the `category_level` routing rule in app.R's `plot_data` reactive). This
#' is independent of `level`/`category`: a unit filter can be in effect
#' while a completely different (non-geographic) level is chosen as
#' `category`.
fetch_leaf_rows <- function(con, table_id, n_levels, level, year_range, has_month, level_label = NULL,
                             filter_level = NULL, filter_values = NULL) {
  period_type_filter <- if (isTRUE(has_month)) "month" else "year"
  level_cols <- paste0("level_", seq_len(n_levels))

  base <- dplyr::tbl(con, "facts") |>
    dplyr::filter(
      .data$table_id == !!table_id,
      .data$row_level == !!n_levels,
      .data$period_type == !!period_type_filter,
      .data$period_year >= !!year_range[1],
      .data$period_year <= !!year_range[2]
    )

  if (!is.null(filter_level) && filter_level > 0) {
    for (i in seq_len(filter_level)) {
      col <- paste0("level_", i)
      val <- filter_values[i]
      base <- base |> dplyr::filter(.data[[col]] == !!val)
    }
  }

  base <- if (identical(level, "total") || identical(level, "none")) {
    base |> dplyr::mutate(category = "Total")
  } else {
    lvl_col <- paste0("level_", level)
    base |> dplyr::mutate(category = .data[[lvl_col]])
  }

  d <- base |>
    dplyr::select(dplyr::all_of(level_cols), "category", "period_year", "period_quarter",
                   "period_month", "value") |>
    dplyr::collect()

  if (!identical(level, "total") && !identical(level, "none") &&
      isTRUE(level_label %in% CENSUS_GEO_LABELS) && "level_1" %in% names(d)) {
    abbr <- PROVINCE_ABBR[d$level_1]
    d$category <- ifelse(!is.na(abbr), paste0(d$category, ", ", abbr), d$category)
  }

  # build the true leaf entity key in plain R - simpler and more portable
  # than translating a dynamic-width paste() into SQL via dbplyr
  d$entity_id <- do.call(paste, c(as.list(d[level_cols]), sep = ""))
  d[c("entity_id", "category", "period_year", "period_quarter", "period_month", "value")]
}

#' Fetch the "real" (IRCC/IRB-published) total for one table/period/place,
#' for the Suppressed Residual (see build_plot_data()). Reuses the same
#' parent-subtotal matching pattern R/validate_utils.R's row-consistency
#' checks already rely on: a group's own published subtotal sits at
#' `row_level == <depth of that group's own dimension prefix>`, flagged
#' `is_row_subtotal == TRUE`, with `level_1..level_<depth>` holding that
#' group's own values (`level_1` is `NA` for the grand total, which always
#' sits at `row_level == 1`). `prefix_level`/`prefix_values` (0/empty for
#' the grand total) work exactly like `fetch_leaf_rows()`'s `filter_level`/
#' `filter_values`. A stock table's subtotal row is already a single
#' per-month aggregate (unlike leaf rows, no per-entity dedup is needed),
#' so the latest available month within the target quarter/year is taken
#' directly; a flow table's subtotal sums across months in the target
#' period, same as leaf rows. Returns `NULL` if no matching subtotal rows
#' exist for the requested filter/year range (callers should check
#' `table_has_subtotals()` once per table before relying on this).
fetch_published_total <- function(con, table_id, prefix_level, prefix_values, year_range,
                                   has_month, is_stock, granularity) {
  period_type_filter <- if (isTRUE(has_month)) "month" else "year"

  base <- dplyr::tbl(con, "facts") |>
    dplyr::filter(
      .data$table_id == !!table_id,
      .data$is_row_subtotal == TRUE,
      .data$row_level == !!max(prefix_level, 1),
      .data$period_type == !!period_type_filter,
      .data$period_year >= !!year_range[1],
      .data$period_year <= !!year_range[2]
    )

  base <- if (prefix_level == 0) {
    base |> dplyr::filter(is.na(.data$level_1))
  } else {
    for (i in seq_len(prefix_level)) {
      col <- paste0("level_", i)
      val <- prefix_values[i]
      base <- base |> dplyr::filter(.data[[col]] == !!val)
    }
    base
  }

  d <- base |>
    dplyr::select("period_year", "period_quarter", "period_month", "value") |>
    dplyr::collect()
  if (nrow(d) == 0) return(NULL)

  if (granularity == "Monthly") {
    out <- d |>
      dplyr::group_by(.data$period_year, .data$period_month) |>
      dplyr::summarise(published_total = sum(.data$value, na.rm = TRUE), .groups = "drop") |>
      dplyr::mutate(period_display = sprintf("%d-%02d", .data$period_year, .data$period_month))
  } else if (granularity == "Quarterly" && "period_quarter" %in% names(d) && !all(is.na(d$period_quarter))) {
    if (isTRUE(is_stock)) {
      out <- d |>
        dplyr::group_by(.data$period_year, .data$period_quarter) |>
        dplyr::slice_max(.data$period_month, n = 1, with_ties = FALSE) |>
        dplyr::ungroup() |>
        dplyr::transmute(.data$period_year, .data$period_quarter, published_total = .data$value)
    } else {
      out <- d |>
        dplyr::group_by(.data$period_year, .data$period_quarter) |>
        dplyr::summarise(published_total = sum(.data$value, na.rm = TRUE), .groups = "drop")
    }
    out <- out |> dplyr::mutate(period_display = sprintf("%d Q%d", .data$period_year, .data$period_quarter))
  } else {
    if (isTRUE(is_stock)) {
      out <- d |>
        dplyr::group_by(.data$period_year) |>
        dplyr::slice_max(.data$period_month, n = 1, with_ties = FALSE) |>
        dplyr::ungroup() |>
        dplyr::transmute(.data$period_year, published_total = .data$value)
    } else {
      out <- d |>
        dplyr::group_by(.data$period_year) |>
        dplyr::summarise(published_total = sum(.data$value, na.rm = TRUE), .groups = "drop")
    }
    out <- out |> dplyr::mutate(period_display = as.character(.data$period_year))
  }

  out |> dplyr::select("period_display", "published_total")
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
        period_display = sprintf("%d-%02d", .data$period_year, .data$period_month),
        period_sort = .data$period_year * 100 + .data$period_month
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
        period_display = sprintf("%d Q%d", .data$period_year, .data$period_quarter),
        period_sort = .data$period_year * 10 + .data$period_quarter
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

#' Determine category display order: west-to-east if the categories look
#' like a province/territory breakdown (at least half, and at least 3, are
#' recognized Canadian provinces/territories - any unrecognized values,
#' e.g. "Province/Territory not stated", are kept but appended after the
#' recognized ones); otherwise the pre-existing convention of ascending
#' total value. "Other" (the residual bucket from `collapse_to_top_n()`)
#' is always included, positioned to match whichever convention applies.
order_categories <- function(cat_totals_desc) {
  non_other <- cat_totals_desc$category[cat_totals_desc$category != "Other"]
  has_other <- "Other" %in% cat_totals_desc$category

  recognized <- intersect(PROVINCE_ORDER_WEST_TO_EAST, non_other)
  is_geographic <- length(non_other) > 0 &&
    length(recognized) >= max(3, ceiling(length(non_other) / 2))

  if (is_geographic) {
    unrecognized <- setdiff(non_other, PROVINCE_ORDER_WEST_TO_EAST)
    ordered <- c(recognized, unrecognized)
    if (has_other) ordered <- c(ordered, "Other")
  } else {
    ordered <- rev(non_other) # ascending total value
    if (has_other) ordered <- c("Other", ordered)
  }
  ordered
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

#' Per-dataset boilerplate stripped from `table_title` when building the
#' short "Data table" dropdown label (see simplify_table_label()). Every
#' table within a dataset tab repeats the theme name (e.g. "Permanent
#' Residents") and often a subject clause, which is redundant with the tab
#' title and the (unchanged) plot title - only the part of the title that
#' actually varies between a dataset's tables is useful in the dropdown.
#'
#' Each entry is either a bare regex (stripped to "") or a
#' `pattern = "replacement"` pair, e.g. the Humanitarian & Compassionate
#' phrase under temporary_workers_imp - that program name is kept (not
#' stripped) because, unlike the IMP/TFWP program names themselves, it's
#' not implied by the tab title and is the one thing distinguishing those
#' tables from the rest of the IMP tab.
THEME_BOILERPLATE <- list(
  permanent_residents = c(
    "Admissions of French-Speaking Permanent Residents",
    "Admissions of English-Speaking Permanent Residents",
    "Admissions of Permanent Residents",
    "Percentage of French Speaking Permanent Residents",
    "Percentage of English-Speaking Permanent Residents",
    "French-Speaking Permanent Residents",
    "English-Speaking Permanent Residents",
    "Permanent [Rr]esidents?"
  ),
  temporary_workers_imp = c(
    "All International Mobility Program \\(IMP\\) work permit holders" = "",
    "International Mobility Program \\(IMP\\) [Ww]ork [Pp]ermit [Hh]olders" = "",
    "International Mobility Program [Ww]ork [Pp]ermit [Hh]olders" = "",
    "Work permit holders for Humanitarian (&|and) Compassionate purposes" = "Humanitarian & Compassionate"
  ),
  temporary_workers_tfwp = c(
    "Temporary Foreign Worker Program \\(TFWP\\) [Ww]ork [Pp]ermit [Hh]olders" = "",
    "Temporary Foreign Worker Program [Ww]ork [Pp]ermit [Hh]olders" = ""
  ),
  study_permit_holders = c(
    "Study permit holders"
  ),
  asylum_claimants = c(
    "Asylum Claimants"
  ),
  tr_to_pr_transition = c(
    "Permanent Residents with [Pp]rior "
  ),
  refugees = c(
    "Refugee Protection Division \\(RPD\\) Decisions",
    "RPD decisions"
  )
)

#' General phrase -> abbreviation map applied after THEME_BOILERPLATE,
#' regardless of dataset. Matched case-insensitively (source titles mix
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

#' Shorten a catalog `table_title` into a compact "Data table" dropdown
#' label: strips the leading "Canada -"/"Quebec -" subject and the
#' dataset's theme name (already shown as the tab title and, unabridged, as
#' the plot title - see app.R's output$plot_title), then abbreviates common
#' long phrases via GENERAL_ABBREV. Falls back to the original title if
#' stripping leaves nothing usefully short (e.g. rpd_decisions' single
#' table, whose title *is* the theme name).
simplify_table_label <- function(table_title, dataset) {
  x <- table_title

  # drop a trailing multi-sheet disambiguator artifact, e.g. "— Pr Age"
  x <- sub("\\s*[—-]\\s*[A-Z][a-z]+(\\s[A-Za-z]+){0,3}\\s*$", "", x)

  # strip leading subject boilerplate
  x <- sub("^Open Dataset Request \\d+ (ENG|FRA)\\s*-?\\s*", "", x)
  x <- sub("^Canada\\s*\\(excluding Quebec\\)\\s*[-–]\\s*", "", x)
  x <- sub("^Canada\\s+ex-QC\\s*[-–]\\s*", "", x)
  x <- sub("^Canada\\s*[-–]\\s*", "", x)
  x <- sub("^Quebec\\s*[-–]\\s*", "", x)

  boilerplate <- THEME_BOILERPLATE[[dataset]] %||% character()
  boilerplate_pat <- names(boilerplate)
  if (is.null(boilerplate_pat)) boilerplate_pat <- rep("", length(boilerplate))
  for (i in seq_along(boilerplate)) {
    pat <- if (nzchar(boilerplate_pat[i])) boilerplate_pat[i] else unname(boilerplate[i])
    repl <- if (nzchar(boilerplate_pat[i])) unname(boilerplate[i]) else ""
    x <- sub(pat, repl, x, perl = TRUE)
  }

  # rpd_1997_2021's title: "from 1997-2021 by outcome and province of
  # claimant" reads better with the date range moved to a trailing suffix
  x <- sub("^\\s*from (\\d{4}-\\d{4}) by (.*)$", "By \\2 (\\1)", x, ignore.case = TRUE, perl = TRUE)

  for (i in seq_along(GENERAL_ABBREV)) {
    x <- gsub(names(GENERAL_ABBREV)[i], GENERAL_ABBREV[i], x, ignore.case = TRUE, perl = TRUE)
  }

  x <- gsub("\\s+", " ", x)
  x <- gsub("\\s+,", ",", x)          # drop a space left dangling before a comma
  x <- gsub(",\\s*,", ",", x)
  x <- gsub(",\\s*(\\(|$)", "\\1", x) # drop a comma left dangling before "(" or end of string
  x <- sub("^\\s*,\\s*", "", x)
  x <- sub("^\\s*by\\s+", "By ", x, ignore.case = TRUE)
  x <- trimws(x)
  x <- sub("\\.$", "", x)

  # capitalize whatever word now leads the label (boilerplate stripping can
  # leave a lowercase word, e.g. a source "...program..." fragment, at the front)
  if (nchar(x) > 0) substr(x, 1, 1) <- toupper(substr(x, 1, 1))

  if (nchar(x) < 4) x <- trimws(table_title)
  x
}

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

#' End-to-end: fetch, aggregate, cap categories, append the Suppressed
#' Residual (if computable), convert to percentages (if requested), and
#' order both axes for plotting (periods chronologically; categories
#' west-to-east for province/territory breakdowns, otherwise by ascending
#' total value; see order_categories()).
#'
#' `filter_level`/`filter_values`: optional geographic ancestor-prefix
#' filter (see fetch_leaf_rows()) - independent of `level`, which is
#' whichever level is currently the display category.
#' `has_subtotals`: from `table_has_subtotals()`, gates whether a
#' Suppressed Residual is attempted at all (flat tables never have one).
#' `display_as`: `"absolute"` (default) or `"percent"`.
build_plot_data <- function(con, table_id, n_levels, level, granularity, year_range, is_stock, top_n,
                             has_month, level_label = NULL, filter_level = NULL, filter_values = NULL,
                             has_subtotals = FALSE, display_as = "absolute") {
  raw <- fetch_leaf_rows(con, table_id, n_levels, level, year_range, has_month, level_label,
                         filter_level, filter_values)
  agg <- aggregate_series(raw, granularity, is_stock)

  # Suppressed Residual: the real published total for this same filter
  # context, minus the sum actually visible *before* any top-N collapsing
  # - top-N/"Other" is a display simplification, not a data limitation, so
  # it must not affect how much residual there "should" be.
  residual_rows <- NULL
  if (isTRUE(has_subtotals) && nrow(agg) > 0) {
    published <- fetch_published_total(
      con, table_id, prefix_level = filter_level %||% 0, prefix_values = filter_values %||% character(0),
      year_range = year_range, has_month = has_month, is_stock = is_stock, granularity = granularity
    )
    if (!is.null(published)) {
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
