# Adds the "Non-Permanent Resident Population" theme (npr_population) to
# app/data/immigration.duckdb from Statistics Canada table 17-10-0121-01,
# "Estimates of the number of non-permanent residents by type, quarterly":
# https://www150.statcan.gc.ca/t1/tbl1/en/tv.action?pid=1710012101
#
# Unlike every other theme this one isn't an IRCC/IRB file on the Open
# Government Portal, so it bypasses 01-08 entirely: this script downloads the
# table's full English and French CSVs, and writes
#  - series_facts rows for theme npr_population (any existing ones replaced),
#  - category_translations rows for its breakdown labels (source "statcan"),
#  - app/data/statcan_sources.csv, the citation record 10_export_web.R adds
#    to sources.json.
#
# 08_build_series_facts.R rewrites series_facts and 09_build_translations.R
# rewrites category_translations, so run this after both (and before
# 10_export_web.R) whenever either has been re-run. Run from the project root.
#
# The data: Canada and each province/territory, quarterly from July 1, 2021.
# Each estimate is a point-in-time count (a stock). StatCan dates them to the
# first day of a quarter; here each is stored as the last month of the
# quarter before (July 1, 2026 -> June 2026, January 1, 2026 -> December
# 2025), so a year's figure is its December 31 / January 1 count - the same
# convention as IRCC's "on December 31" permit-holder stocks - and the app's
# stock rule (the latest month in each period) picks the right quarter.
# Types are mutually exclusive and add up exactly to their group totals, and
# provinces to Canada, so only leaf types are stored (the app sums them).

library(DBI)
library(duckdb)
library(dplyr)

DB_PATH <- "app/data/immigration.duckdb"
PID <- "17100121"
THEME <- "npr_population"
SERIES <- "All non-permanent residents"
FACET <- "Non-Permanent Resident Type"
TABLE_ID <- sprintf("%s/%s__estimates_of_the_number_of_non_permanent_residents_by_type_quarterly", THEME, PID)
DOWNLOAD_DIR <- "data-raw/downloads/statcan"
SOURCES_CSV <- "app/data/statcan_sources.csv"

if (!file.exists(DB_PATH)) stop("app/data/immigration.duckdb not found - run data-raw/05 through 09 first")
dir.create(DOWNLOAD_DIR, recursive = TRUE, showWarnings = FALSE)

# ---- download (skipped when StatCan's release time hasn't changed) ----------
ua <- "canadian-immigration-statistics ingest pipeline"
meta <- httr2::request("https://www150.statcan.gc.ca/t1/wds/rest/getCubeMetadata") |>
  httr2::req_user_agent(ua) |>
  httr2::req_body_json(list(list(productId = as.integer(PID)))) |>
  httr2::req_retry(max_tries = 3) |>
  httr2::req_perform() |>
  httr2::resp_body_json()
meta <- meta[[1]]$object
release_time <- meta$releaseTime

zip_path <- function(lang) file.path(DOWNLOAD_DIR, sprintf("%s-%s.zip", PID, lang))
previous <- if (file.exists(SOURCES_CSV)) readr::read_csv(SOURCES_CSV, show_col_types = FALSE, col_types = readr::cols(.default = "c")) else NULL
unchanged <- !is.null(previous) && identical(previous$release_time[1], release_time) &&
  all(file.exists(zip_path(c("eng", "fra"))))
if (unchanged) {
  cli::cli_alert_info("StatCan {PID}: release {release_time} unchanged, using the downloaded copy")
} else {
  for (lang in c("eng", "fra")) {
    httr2::request(sprintf("https://www150.statcan.gc.ca/n1/tbl/csv/%s-%s.zip", PID, lang)) |>
      httr2::req_user_agent(ua) |>
      httr2::req_retry(max_tries = 3) |>
      httr2::req_perform(path = zip_path(lang))
  }
  cli::cli_alert_success("StatCan {PID}: downloaded release {release_time}")
}

read_table <- function(lang) {
  # English is comma-separated; French uses ";" (with "," as decimal mark)
  file <- unzip(zip_path(lang), files = sprintf("%s.csv", PID), exdir = tempdir())
  delim <- if (lang == "eng") "," else ";"
  d <- readr::read_delim(file, delim = delim, show_col_types = FALSE,
                         col_types = readr::cols(.default = "c"), locale = readr::locale(encoding = "UTF-8"))
  names(d)[c(1, 2, 4, 10, 11)] <- c("ref_date", "geo", "type", "coordinate", "value")
  d
}
en <- read_table("eng")
fr <- read_table("fra")

# ---- labels: StatCan member (coordinate 1.<member>) -> breakdown_1/2 --------
# Shortened from StatCan's member names, which repeat the group in every type.
# "Other" is renamed: the app reserves it for the top-N catch-all bucket.
ASYLUM <- c(en = "Asylum claimants, protected persons and related groups",
            fr = "Demandeurs d'asile, personnes protégées et groupes apparentés")
PERMIT <- c(en = "Permit holders and their family members",
            fr = "Titulaires de permis et membres de leur famille")
TYPES <- tibble::tribble(
  ~member, ~b1,  ~b2_en,                            ~b2_fr,
  "3",  "asylum", "With work permit only",          "Avec permis de travail seulement",
  "4",  "asylum", "With study permit only",         "Avec permis d'études seulement",
  "5",  "asylum", "With work and study permits",    "Avec permis de travail et d'études",
  "6",  "asylum", "Without work or study permits",  "Sans permis de travail ou d'études",
  "8",  "permit", "Work permit holders only",       "Titulaires de permis de travail seulement",
  "9",  "permit", "Study permit holders only",      "Titulaires de permis d'études seulement",
  "10", "permit", "Work and study permit holders",  "Titulaires de permis de travail et d'études",
  "11", "permit", "Other (mainly family members)",  "Autres (surtout des membres de la famille)"
) |>
  mutate(b1_en = ifelse(b1 == "asylum", ASYLUM[["en"]], PERMIT[["en"]]),
         b1_fr = ifelse(b1 == "asylum", ASYLUM[["fr"]], PERMIT[["fr"]]))

# The French file must describe the same members, in the same places.
stopifnot(identical(en$coordinate, fr$coordinate), identical(en$value, fr$value))

# ---- series_facts rows ------------------------------------------------------
d <- en |>
  mutate(
    member = sub("^\\d+\\.", "", coordinate),
    value = as.numeric(value),
    date = as.Date(ref_date) - 1,  # the day before: the end of the previous quarter
    period_year = as.integer(format(date, "%Y")),
    period_month = as.integer(format(date, "%m")),
    period_quarter = as.integer((period_month - 1) %/% 3 + 1),
    geo_level = ifelse(geo == "Canada", "National", "PT"),
    geo_1 = ifelse(geo == "Canada", NA_character_, geo)
  )
stopifnot(!anyNA(d$value), all(d$period_month %in% c(3L, 6L, 9L, 12L)))

# Check the published hierarchy adds up before storing only its leaves.
wide <- d |> select(ref_date, geo, member, value) |> tidyr::pivot_wider(names_from = member, values_from = value)
stopifnot(with(wide, all(`1` == `2` + `7`, `2` == `3` + `4` + `5` + `6`, `7` == `8` + `9` + `10` + `11`)))
pt_sum <- d |> filter(geo_level == "PT", member == "1") |> group_by(ref_date) |> summarise(v = sum(value))
ca <- d |> filter(geo_level == "National", member == "1") |> select(ref_date, ca = value)
stopifnot(all(inner_join(pt_sum, ca, by = "ref_date") |> mutate(ok = v == ca) |> pull(ok)))

base <- d |> transmute(theme = THEME, series = SERIES, geo_level, geo_1, geo_2 = NA_character_, geo_3 = NA_character_,
                       period_type = "month", period_year, period_quarter, period_month, value,
                       is_stock = TRUE, source_table_id = TABLE_ID, member)
totals <- base |> filter(member == "1") |>
  mutate(facet = "Total", breakdown_1 = NA_character_, breakdown_2 = NA_character_)
types <- base |> inner_join(TYPES, by = "member") |>
  mutate(facet = FACET, breakdown_1 = b1_en, breakdown_2 = b2_en)
rows <- bind_rows(totals, types) |>
  transmute(theme, series, facet, breakdown_1, breakdown_2, breakdown_3 = NA_character_,
            geo_level, geo_1, geo_2, geo_3, period_type, period_year, period_quarter, period_month,
            value, is_stock, source_table_id)

con <- dbConnect(duckdb(), DB_PATH)
on.exit(dbDisconnect(con, shutdown = TRUE), add = TRUE)
# Match series_facts' column order whatever it is.
cols <- dbListFields(con, "series_facts")
stopifnot(setequal(cols, names(rows)))
invisible(dbExecute(con, "DELETE FROM series_facts WHERE theme = ?", params = list(THEME)))
dbAppendTable(con, "series_facts", rows[, cols])

# ---- French labels ------------------------------------------------------------
# Unscoped (table_id NA), like 09's own rows: the web app only reads those.
tr <- bind_rows(
  distinct(TYPES, en_text = b1_en, fr_text = b1_fr) |> mutate(context = "breakdown_1"),
  distinct(TYPES, en_text = b2_en, fr_text = b2_fr) |> mutate(context = "breakdown_2")
) |>
  transmute(en_text, context, table_id = NA_character_, fr_text, source = "statcan")
invisible(dbExecute(con, "DELETE FROM category_translations WHERE source = 'statcan'"))
dbAppendTable(con, "category_translations", tr[, dbListFields(con, "category_translations")])

# ---- citation record ----------------------------------------------------------
readr::write_csv(tibble::tibble(
  hash = PID,
  agency = "Statistics Canada",
  agency_fr = "Statistique Canada",
  table_name = sprintf("Table 17-10-0121-01 %s", meta$cubeTitleEn),
  table_name_fr = sprintf("Tableau 17-10-0121-01 %s", meta$cubeTitleFr),
  format = "CSV",
  url = sprintf("https://www150.statcan.gc.ca/n1/tbl/csv/%s-eng.zip", PID),
  dataset_url = "https://www150.statcan.gc.ca/t1/tbl1/en/tv.action?pid=1710012101",
  dataset_url_fr = "https://www150.statcan.gc.ca/t1/tbl1/fr/tv.action?pid=1710012101",
  updated_at = substr(release_time, 1, 10),
  release_time = release_time,
  data_through = meta$cubeEndDate
), SOURCES_CSV)

cli::cli_alert_success(
  "{THEME}: {nrow(rows)} series_facts rows ({min(d$ref_date)} to {max(d$ref_date)}), {nrow(tr)} French labels")
