# Extends permanent_residents / "All admissions" back to 2000 with IRCC's
# "Specialized Research Datasets: Permanent Residents – Ad Hoc" extracts:
# https://open.canada.ca/data/en/dataset/970ff3c4-50fd-4eeb-b402-f82f9ee22990
#
# Five tidy CSVs (count, landing year, label...), national only, 2000-2016,
# randomly rounded to 5 with "--" for 1-4 - the same conventions as the
# Monthly IRCC Updates. They were extracted once (2017) and are never
# updated, so they bypass 01-08 like 09b's StatCan table. This script
# writes, for 2000-2014 only (2015 on comes from the monthly tables):
#  - series_facts rows (period_type 'year') for the Total (National and
#    PT), Immigration Category, Age Group, Gender and Country of
#    Citizenship facets, replacing any it wrote before,
#  - a category_translations row for the one label the post-2015 data
#    doesn't have (source "pre2015"),
#  - app/data/pre2015_sources.csv, in source_manifest.csv's format, which
#    10_export_web.R adds to sources.json.
#
# The files' 2015 figures are compared with the monthly tables' 2015 totals
# first, and the script stops if they disagree, so the two only meet where
# they line up. Labels are mapped explicitly onto the post-2015 ones; a
# label with no mapping is an error, not a new category.
#
# 08_build_series_facts.R rewrites series_facts and 09_build_translations.R
# rewrites category_translations, so run this after both (and after 09b,
# before 10_export_web.R). Run from the project root.

library(DBI)
library(duckdb)
library(dplyr)

DB_PATH <- "app/data/immigration.duckdb"
DATASET_ID <- "970ff3c4-50fd-4eeb-b402-f82f9ee22990"
THEME <- "permanent_residents"
SERIES <- "All admissions"
LAST_YEAR <- 2014L
DOWNLOAD_DIR <- "data-raw/downloads/pre2015"
SOURCES_CSV <- "app/data/pre2015_sources.csv"
# CSV file -> the facet it feeds
FILES <- c(IRCC_AdhocSR_PR_0001_E.csv = "Age Group",
           IRCC_AdhocSR_PR_0004_E.csv = "Country of Citizenship",
           IRCC_AdhocSR_PR_0006_E.csv = "Gender",
           IRCC_AdhocSR_PR_0007_E.csv = "Immigration Category",
           IRCC_AdhocSR_PR_0011_E.csv = "Total")

if (!file.exists(DB_PATH)) stop("app/data/immigration.duckdb not found - run data-raw/05 through 09 first")
dir.create(DOWNLOAD_DIR, recursive = TRUE, showWarnings = FALSE)

# ---- download (once: the dataset is frozen) ----------------------------------
ua <- "canadian-immigration-statistics ingest pipeline"
pkg <- httr2::request("https://open.canada.ca/data/api/action/package_show") |>
  httr2::req_url_query(id = DATASET_ID) |>
  httr2::req_user_agent(ua) |>
  httr2::req_retry(max_tries = 3) |>
  httr2::req_perform() |>
  httr2::resp_body_json()
resources <- pkg$result$resources |>
  purrr::map(\(r) tibble::tibble(resource_id = r$id, url = r$url, file = basename(r$url),
                                 table_name = r$name_translated$en, format = r$format,
                                 last_modified_ckan = if (is.null(r$last_modified)) r$created else r$last_modified)) |>
  bind_rows() |>
  filter(file %in% names(FILES))
stopifnot(setequal(resources$file, names(FILES)))

for (i in seq_len(nrow(resources))) {
  path <- file.path(DOWNLOAD_DIR, resources$file[i])
  if (file.exists(path)) next
  httr2::request(resources$url[i]) |> httr2::req_user_agent(ua) |> httr2::req_retry(max_tries = 3) |>
    httr2::req_perform(path = path)
  cli::cli_alert_success("Downloaded {resources$file[i]}")
}
resources <- resources |>
  mutate(facet = unname(FILES[file]),
         source_table_id = sprintf("%s/%s__%s", THEME, substr(resource_id, 1, 8),
                                   gsub("[^a-z0-9]+", "_", tolower(sub(" - 2000 - 2016$", "", table_name)))))

read_sr <- function(file) {
  # Latin-1; two files start with a byte-order mark and name the count column differently
  d <- readr::read_csv(file.path(DOWNLOAD_DIR, file), col_types = readr::cols(.default = "c"),
                       locale = readr::locale(encoding = "latin1"))
  names(d) <- c("value", "year", paste0("label_", seq_len(ncol(d) - 2)))
  d |> mutate(value = suppressWarnings(as.numeric(value)), year = as.integer(year),
              across(starts_with("label_"), trimws))
}

# ---- label maps: pre-2015 text -> the post-2015 label ------------------------
NOT_STATED <- c(`Age Group` = "Age not stated", Gender = "Gender not stated",
                Total = "Province/Territory not stated")
CITIZENSHIP <- c("United Kingdom and Colonies" = "United Kingdom and Overseas Territories",
                 "Hong Kong" = "Hong Kong SAR",
                 "Macau" = "Macau SAR",
                 "Not stated" = "Country not stated",
                 "Solomons, The" = "Solomon Islands",
                 "Soloman Islands" = "Solomon Islands")
# Only ever zero in these files, and gone from the post-2015 list.
CITIZENSHIP_ZERO <- c("Panama Canal Zone", "Pitcairn Island")
# The one category the post-2015 data has no equivalent for (2002-2014),
# kept as a Sponsored Family component of its own. French: IRCC's own label.
HC_FAMILY <- c(en = "Sponsored Family Member - H&C Consideration", fr = "Membres de la famille parrainés - CH")

#' The post-2015 Immigration Category hierarchy (after 08's padding
#' collapse): Sponsored Family's pass-through "Sponsored Family" group is
#' removed, Provincial Nominee Program and Protected Person in Canada stop
#' at the group, and All Other Immigration at the top level.
map_category <- function(d) {
  d |>
    transmute(value, year, b1 = label_1, b2 = label_2, b3 = label_3) |>
    mutate(
      b2 = case_when(b1 == "Sponsored Family" ~ b3, b1 == "All Other Immigration" ~ NA_character_, .default = b2),
      b3 = case_when(b1 == "Sponsored Family" | b1 == "All Other Immigration" ~ NA_character_,
                     b2 %in% c("Provincial Nominee Program", "Protected Person in Canada") ~ NA_character_,
                     .default = b3)
    )
}

# ---- build rows ---------------------------------------------------------------
facet_rows <- function(file) {
  d <- read_sr(file)
  facet <- unname(FILES[file])
  out <- switch(facet,
    "Immigration Category" = map_category(d),
    "Country of Citizenship" = d |>
      filter(!label_1 %in% CITIZENSHIP_ZERO) |>
      transmute(value, year, b1 = coalesce(CITIZENSHIP[label_1], label_1), b2 = NA_character_, b3 = NA_character_),
    d |> transmute(value, year, b1 = ifelse(label_1 == "Not stated", NOT_STATED[[facet]], label_1),
                   b2 = NA_character_, b3 = NA_character_)
  )
  out |> mutate(facet = facet, source_table_id = resources$source_table_id[resources$file == file])
}
all_years <- bind_rows(lapply(names(FILES), facet_rows))

con <- dbConnect(duckdb(), DB_PATH)
on.exit(dbDisconnect(con, shutdown = TRUE), add = TRUE)

# Every label must already exist in the post-2015 facet, in any of the
# theme's series (the H&C component aside): the whole path for Immigration
# Category, the top level elsewhere (post-2015 citizenship rows are split
# further, by category). "Other Countries", for one, is only in the
# Francophone series after 2015.
existing <- dbGetQuery(con, "
  SELECT DISTINCT facet, coalesce(breakdown_1, geo_1) AS b1,
         CASE WHEN facet = 'Immigration Category' THEN breakdown_2 END AS b2,
         CASE WHEN facet = 'Immigration Category' THEN breakdown_3 END AS b3
  FROM series_facts WHERE theme = ? AND period_type = 'month'
    AND (facet <> 'Total' OR geo_level = 'PT')", params = list(THEME))
unmatched <- all_years |>
  filter(year <= LAST_YEAR, !is.na(value), value != 0) |>
  distinct(facet, b1, b2, b3) |>
  filter(!(facet == "Immigration Category" & b2 %in% HC_FAMILY[["en"]])) |>
  anti_join(existing, by = c("facet", "b1", "b2", "b3"))
if (nrow(unmatched) > 0) {
  print(unmatched)
  stop("pre-2015 labels with no post-2015 match - map them in 09c_add_pre2015.R")
}

# ---- check the splice: 2015 in these files vs the monthly tables -------------
# Each file's total within 2% of the published 2015 total; categories with
# 5,000+ admissions within 10% (the files are a 2017 extract, the monthly
# tables current, and both rounded). Smaller categories, and the facets'
# own sums, aren't compared: the monthly citizenship figures come from
# country x category x month cells, so many small ones are suppressed
# (their 2015 sum is 4% under the total, Ethiopia's 13%).
db_2015 <- dbGetQuery(con, "
  SELECT facet, coalesce(breakdown_1, geo_1) AS b1, sum(value) AS db
  FROM series_facts
  WHERE theme = ? AND series = ? AND period_year = 2015 AND period_type = 'month'
    AND ((facet = 'Total' AND geo_level = 'PT') OR (facet <> 'Total' AND geo_level = 'National'))
  GROUP BY ALL", params = list(THEME, SERIES))
check <- all_years |>
  filter(year == 2015) |>
  group_by(facet, b1) |>
  summarise(sr = sum(value, na.rm = TRUE), .groups = "drop") |>
  inner_join(db_2015, by = c("facet", "b1"))
published <- sum(db_2015$db[db_2015$facet == "Total"])
totals <- all_years |> filter(year == 2015) |> group_by(facet) |>
  summarise(sr = sum(value, na.rm = TRUE), .groups = "drop") |>
  mutate(db = published, rel = abs(sr - db) / db)
big <- check |> filter(db >= 5000) |> mutate(rel = abs(sr - db) / db)
cli::cli_alert_info("2015 overlap: totals within {round(100 * max(totals$rel), 2)}%, largest category gap {round(100 * max(big$rel), 1)}%")
if (any(totals$rel > 0.02) || any(big$rel > 0.10)) {
  print(totals)
  print(big |> filter(rel > 0.10))
  stop("pre-2015 files don't line up with the monthly tables in 2015")
}

# ---- series_facts rows --------------------------------------------------------
pre <- all_years |>
  filter(year <= LAST_YEAR, !is.na(value), value != 0) |>
  group_by(facet, b1, b2, b3, year, source_table_id) |>
  summarise(value = sum(value), .groups = "drop")
national_total <- pre |>
  filter(facet == "Total") |>
  group_by(facet, year, source_table_id) |>
  summarise(value = sum(value), .groups = "drop")
rows <- bind_rows(
  pre |> filter(facet == "Total") |>
    transmute(facet, breakdown_1 = NA_character_, breakdown_2 = NA_character_,
              geo_level = "PT", geo_1 = b1, year, value, source_table_id),
  national_total |> transmute(facet, breakdown_1 = NA_character_, breakdown_2 = NA_character_,
                              geo_level = "National", geo_1 = NA_character_, year, value, source_table_id),
  pre |> filter(facet != "Total") |>
    transmute(facet, breakdown_1 = b1, breakdown_2 = b2, breakdown_3 = b3,
              geo_level = "National", geo_1 = NA_character_, year, value, source_table_id)
) |>
  transmute(theme = THEME, series = SERIES, facet, breakdown_1, breakdown_2, breakdown_3,
            geo_level, geo_1, geo_2 = NA_character_, geo_3 = NA_character_,
            period_type = "year", period_year = year, period_quarter = NA_integer_, period_month = NA_integer_,
            value, is_stock = FALSE, source_table_id)

cols <- dbListFields(con, "series_facts")
stopifnot(setequal(cols, names(rows)))
invisible(dbExecute(con, sprintf("DELETE FROM series_facts WHERE source_table_id IN (%s)",
                                 paste(DBI::dbQuoteString(con, resources$source_table_id), collapse = ", "))))
dbAppendTable(con, "series_facts", rows[, cols])

# ---- French label for the one new category ------------------------------------
invisible(dbExecute(con, "DELETE FROM category_translations WHERE source = 'pre2015'"))
dbAppendTable(con, "category_translations", tibble::tibble(
  en_text = HC_FAMILY[["en"]], context = "breakdown_2", table_id = NA_character_,
  fr_text = HC_FAMILY[["fr"]], source = "pre2015"
)[, dbListFields(con, "category_translations")])

# ---- citation records, in source_manifest.csv's format -----------------------
readr::write_csv(resources |> transmute(
  dataset = THEME, dataset_id = DATASET_ID, resource_id,
  table_key = tolower(table_name), table_name, format, url, last_modified_ckan
), SOURCES_CSV)

cli::cli_alert_success(
  "{THEME} 2000-{LAST_YEAR}: {nrow(rows)} series_facts rows across {n_distinct(rows$facet)} facets")
