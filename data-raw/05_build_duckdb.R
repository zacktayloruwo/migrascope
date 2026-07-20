# Load every tidy long table in data/processed/ into a DuckDB database
# (data/immigration.duckdb) for the Shiny app to query: a unified `facts`
# table (see R/duckdb_utils.R for the normalization) plus a `catalog` table
# describing each table's dimensions and available temporal granularities.
#
# Safe to re-run: replaces both tables each time. Takes a few minutes -
# dominated by the same handful of 500k+ row tables as data-raw/04.

library(dplyr)
source("R/duckdb_utils.R")

process_log <- readr::read_csv("data-raw/process_log.csv", show_col_types = FALSE)
manifest <- readr::read_csv("data-raw/manifest.csv", show_col_types = FALSE,
                             col_types = readr::cols(last_modified_ckan = "c"))
hash_to_title <- manifest |>
  mutate(hash = substr(resource_id, 1, 8)) |>
  select(hash, table_name) |>
  distinct(hash, .keep_all = TRUE)

ok_tables <- process_log |> filter(status == "ok")

# rpd_decisions and rpd_1997_2021 are normalized individually below like
# any other table (so their own Province of Residence / Country of
# Persecution breakdowns stay browsable), *and* combined into one extra
# "by Outcome, 1997-2026" table - see R/duckdb_utils.R::build_refugees_table().
# All three end up under the "refugees" dataset/theme (relabeled below)
# since geography aside, they're the same subject.
refugee_source_slugs <- ok_tables |>
  filter(dataset %in% c("rpd_decisions", "rpd_1997_2021")) |>
  select(dataset, slug) |>
  tibble::deframe()

title_for_slug <- function(slug) {
  parts <- strsplit(slug, "__")[[1]]
  hash <- parts[1]
  base_title <- hash_to_title$table_name[match(hash, hash_to_title$hash)]
  if (is.na(base_title)) base_title <- gsub("_", " ", slug)
  if (length(parts) >= 3) {
    sheet_suffix <- tools::toTitleCase(gsub("_", " ", parts[length(parts)]))
    base_title <- paste0(base_title, " — ", sheet_suffix)
  }
  base_title
}

cli::cli_h1("Normalizing {nrow(ok_tables)} tables for DuckDB")

results <- purrr::pmap(ok_tables |> select(dataset, slug), function(dataset, slug) {
  path <- fs::path("data", "processed", dataset, paste0(slug, "_long.csv"))
  table_id <- paste(dataset, slug, sep = "/")
  title <- title_for_slug(slug)

  long <- tryCatch(
    readr::read_csv(path, show_col_types = FALSE,
                     col_types = readr::cols(
                       is_row_subtotal = "l", is_period_subtotal = "l",
                       suppressed = "l", is_percent = "l", value = "d",
                       period_year = "i", period_quarter = "i", period_month = "i",
                       period_label = "c",
                       level_1 = "c", level_2 = "c", level_3 = "c", level_4 = "c", level_5 = "c",
                       row_label_raw = "c"
                     )),
    error = function(e) e
  )
  if (inherits(long, "error")) {
    cli::cli_alert_danger("Could not read {path}: {conditionMessage(long)}")
    return(NULL)
  }
  if ("row_level" %in% names(long)) long$row_level <- as.integer(long$row_level)

  tryCatch(normalize_table(long, table_id, dataset, title), error = function(e) {
    cli::cli_alert_danger("Could not normalize {table_id}: {conditionMessage(e)}")
    NULL
  })
}, .progress = "Normalizing")

results <- lapply(results, function(r) {
  if (!is.null(r) && r$catalog_row$dataset %in% c("rpd_decisions", "rpd_1997_2021")) {
    r$catalog_row$dataset <- "refugees"
  }
  r
})

# A handful of catalog rows have level_N_label fields that don't match the
# real data in `facts` at all - a title-parsing bug in guess_level_labels()
# (see R/duckdb_utils.R) that misattributes which label belongs to which
# column. Confirmed by checking actual distinct values in the affected
# columns, not just title text - e.g. permanent_residents/840a3387's
# level_1_label said "Country of Birth" but level_1's real values were
# Male/Female; level_2_label said "Gender" but level_2's real values were
# country names (a user noticed this live: picking "Break down by = Country
# of Birth" plotted Gender). Corrected here as a targeted, documented
# override rather than fixing guess_level_labels() itself, which would need
# to correctly parse this table's specific source title structure - same
# spirit as the dataset relabel just above.
LEVEL_LABEL_CORRECTIONS <- list(
  "permanent_residents/840a3387__canada_adoptions_via_permanent_residence_fc6_fc9_by_country_" =
    c(level_1_label = "Gender", level_2_label = "Country of Birth")
)

results <- lapply(results, function(r) {
  if (is.null(r)) return(r)
  fix <- LEVEL_LABEL_CORRECTIONS[[r$catalog_row$table_id]]
  if (!is.null(fix)) {
    for (col in names(fix)) r$catalog_row[[col]] <- fix[[col]]
  }
  r
})

if (all(c("rpd_decisions", "rpd_1997_2021") %in% names(refugee_source_slugs))) {
  refugees_result <- tryCatch(
    build_refugees_table(refugee_source_slugs[["rpd_decisions"]], refugee_source_slugs[["rpd_1997_2021"]]),
    error = function(e) {
      cli::cli_alert_danger("Could not build merged refugees table: {conditionMessage(e)}")
      NULL
    }
  )
  results <- c(results, list(refugees_result))
} else {
  cli::cli_alert_warning("rpd_decisions and/or rpd_1997_2021 missing from process_log - skipping refugees merge")
}

results <- purrr::compact(results)

# Genuinely-redundant tables, dropped entirely rather than just hidden by
# the app - each is superseded by a sibling table with the identical
# geography+category signature, the same is_stock, and equal-or-wider year
# coverage (verified against real catalog/facts data, not just title text).
# Not a general dedup mechanism: most same-signature "duplicates" elsewhere
# in the catalog are genuinely different series (stock vs flow, population/
# program subset, or a distinct externally-normalized metric like
# "Percentage of French Speaking..." tables) and must stay independently
# selectable - see the Shiny app's derive_series_label()/
# build_theme_dimension_map() (app/R/app_utils.R).
EXCLUDED_DUPLICATE_TABLE_IDS <- c(
  # superseded by study_permit_holders/d3702eb4 (same PT+Study Level
  # series, 2015-2026 vs this one's narrower 2015-2022)
  "study_permit_holders/5d3a238a__canada_study_permit_holders_by_province_territory_of_intende",
  # superseded by asylum_claimants/450f7e37 (identical PT+Claim Office
  # Type coverage, more detail retained)
  "asylum_claimants/13d02e73__canada_asylum_claimants_by_claim_office_type_province_territ",
  # superseded by asylum_claimants/46bee0ae (same PT+Age series,
  # 2015-2026 vs this one's narrower 2015-2025)
  "asylum_claimants/bdac348b__canada_asylum_claimants_by_province_territory_of_claim_age_a",
  # superseded by asylum_claimants/34c502f9 (identical PT+Gender
  # coverage, more detail retained)
  "asylum_claimants/ec417b64__canada_asylum_claimants_by_province_territory_of_claim_gende",
  # superseded by permanent_residents/81021dfd (identical CMA+PT
  # coverage, more detail retained)
  "permanent_residents/4665647e__canada_permanent_residents_by_province_territory_and_cma"
)
results <- purrr::keep(results, function(r) !(r$catalog_row$table_id %in% EXCLUDED_DUPLICATE_TABLE_IDS))

facts <- purrr::map(results, "facts") |> bind_rows()
catalog <- purrr::map(results, "catalog_row") |> bind_rows()

cli::cli_alert_success("{nrow(catalog)} tables normalized, {format(nrow(facts), big.mark = ',')} total rows")

# Written straight into app/data/ (not data/) - that directory is the
# self-contained Shiny app bundle deployed to shinyapps.io, so its data
# inputs live there rather than being copied over from a top-level data/
# as a separate step.
db_path <- "app/data/immigration.duckdb"
fs::dir_create("app/data")
if (fs::file_exists(db_path)) fs::file_delete(db_path)

con <- DBI::dbConnect(duckdb::duckdb(), db_path)
DBI::dbWriteTable(con, "facts", facts)
DBI::dbWriteTable(con, "catalog", catalog)
DBI::dbExecute(con, "CREATE INDEX idx_facts_table_id ON facts(table_id)")
DBI::dbExecute(con, "CREATE INDEX idx_facts_period_type ON facts(period_type)")
DBI::dbDisconnect(con, shutdown = TRUE)

# app.R's source-citation feature reads a copy of the manifest from its own
# data/ directory rather than reaching into data-raw/ at runtime - keep it
# in sync here, right alongside the duckdb it's cited against.
fs::file_copy("data-raw/manifest.csv", "app/data/source_manifest.csv", overwrite = TRUE)
cli::cli_alert_info("Wrote app/data/source_manifest.csv")

cli::cli_alert_info("Wrote {db_path}")
