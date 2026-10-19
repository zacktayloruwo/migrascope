# Builds app/data/immigration.duckdb's `series_facts` table: one row per
# genuinely distinct (theme, series, breakdown facet/depth, geography,
# period) fact, already deduplicated across every source table that
# contributes to it. This is the fix for a problem query-time table
# selection couldn't solve: many tables within one series independently
# publish the same underlying total (e.g. a province's grand total) - one
# broken down by Sex, another by Intended Occupation, another by CD/CSD -
# each with its own suppression pattern, so the number shown depended on
# which sibling table happened to get picked for a given query. Here, that
# duplication is resolved once, at the row level, not by choosing one
# table to represent a whole series.
#
# Two kinds of rows, per (theme, series):
#  - facet = "Total": the shared, no-breakdown total at every geography
#    level (National, and whichever of PT/CMA/CD/CSD any member table
#    supports) - built by pulling each qualifying member table's OWN
#    published subtotal rows at that geo depth (table_geo_subtotals() in
#    app/R/app_utils.R), unioning across tables, and for every
#    (geography, period) cell taking the LARGEST reported value.
#    Suppression only ever removes value from a published sum, never
#    inflates it, so whichever sibling has the least suppression for that
#    specific cell reports the highest, most-complete number - confirmed
#    with the user as the merge rule. The winning table_id is kept in
#    `source_table_id` for traceability.
#  - facet = <a real breakdown name> (e.g. "Age Group", "Immigration
#    Category"): a member table's own leaf rows (table_facet_leaf_rows()),
#    reshaped into geo_1.. / breakdown_1.. columns. Usually only one
#    member table offers a given facet at all, so this is a plain union;
#    when more than one does (the French-Speaking PR "Immigration
#    Category" family - four sheets at different nesting/geo depth is the
#    concrete example already in this repo), they're unioned and any
#    genuinely overlapping cells get the same max-value merge as "Total"
#    rows. Different geo/depth coverage between siblings (one has a real
#    Province dimension, another goes one level deeper in the category
#    itself) is complementary, not overlapping, and both are kept as-is.
#
# Raw `facts`/`catalog` (from 05_build_duckdb.R) are untouched - this
# reads them and writes a new, additional table alongside them. Must run
# after 06_build_label_lookups.R, since it reads `catalog$series_label`
# and the already-corrected `level_N_label` columns that script bakes in.

library(DBI)
library(duckdb)
library(dplyr)

source("app/R/app_utils.R")

DB_PATH <- "app/data/immigration.duckdb"

if (!file.exists(DB_PATH)) {
  stop("app/data/immigration.duckdb not found - run 05_build_duckdb.R then 06_build_label_lookups.R first")
}

GEO_RANKS_ORDER <- c("PT", "CMA", "CD", "CSD")

#' The strict, exhaustively-nested geographic hierarchy this pipeline can
#' safely sum up: every Census Subdivision sits in exactly one Census
#' Division, every Census Division in exactly one Province/Territory, and
#' every Province/Territory sums to Canada - so a series' own PT-level
#' breakdown rows can be summed straight into a true National figure, CD
#' rows into their PT, etc. (see roll_up_facet_geo() below). CMA is
#' deliberately excluded: Census Metropolitan Areas don't exhaustively
#' cover a province (a lot of rural/non-metro population sits outside every
#' CMA), so summing a series' CMA-level rows would understate its true
#' PT/National total rather than equal it - CMA-level facet rows are never
#' rolled up or down.
GEO_HIERARCHY <- c("National", "PT", "CD", "CSD")

con <- dbConnect(duckdb(), DB_PATH, read_only = TRUE)
catalog <- tbl(con, "catalog") |> collect() |> split_temporary_workers()
dim_map <- build_theme_dimension_map(catalog)

#' A level only counts as Province/Territory if its values really are
#' provinces. Level labels are guessed from table titles (guess_level_labels()
#' in R/duckdb_utils.R), and a workbook titled "... by Province/Territory and
#' Immigration Category" can contain a sheet with no province level at all:
#' permanent_residents/d839c522's "Pr Immcat" sheet starts at Immigration
#' Category, so its categories (Economic, Sponsored Family, ...) ended up in
#' geo_1 and showed as "places". Checked against the level's actual values:
#' at least half its distinct values must be province/territory names (or a
#' "not stated"-type placeholder). A level that fails is demoted to a
#' category, and since the title guess assumed one level too many, the labels
#' from that position down shift up by one (its own label becomes the next
#' level's, e.g. "Immigration Category").
PT_NAMES <- names(PROVINCE_ABBR)
verify_pt_levels <- function(dim_map) {
  for (i in seq_len(nrow(dim_map))) {
    cl <- dim_map$classification[[i]]
    for (j in which(cl$geo_rank %in% "PT")) {
      col <- paste0("level_", cl$level_index[j])
      vals <- dbGetQuery(con, sprintf("SELECT DISTINCT %s AS v FROM facts WHERE table_id = ? AND %s IS NOT NULL", col, col),
                         params = list(dim_map$table_id[i]))$v
      looks_like_pt <- vals %in% PT_NAMES | grepl("not stated|unknown|outside canada", vals, ignore.case = TRUE)
      if (length(vals) == 0 || mean(looks_like_pt) >= 0.5) next

      cli::cli_alert_warning(
        "{dim_map$table_id[i]}: level {cl$level_index[j]} ({cl$label[j]}) holds no provinces - treated as a category")
      n <- nrow(cl)
      shifted <- c(cl$label[seq_len(j - 1)], cl$label[-seq_len(j)], paste("Category Level", cl$level_index[n]))
      fresh <- classify_level(shifted)
      cl$label <- shifted
      cl$geo_rank <- fresh$geo_rank
      cl$geo_rank[j] <- NA_character_
      cl$is_filler <- fresh$is_filler
      cl$label_normalized <- normalize_category_label(shifted)
    }
    dim_map$classification[[i]] <- cl
    dim_map$geo_ranks[[i]] <- unique(stats::na.omit(cl$geo_rank))
    dim_map$categories[[i]] <- unique(cl$label_normalized[is.na(cl$geo_rank) & !cl$is_filler])
  }
  dim_map
}
dim_map <- verify_pt_levels(dim_map)

# Percentage tables (facts.is_percent, set when the source's values are
# shares - e.g. "Percentage of French-speaking Permanent Residents") hold
# rates, not counts, so they can't be summed or merged with count tables.
# They used to feed the official-language series as if 0.0037 were a count,
# and one was mis-flagged as a stock table (docs/data-audit-2026-10-18.md,
# finding B).
percent_tables <- dbGetQuery(con, "SELECT DISTINCT table_id FROM facts WHERE is_percent")$table_id
if (length(percent_tables) > 0) {
  cli::cli_alert_info("Excluding {length(percent_tables)} percentage table(s): {basename(percent_tables)}")
  dim_map <- dim_map[!dim_map$table_id %in% percent_tables, , drop = FALSE]
}

#' This table's own geographic level positions and (if any) facet name/
#' positions, from its precomputed `classification` (see
#' build_theme_dimension_map()). Returns *positions* (`geo_positions`/
#' `facet_positions`), not just a depth count: a table can have a filler
#' column (see FILLER_LEVEL_REGEX) sitting between its geography and its
#' real facet - e.g. IRCC's "Top 25 Countries of Citizenship" family has
#' Province/Territory (geo, position 1), a literal 1-25 "Country Rank"
#' (filler, position 2), then Country of Citizenship (the real facet,
#' position 3) - so geo_depth can't just be "facet_pos[1] - 1" (that would
#' wrongly count the filler as part of geography); the filler position must
#' be excluded from both the geo and facet position sets entirely, not
#' folded into either.
#'
#' `cl$is_filler` alone isn't trustworthy for a *generic-fallback* label
#' (GENERIC_FALLBACK_LABEL_REGEX, app/R/app_utils.R), though: it's set purely
#' from label text, and that same fallback text also appears whenever a
#' table's title under-names how deep its row hierarchy actually nests -
#' e.g. a title reading "... and Program" when the source data splits
#' "Program" across 4 real nested sub-levels (see
#' reports/database_coverage_report.qmd #2.4, temporary_workers/520ac8e1). A
#' label-only filler check can't tell that case apart from genuine empty
#' padding, so a *generic-fallback* position is re-checked against the real
#' data (level_has_real_data(), app/R/app_utils.R) before being trusted as
#' filler - a populated "Category Level N" column is treated as a real facet
#' position instead, keeping its generic label rather than dropping the data
#' it holds. Other filler patterns (e.g. "... Rank" - a purely ordinal
#' position column, real numbers but not a real category) are deliberately
#' NOT reconsidered this way: unlike a generic fallback, holding real data
#' doesn't make a rank column a real breakdown, so it must stay excluded from
#' this override or it would wrongly resurface as a facet (as it did before
#' this distinction existed - see FILLER_LEVEL_REGEX's own comment).
table_shape <- function(cl, con, table_id) {
  really_filler <- really_filler_levels(cl, con, table_id)

  geo_positions <- which(!is.na(cl$geo_rank))
  facet_positions <- which(is.na(cl$geo_rank) & !really_filler)
  geo_depth <- length(geo_positions)
  geo_rank <- if (geo_depth > 0) utils::tail(cl$geo_rank[geo_positions], 1) else NA_character_
  if (length(facet_positions) == 0) {
    list(geo_depth = geo_depth, geo_rank = geo_rank, has_facet = FALSE, facet_name = NA_character_,
         n_facet_levels = 0L, geo_positions = geo_positions, facet_positions = integer(0))
  } else {
    list(geo_depth = geo_depth, geo_rank = geo_rank, has_facet = TRUE,
         facet_name = cl$label_normalized[facet_positions[1]],
         n_facet_levels = length(facet_positions),
         geo_positions = geo_positions, facet_positions = facet_positions)
  }
}

#' A table that only ever publishes annual totals (period_month always
#' NA) is redundant for any specific year where some *other* contributing
#' table in the same merge has real monthly data - keeping both would
#' leave two entries for that year at different grains (a real Q1-Q4
#' breakdown from the monthly table, plus an extra whole-year value with
#' no period_quarter/period_month of its own) that don't share an exact
#' merge key, so both survive merge_max() instead of one replacing the
#' other - then rolling up to Quarterly/Monthly granularity sums the real
#' quarters/months *and* that extra whole-year value together, inflating
#' the total (discovered in Study Permit Holders' "All permits (at
#' December 31)": a monthly-published pair of tables (2015-2018) overlaps
#' a decades-long annual-only pair (2000-2024) for exactly those years).
#' Drops an annual-only piece's rows for any period_year where some other
#' piece in the same merge has real month data - keeps it for every other
#' year, where it's the only source available.
prefer_finest_grain <- function(pieces) {
  years_with_month <- unique(unlist(lapply(pieces, function(d) {
    if (any(!is.na(d$period_month))) unique(d$period_year[!is.na(d$period_month)]) else integer(0)
  })))
  if (length(years_with_month) == 0) return(pieces)
  lapply(pieces, function(d) {
    is_annual_only <- !any(!is.na(d$period_month))
    if (is_annual_only) d[!(d$period_year %in% years_with_month), , drop = FALSE] else d
  })
}

#' When a merge_max() candidate set spans >=2 source tables (same facet,
#' geo_level, is_stock) that differ in how many real breakdown levels they
#' each publish - table_facet_leaf_rows()'s padding-collapse only removes
#' non-informative depth *within* one table, it can't make two tables
#' agree when one of them genuinely publishes a real sub-split the other
#' never did at all (found via temporary_workers/520ac8e1 publishing an
#' extra "Unknown International Mobility Program" layer under "Other IMP
#' Participants" that temporary_workers/d5779439, a real sibling for the
#' same "Program" facet, never breaks down further - and again one level
#' up, in roll_up_facet_geo()'s own province-to-national rollup, once
#' 520ac8e1's PT-level rows are summed up and compared against
#' d5779439's already-National rows). Left alone, the deeper table's
#' extra-depth rows and the shallower table's flatter row for the very
#' same real category both survive merge_max()'s key match as different
#' keys - each individually correct, but together double-counting one
#' real total. Raggedness is per-branch, not per-table - the very same
#' table can genuinely split "Agreements" three levels deep while leaving
#' "Other IMP Participants" flat (see table_facet_leaf_rows()'s own
#' padding-collapse comment) - so this checks, for each breakdown_1..N-1
#' parent path shared by >=2 contributing tables, whether every one of
#' those tables has *some* real data at the next level; if even one of
#' them never goes that deep for that specific path, the next level (and
#' everything deeper) is collapsed to NA for that path across every
#' table, so all of them compare at the same granularity for that branch
#' specifically before the max-merge below runs. This sacrifices a richer
#' sibling's extra depth for that one branch once merged with a shallower
#' one, but that's the right trade: an extra drill-down layer isn't worth
#' a doubled total. A no-op whenever there's only one contributing table,
#' or no breakdown columns at all (the facet="Total" merges in this
#' script never have breakdown columns).
roll_up_to_common_breakdown_depth <- function(combined) {
  bcols <- intersect(paste0("breakdown_", seq_len(MAX_BREAKDOWN_LEVELS)), names(combined))
  if (length(bcols) == 0 || !("source_table_id" %in% names(combined))) return(combined)
  if (length(unique(combined$source_table_id)) < 2) return(combined)

  branch_key <- function(x, cols) do.call(paste, c(x[cols], sep = "␟"))

  for (i in length(bcols):2) {
    parent_cols <- bcols[seq_len(i - 1)]
    col <- bcols[i]
    per_table_depth <- combined |>
      group_by(across(all_of(c(parent_cols, "source_table_id")))) |>
      summarise(has_depth = any(!is.na(.data[[col]])), .groups = "drop")
    shallow_branches <- per_table_depth |>
      group_by(across(all_of(parent_cols))) |>
      summarise(all_have_depth = all(.data$has_depth), n_tables = dplyr::n(), .groups = "drop") |>
      filter(.data$n_tables >= 2, !.data$all_have_depth) |>
      select(all_of(parent_cols))
    if (nrow(shallow_branches) == 0) next
    is_shallow <- branch_key(combined, parent_cols) %in% branch_key(shallow_branches, parent_cols)
    for (j in i:length(bcols)) combined[[bcols[j]]][is_shallow] <- NA_character_
  }

  # Nulling levels above can create duplicate rows within the same table
  # (several deeper values collapsing onto the same shallower key) that
  # must be summed back together before merge_max()'s own cross-table
  # max-merge runs.
  group_cols <- setdiff(names(combined), "value")
  combined |>
    group_by(across(all_of(group_cols))) |>
    summarise(value = sum(.data$value, na.rm = TRUE), .groups = "drop")
}

#' Merge candidate rows (one data.frame per contributing table, each with a
#' `source_table_id` column already attached) down to one row per distinct
#' key column set, keeping the row with the largest `value` - "least
#' suppressed sibling wins" (see this script's header comment). Rolls
#' sibling tables of differing breakdown depth to a common depth first -
#' see roll_up_to_common_breakdown_depth().
merge_max <- function(pieces, key_cols) {
  pieces <- pieces[vapply(pieces, function(d) !is.null(d) && nrow(d) > 0, logical(1))]
  if (length(pieces) == 0) return(NULL)
  combined <- bind_rows(pieces) |> filter(!is.na(.data$value))
  if (nrow(combined) == 0) return(NULL)
  combined <- roll_up_to_common_breakdown_depth(combined)
  combined |>
    group_by(across(all_of(key_cols))) |>
    slice_max(order_by = .data$value, n = 1, with_ties = FALSE) |>
    ungroup()
}

#' table_geo_subtotals() returns level_1..level_idx as geo_1..geo_idx, which
#' assumes every level above the geography is itself geographic. Some tables
#' nest places under a category instead - "Asylum Claimants by Claim Office
#' Type, Province/Territory" (Airport/Border/Inland > province) or the "Top 25
#' Countries of Citizenship" family (country > province) - and those
#' categories leaked into the geo columns, so each province appeared once per
#' office type alongside its real total (double-counted, and listed three
#' times in the Geographic unit picker). Here any non-geographic level above
#' the geography is summed out, leaving one candidate total per place that
#' merge_max() then weighs against the series' other tables as usual.
sum_out_non_geo_levels <- function(d, cl, idx) {
  if (idx < 1) return(d)
  ranks <- cl$geo_rank[match(seq_len(idx), cl$level_index)]
  non_geo <- which(is.na(ranks))
  if (length(non_geo) == 0) return(d)
  keep <- setdiff(seq_len(idx), non_geo)
  d <- d[, setdiff(names(d), paste0("geo_", non_geo)), drop = FALSE]
  names(d)[match(paste0("geo_", keep), names(d))] <- paste0("geo_", seq_along(keep))
  geo_cols <- paste0("geo_", seq_along(keep))
  d |>
    group_by(across(all_of(c(geo_cols, "period_year", "period_quarter", "period_month")))) |>
    summarise(value = if (all(is.na(.data$value))) NA_real_ else sum(.data$value, na.rm = TRUE), .groups = "drop")
}

build_total_rows <- function(members, geo_rank, geo_level_idx_lookup) {
  # geo_rank is "National" (geo_level_idx 0, every member qualifies) or one
  # of PT/CMA/CD/CSD (only members whose own geo_ranks include it)
  pieces <- lapply(seq_len(nrow(members)), function(i) {
    m <- members[i, ]
    if (identical(geo_rank, "National")) {
      idx <- 0L
    } else {
      if (!(geo_rank %in% unlist(m$geo_ranks))) return(NULL)
      idx <- geo_level_idx_lookup(m$classification[[1]], geo_rank)
    }
    d <- table_geo_subtotals(con, m$table_id, idx, m$has_month, isTRUE(m$is_stock))
    if (nrow(d) == 0) return(NULL)
    d <- sum_out_non_geo_levels(d, m$classification[[1]], idx)
    d$source_table_id <- m$table_id
    d$is_stock <- isTRUE(m$is_stock)
    d
  })
  pieces <- purrr::compact(pieces)
  if (length(pieces) == 0) return(NULL)

  geo_cols <- if (identical(geo_rank, "National")) character(0) else {
    max_depth <- max(vapply(pieces, function(d) sum(grepl("^geo_", names(d))), integer(1)))
    paste0("geo_", seq_len(max_depth))
  }
  # pad any missing geo_N columns (siblings can differ in depth for the
  # same rank - shouldn't happen for PT itself, but keep this safe)
  pieces <- lapply(pieces, function(d) {
    for (col in geo_cols) if (!(col %in% names(d))) d[[col]] <- NA_character_
    d
  })

  pieces <- prefer_finest_grain(pieces)

  # is_stock must partition the merge - a stock (point-in-time) value and
  # a flow (period total) value are different quantities and must never
  # be merged into the same cell even if they happen to share a period
  by_stock <- split(pieces, vapply(pieces, function(d) unique(d$is_stock)[1], logical(1)))
  out <- lapply(by_stock, function(grp) {
    merge_max(grp, c(geo_cols, "period_year", "period_quarter", "period_month"))
  })
  out <- bind_rows(purrr::compact(out))
  if (nrow(out) == 0) return(NULL)

  out$geo_level <- geo_rank
  out$facet <- "Total"
  out$breakdown_1 <- NA_character_
  out$breakdown_2 <- NA_character_
  out$breakdown_3 <- NA_character_
  for (i in 1:3) {
    col <- paste0("geo_", i)
    if (!(col %in% names(out))) out[[col]] <- NA_character_
  }
  out
}

#' Roll a facet's own PT/CD/CSD-level rows up to every coarser level in
#' GEO_HIERARCHY (summed - see that constant's comment for why this is safe
#' for PT/CD/CSD but never for CMA). Run AFTER the max-merge across sibling
#' tables at each geo_level, so a rollup sums the series' own canonical,
#' already-deduplicated entity values, not a single raw table's own
#' (possibly more-suppressed) figures. Rolled-up rows are then merged with
#' whatever the series already has directly at that coarser level (same
#' "largest value wins" rule as everywhere else in this script), in case
#' some sibling table already publishes that coarser breakdown outright -
#' the rollup is a candidate value for that cell, not assumed to be the only
#' one.
#'
#' Discovered from a user report: "All admissions" (permanent_residents) had
#' Age Group/Gender/Immigration Category/Intended Occupation only at PT, and
#' Country of Citizenship only at National, with no way to see the PT-only
#' breakdowns nationally even though every one of them sums straightforwardly
#' to a true national figure - "everything available at a smaller geography
#' should be available at a larger one" (the reverse - National-only data
#' appearing at PT - genuinely isn't possible without inventing numbers, so
#' this only ever rolls finer geography up to coarser, never the other way).
roll_up_facet_geo <- function(d) {
  present <- intersect(GEO_HIERARCHY, unique(d$geo_level))
  rolled <- list()
  for (gl in present) {
    gl_idx <- match(gl, GEO_HIERARCHY)
    if (gl_idx <= 1) next  # National has nothing coarser to roll into
    src <- d[d$geo_level == gl, , drop = FALSE]
    for (coarser_idx in seq_len(gl_idx - 1)) {
      coarser <- GEO_HIERARCHY[coarser_idx]
      depth <- coarser_idx - 1L  # National = 0, PT = 1, CD = 2
      geo_keep <- if (depth > 0) paste0("geo_", seq_len(depth)) else character(0)
      key_cols <- c(geo_keep, "breakdown_1", "breakdown_2", "breakdown_3",
                    "period_year", "period_quarter", "period_month", "is_stock")
      r <- src |>
        dplyr::group_by(dplyr::across(dplyr::all_of(key_cols))) |>
        dplyr::summarise(value = sum(.data$value, na.rm = TRUE),
                          source_table_id = dplyr::first(.data$source_table_id),
                          .groups = "drop")
      r$geo_level <- coarser
      for (i in 1:3) {
        col <- paste0("geo_", i)
        if (!(col %in% names(r)) || i > depth) r[[col]] <- NA_character_
      }
      rolled[[paste(gl, coarser)]] <- r
    }
  }
  if (length(rolled) == 0) return(d)

  combined <- bind_rows(d, bind_rows(rolled))
  by_geo <- split(combined, combined$geo_level)
  out <- lapply(by_geo, function(sub) {
    geo_cols <- grep("^geo_", names(sub), value = TRUE)
    by_stock <- split(sub, sub$is_stock)
    merge_max(by_stock, c(geo_cols, "breakdown_1", "breakdown_2", "breakdown_3",
                           "period_year", "period_quarter", "period_month"))
  })
  bind_rows(purrr::compact(out))
}

build_facet_rows <- function(members) {
  shapes <- lapply(seq_len(nrow(members)), function(i) {
    table_shape(members$classification[[i]], con, members$table_id[i])
  })
  has_facet <- vapply(shapes, `[[`, logical(1), "has_facet")
  if (!any(has_facet)) return(NULL)

  facet_names <- vapply(shapes, function(s) if (isTRUE(s$has_facet)) s$facet_name else NA_character_,
                         character(1))
  pieces_by_facet <- list()
  for (fname in unique(stats::na.omit(facet_names))) {
    idx_tables <- which(facet_names == fname)
    pieces <- lapply(idx_tables, function(i) {
      m <- members[i, ]
      s <- shapes[[i]]
      d <- table_facet_leaf_rows(con, m$table_id, m$n_levels, s$geo_positions, s$facet_positions, m$has_month,
                                 isTRUE(m$is_stock))
      if (nrow(d) == 0) return(NULL)
      if (s$n_facet_levels > MAX_BREAKDOWN_LEVELS) {
        cli::cli_alert_warning("{m$table_id}: facet '{fname}' has {s$n_facet_levels} levels, capping at {MAX_BREAKDOWN_LEVELS}")
      }
      d$source_table_id <- m$table_id
      d$is_stock <- isTRUE(m$is_stock)
      d$geo_level <- if (s$geo_depth == 0) "National" else s$geo_rank
      d
    })
    pieces <- purrr::compact(pieces)
    if (length(pieces) == 0) next
    # scoped per geo_level - a facet can draw from siblings at different
    # geo levels (e.g. one table's National-only rows plus another's
    # PT-level rows for the same facet), and an annual-only National
    # piece must not be dropped just because an unrelated PT-level
    # sibling happens to have monthly data
    by_geo <- split(pieces, vapply(pieces, function(d) unique(d$geo_level)[1], character(1)))
    pieces <- unlist(lapply(by_geo, prefer_finest_grain), recursive = FALSE)

    by_stock <- split(pieces, vapply(pieces, function(d) unique(d$is_stock)[1], logical(1)))
    merged <- lapply(by_stock, function(grp) {
      key_cols <- c("geo_level", grep("^geo_", names(grp[[1]]), value = TRUE),
                    grep("^breakdown_", names(grp[[1]]), value = TRUE),
                    "period_year", "period_quarter", "period_month")
      merge_max(grp, key_cols)
    })
    merged <- bind_rows(purrr::compact(merged))
    if (nrow(merged) == 0) next
    merged <- roll_up_facet_geo(merged)
    merged$facet <- fname
    pieces_by_facet[[fname]] <- merged
  }
  if (length(pieces_by_facet) == 0) return(NULL)
  bind_rows(pieces_by_facet)
}

geo_level_idx_lookup <- function(cl, geo_rank) {
  cl$level_index[match(geo_rank, cl$geo_rank)]
}

cli::cli_h1("Building series_facts")
# a blank series_label is a valid group too - a table with no distinguishing
# series text still needs its own (theme, "") group like any other
all_series <- unique(dim_map[, c("dataset", "series_label")])

results <- purrr::pmap(all_series, function(dataset, series_label) {
  members <- dim_map[dim_map$dataset == dataset & dim_map$series_label == series_label, , drop = FALSE]

  geo_ranks_present <- unique(unlist(members$geo_ranks))
  total_rows <- lapply(c("National", intersect(GEO_RANKS_ORDER, geo_ranks_present)), function(gr) {
    build_total_rows(members, gr, geo_level_idx_lookup)
  })
  total_rows <- bind_rows(purrr::compact(total_rows))

  facet_rows <- build_facet_rows(members)

  out <- bind_rows(total_rows, facet_rows)
  if (nrow(out) == 0) return(NULL)
  out$theme <- dataset
  out$series <- series_label
  out
}, .progress = "Merging series")

series_facts <- bind_rows(purrr::compact(results))

# period_type: mirrors `facts` - "month" when period_month is populated,
# else "year" (this catalog's tables are always one or the other per row,
# never mixed within a single query result, since each contributing fetch
# was already filtered to has_month's own single period_type_filter)
series_facts$period_type <- ifelse(!is.na(series_facts$period_month), "month", "year")

#' IRCC changes capitalisation and spacing between years ("Study level not
#' stated" / "Study Level not stated", "Province/territory not stated" /
#' "Province / Territory not stated"), which split one category into two
#' legend entries across a multi-year chart (docs/data-audit-2026-10-18.md,
#' finding D). Within a theme, labels that differ only by letter case or
#' whitespace are unified to the spelling used in the most recent year.
#' Accents and punctuation still distinguish labels - "Saint-Simon" and
#' "Saint-Siméon", "St. Mary's" and "St. Marys" are different places.
unify_spellings <- function(sf, cols) {
  for (col in cols) {
    vals <- sf[!is.na(sf[[col]]), c("theme", col, "period_year")]
    names(vals)[2] <- "label"
    canon <- vals |>
      mutate(key = tolower(gsub("\\s+", "", .data$label))) |>
      group_by(.data$theme, .data$key, .data$label) |>
      summarise(last_year = max(.data$period_year), n = n(), .groups = "drop") |>
      group_by(.data$theme, .data$key) |>
      filter(n_distinct(.data$label) > 1) |>
      arrange(desc(.data$last_year), desc(.data$n), .by_group = TRUE) |>
      mutate(canonical = first(.data$label)) |>
      ungroup() |>
      filter(.data$label != .data$canonical)
    if (nrow(canon) == 0) next
    cli::cli_alert_info("{col}: unified {nrow(canon)} spelling variant(s), e.g. '{canon$label[1]}' -> '{canon$canonical[1]}'")
    idx <- match(paste(sf$theme, sf[[col]]), paste(canon$theme, canon$label))
    sf[[col]][!is.na(idx)] <- canon$canonical[idx[!is.na(idx)]]
  }
  sf
}
series_facts <- unify_spellings(series_facts, c("geo_1", "geo_2", "geo_3", "breakdown_1", "breakdown_2", "breakdown_3"))

# Two sibling tables can report the same cell under different spellings
# (e.g. 5582034d's "Province/Territory not stated" and 2aa5b7eb's
# "Province/territory not stated"), which merge_max() couldn't match, so
# both were kept and the cell counted twice. Now that spellings agree,
# resolve them by the same rule as every other sibling merge: keep the
# larger value.
key_cols <- c("theme", "series", "facet", "geo_level", "geo_1", "geo_2", "geo_3", "breakdown_1", "breakdown_2",
              "breakdown_3", "period_type", "period_year", "period_quarter", "period_month")
row_key <- do.call(paste, c(lapply(series_facts[key_cols], function(x) ifelse(is.na(x), "\u0001", x)), sep = "\u241f"))
in_dup <- row_key %in% row_key[duplicated(row_key)]
if (any(in_dup)) {
  resolved <- series_facts[in_dup, , drop = FALSE] |>
    group_by(across(all_of(key_cols))) |>
    slice_max(order_by = .data$value, n = 1, with_ties = FALSE) |>
    ungroup()
  cli::cli_alert_info("Merged {sum(in_dup) - nrow(resolved)} row(s) that were the same cell spelled two ways (kept the larger value)")
  series_facts <- bind_rows(series_facts[!in_dup, , drop = FALSE], resolved)
}

# Where a cell has monthly rows through December, an annual row for the
# same cell and year is redundant: for a stock series the Monthly view showed it as an
# extra point among the months, and for a flow it would be counted twice in
# the Annual view. Seen only for "All permits (at December 31)" by country,
# where a province-to-national rollup added monthly rows beside a table's
# own year-end figures (docs/data-audit-2026-10-18.md, finding E).
cell_key <- do.call(paste, c(lapply(series_facts[c("theme", "series", "facet", "geo_level", "geo_1", "geo_2", "geo_3",
                                                   "breakdown_1", "breakdown_2", "breakdown_3", "period_year")],
                                   function(x) ifelse(is.na(x), "\u0001", x)), sep = "\u241f"))
# Only when the monthly rows reach December: a year whose monthly series
# stops early (e.g. "valid permit" months that end in August 2018) keeps its
# year-end figure.
redundant_year <- series_facts$period_type == "year" &
  cell_key %in% cell_key[series_facts$period_type == "month" & series_facts$period_month %in% 12]
if (any(redundant_year)) {
  cli::cli_alert_info("Dropped {sum(redundant_year)} annual row(s) that duplicate monthly rows for the same cell and year")
  series_facts <- series_facts[!redundant_year, , drop = FALSE]
}

# The spelling unification above must never make two rows share a key.
dupes <- series_facts |>
  count(theme, series, facet, geo_level, geo_1, geo_2, geo_3, breakdown_1, breakdown_2, breakdown_3,
        period_type, period_year, period_quarter, period_month) |>
  filter(n > 1)
if (nrow(dupes) > 0) {
  print(as.data.frame(dupes |> count(theme, series, facet, geo_level, period_type, name = "n_keys")))
  print(as.data.frame(head(dupes, 8)))
  stop(nrow(dupes), " duplicate series_facts keys after clean-up")
}

series_facts <- series_facts |>
  select(theme, series, facet, breakdown_1, breakdown_2, breakdown_3,
         geo_level, geo_1, geo_2, geo_3,
         period_type, period_year, period_quarter, period_month,
         value, is_stock, source_table_id)

dbDisconnect(con, shutdown = TRUE)

con2 <- dbConnect(duckdb(), DB_PATH, read_only = FALSE)
dbWriteTable(con2, "series_facts", series_facts, overwrite = TRUE)
dbExecute(con2, "CREATE INDEX idx_series_facts_theme_series ON series_facts(theme, series)")
dbDisconnect(con2, shutdown = TRUE)

cli::cli_alert_success("Wrote {format(nrow(series_facts), big.mark = ',')} rows to series_facts ({length(unique(paste(series_facts$theme, series_facts$series)))} theme/series pairs)")
