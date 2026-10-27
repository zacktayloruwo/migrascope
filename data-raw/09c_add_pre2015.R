# Extends series back before 2015 with IRCC's frozen ad hoc extracts on the
# Open Government Portal (2016-2017; never updated):
#  - Specialized Research Datasets: Permanent Residents (970ff3c4) - five
#    tidy CSVs, annual and national, 2000-2016: permanent_residents /
#    All admissions by Total (National and PT), Immigration Category, Age
#    Group, Gender and Country of Citizenship.
#  - Permanent Residents - Ad Hoc (ad975a26) - the PT x CMA pivot, 2006 on:
#    the same series' Total at CMA level.
#  - Study Permit Holders - Ad Hoc (b813dcb6) - PT x gender and PT x
#    citizenship pivots, 2004 on: study_permit_holders / All permits (Year
#    became effective) by Total (National and PT), Gender (National and PT)
#    and Country of Citizenship (National).
# All are randomly rounded to 5 with "--" for 1-4, like the Monthly IRCC
# Updates, and bypass 01-08 like 09b's StatCan table. This script writes,
# for the years before 2015 only (2015 on comes from the monthly tables):
#  - series_facts rows (period_type 'year'), replacing any it wrote before,
#  - a category_translations row for the one label the post-2015 data
#    doesn't have (source "pre2015"),
#  - app/data/pre2015_sources.csv, in source_manifest.csv's format, which
#    10_export_web.R adds to sources.json.
#
# Each file's 2015 figures are compared with the monthly tables' 2015 totals
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
LAST_YEAR <- 2014L
DOWNLOAD_DIR <- "data-raw/downloads/pre2015"
SOURCES_CSV <- "app/data/pre2015_sources.csv"
PR <- c(theme = "permanent_residents", series = "All admissions")
SP <- c(theme = "study_permit_holders", series = "All permits (Year became effective)")
DATASETS <- c(sr_pr = "970ff3c4-50fd-4eeb-b402-f82f9ee22990",
              adhoc_pr = "ad975a26-df23-456a-8ada-756191a23695",
              adhoc_sp = "b813dcb6-cc08-4e06-97d4-85b7e4daa822")
# file -> dataset, and the theme its rows belong to
FILES <- tibble::tribble(
  ~file,                          ~dataset,    ~theme,
  "IRCC_AdhocSR_PR_0001_E.csv",  "sr_pr",     PR[["theme"]],
  "IRCC_AdhocSR_PR_0004_E.csv",  "sr_pr",     PR[["theme"]],
  "IRCC_AdhocSR_PR_0006_E.csv",  "sr_pr",     PR[["theme"]],
  "IRCC_AdhocSR_PR_0007_E.csv",  "sr_pr",     PR[["theme"]],
  "IRCC_AdhocSR_PR_0011_E.csv",  "sr_pr",     PR[["theme"]],
  "IRCC_PRadmiss_0011_E.xls",    "adhoc_pr",  PR[["theme"]],
  "IRCC_IS_0006_E.csv",          "adhoc_sp",  SP[["theme"]],
  "IRCC_IS_0009_E.csv",          "adhoc_sp",  SP[["theme"]]
)

if (!file.exists(DB_PATH)) stop("app/data/immigration.duckdb not found - run data-raw/05 through 09 first")
dir.create(DOWNLOAD_DIR, recursive = TRUE, showWarnings = FALSE)

# ---- download (once: the datasets are frozen) ---------------------------------
ua <- "canadian-immigration-statistics ingest pipeline"
resources <- lapply(names(DATASETS), function(ds) {
  pkg <- httr2::request("https://open.canada.ca/data/api/action/package_show") |>
    httr2::req_url_query(id = DATASETS[[ds]]) |>
    httr2::req_user_agent(ua) |>
    httr2::req_retry(max_tries = 3) |>
    httr2::req_perform() |>
    httr2::resp_body_json()
  pkg$result$resources |>
    purrr::map(\(r) tibble::tibble(dataset = ds, dataset_id = DATASETS[[ds]], resource_id = r$id, url = r$url,
                                   file = basename(r$url), table_name = trimws(r$name_translated$en), format = r$format,
                                   last_modified_ckan = if (is.null(r$last_modified)) r$created else r$last_modified)) |>
    bind_rows()
}) |>
  bind_rows() |>
  inner_join(FILES, by = c("file", "dataset"))
stopifnot(setequal(resources$file, FILES$file))

for (i in seq_len(nrow(resources))) {
  path <- file.path(DOWNLOAD_DIR, resources$file[i])
  if (file.exists(path)) next
  httr2::request(resources$url[i]) |> httr2::req_user_agent(ua) |> httr2::req_retry(max_tries = 3) |>
    httr2::req_perform(path = path)
  cli::cli_alert_success("Downloaded {resources$file[i]}")
}
resources <- resources |>
  mutate(slug = substr(gsub("^_|_$", "", gsub("[^a-z0-9]+", "_", tolower(sub(" - 2000 - 2016$", "", table_name)))), 1, 90),
         source_table_id = sprintf("%s/%s__%s", theme, substr(resource_id, 1, 8), slug))
source_id <- function(file) resources$source_table_id[resources$file == file]

num <- function(x) suppressWarnings(as.numeric(gsub(",", "", x)))
PROVINCES <- c("Newfoundland and Labrador", "Prince Edward Island", "Nova Scotia", "New Brunswick", "Quebec",
               "Ontario", "Manitoba", "Saskatchewan", "Alberta", "British Columbia", "Yukon",
               "Northwest Territories", "Nunavut")

# ---- readers --------------------------------------------------------------------
#' The research extracts: long CSVs of (count, landing year, label...).
#' Latin-1; two start with a byte-order mark and name the count column differently.
read_sr <- function(file) {
  d <- readr::read_csv(file.path(DOWNLOAD_DIR, file), col_types = readr::cols(.default = "c"),
                       locale = readr::locale(encoding = "latin1"))
  names(d) <- c("value", "year", paste0("label_", seq_len(ncol(d) - 2)))
  d |> mutate(value = num(value), year = as.integer(year), across(starts_with("label_"), trimws))
}

#' A pivot whose second column lists the places/categories of one province,
#' closed by a "<Province> Total" row in the first column. Year columns are
#' the header cells that are a plain year (a trailing "Jan-Mar 2016" is not).
read_blocks <- function(cells, header_row) {
  hdr <- unlist(cells[header_row, ])
  yc <- which(grepl("^(19|20)[0-9]{2}$", hdr))
  out <- list()
  pending <- list()
  for (i in seq(header_row + 1, nrow(cells))) {
    a <- cells[[1]][i]
    b <- cells[[2]][i]
    if (!is.na(b) && nzchar(trimws(b))) {
      pending[[length(pending) + 1]] <- tibble::tibble(label = trimws(b), year = as.integer(hdr[yc]),
                                                        value = num(unlist(cells[i, yc])))
    } else if (!is.na(a) && sub(" Total$", "", trimws(a)) %in% PROVINCES) {
      out[[length(out) + 1]] <- bind_rows(pending) |> mutate(pt = sub(" Total$", "", trimws(a)))
      pending <- list()
    } else if (!is.na(a)) {
      pending <- list()  # "not stated" and grand-total rows have no breakdown of their own
    }
  }
  bind_rows(out)
}
read_csv_cells <- function(file) {
  readr::read_csv(file.path(DOWNLOAD_DIR, file), col_names = FALSE, col_types = readr::cols(.default = "c"),
                  locale = readr::locale(encoding = "latin1"))
}

# ---- label maps: pre-2015 text -> the post-2015 label ------------------------
NOT_STATED <- c(`Age Group` = "Age not stated", Gender = "Gender not stated",
                Total = "Province/Territory not stated")
PR_CITIZENSHIP <- c("United Kingdom and Colonies" = "United Kingdom and Overseas Territories",
                    "Hong Kong" = "Hong Kong SAR",
                    "Macau" = "Macau SAR",
                    "Not stated" = "Country not stated",
                    "Solomons, The" = "Solomon Islands",
                    "Soloman Islands" = "Solomon Islands")
# Only ever zero in these files, and gone from the post-2015 list.
PR_CITIZENSHIP_ZERO <- c("Panama Canal Zone", "Pitcairn Island")
SP_CITIZENSHIP <- c("United Kingdom and Colonies" = "United Kingdom and Overseas Territories",
                    "Hong Kong" = "Hong Kong SAR",
                    "Macau" = "Macau SAR",
                    "Benin, Peoples Republic of" = "Benin, Republic of",
                    "Republic of Kosovo" = "Kosovo, Republic of",
                    "Other country of citizenship" = "Other",
                    "Country of citizenship not stated" = "Country of Citizenship not stated",
                    "Solomons, The" = "Solomon Islands")
# The one category the post-2015 data has no equivalent for (2002-2014),
# kept as a Sponsored Family component of its own. French: IRCC's own label.
HC_FAMILY <- c(en = "Sponsored Family Member - H&C Consideration", fr = "Membres de la famille parrainés - CH")
# CMAs the old table names without the province part the current ones carry
# are matched as "<name> (<Province> part)"; these were renamed:
CMA_RENAMED <- c("Belleville" = "Belleville - Quinte West")
# Census agglomerations the old table lists that the current one folds into
# "Other - <Province>" (no longer CMAs/CAs, or never published separately).
CMA_TO_OTHER <- c("Bay Roberts", "Cold Lake", "Leamington", "Saint-Jean-sur-Richelieu", "Temiskaming Shores")

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

con <- dbConnect(duckdb(), DB_PATH)
on.exit(dbDisconnect(con, shutdown = TRUE), add = TRUE)

# ---- build rows -------------------------------------------------------------------
# One tibble per file: theme, series, facet, b1-b3, geo_level, geo_1, geo_2,
# year, value, file.
row_template <- function(d, ids, facet, geo_level, b1 = NA_character_, b2 = NA_character_, b3 = NA_character_,
                         geo_1 = NA_character_, geo_2 = NA_character_) {
  tibble::tibble(theme = ids[["theme"]], series = ids[["series"]], facet = facet,
                 b1 = b1, b2 = b2, b3 = b3, geo_level = geo_level, geo_1 = geo_1, geo_2 = geo_2,
                 year = d$year, value = d$value)
}

pr_sr <- function(file, facet) {
  d <- read_sr(file)
  switch(facet,
    "Immigration Category" = {
      m <- map_category(d)
      row_template(m, PR, facet, "National", m$b1, m$b2, m$b3)
    },
    "Country of Citizenship" = {
      d <- d |> filter(!label_1 %in% PR_CITIZENSHIP_ZERO)
      row_template(d, PR, facet, "National", coalesce(PR_CITIZENSHIP[d$label_1], d$label_1))
    },
    "Total" = {
      pt <- ifelse(d$label_1 == "Not stated", NOT_STATED[["Total"]], d$label_1)
      bind_rows(row_template(d, PR, facet, "PT", geo_1 = pt),
                row_template(d, PR, facet, "National"))  # summed per year below
    },
    row_template(d, PR, facet, "National", ifelse(d$label_1 == "Not stated", NOT_STATED[[facet]], d$label_1))
  ) |> mutate(file = file)
}

pr_cma <- function(file) {
  cells <- suppressMessages(readxl::read_excel(file.path(DOWNLOAD_DIR, file), col_names = FALSE, col_types = "text"))
  d <- read_blocks(cells, header_row = 3)
  known <- dbGetQuery(con, "SELECT DISTINCT geo_1, geo_2 FROM series_facts WHERE theme = ? AND geo_level = 'CMA'",
                      params = list(PR[["theme"]]))
  parted <- sprintf("%s (%s part)", d$label, d$pt)
  cma <- case_when(
    d$label == "Other CMA" | d$label %in% CMA_TO_OTHER ~ paste("Other -", d$pt),
    d$label %in% names(CMA_RENAMED) ~ unname(CMA_RENAMED[d$label]),
    paste(d$pt, parted) %in% paste(known$geo_1, known$geo_2) ~ parted,
    .default = d$label
  )
  row_template(d, PR, "Total", "CMA", geo_1 = d$pt, geo_2 = cma) |> mutate(file = file)
}

sp_citizenship <- function(file) {
  d <- read_blocks(read_csv_cells(file), header_row = 3)
  # The file has no national block (its "Total unique" row isn't broken
  # down), so National is the provinces' sum - within 0.2% of the unique
  # total, which counts once a student who studied in two provinces.
  row_template(d, SP, "Country of Citizenship", "National", coalesce(SP_CITIZENSHIP[d$label], d$label)) |>
    mutate(file = file)
}

sp_gender <- function(file) {
  cells <- read_csv_cells(file)
  years <- unlist(cells[3, ])
  genders <- unlist(cells[4, ])
  out <- list()
  for (i in 5:nrow(cells)) {
    place <- trimws(cells[[1]][i])
    if (is.na(place)) next
    geo <- if (place %in% PROVINCES) "PT" else if (place == "Province/Territory not stated") "PT" else
      if (grepl("^Total unique", place)) "National" else next
    for (j in which(grepl("^(19|20)[0-9]{2}$", years))) {
      year <- as.integer(years[j])
      vals <- num(unlist(cells[i, j:(j + 3)]))
      g <- genders[j:(j + 2)]
      # the monthly study-permit tables spell it with a lower-case "t"
      geo_1 <- if (geo != "PT") NA_character_ else if (place %in% PROVINCES) place else "Province/territory not stated"
      # The monthly gender-by-province table has no "province not stated"
      # row, so those students are only in the Total (as after 2015).
      by_gender <- if (geo == "PT" && !place %in% PROVINCES) NULL else
        row_template(tibble::tibble(year = year, value = vals[1:3]), SP, "Gender", geo, g, geo_1 = geo_1)
      out[[length(out) + 1]] <- bind_rows(
        by_gender,
        row_template(tibble::tibble(year = year, value = vals[4]), SP, "Total", geo, geo_1 = geo_1)
      )
    }
  }
  bind_rows(out) |> mutate(file = file)
}

all_years <- bind_rows(
  pr_sr("IRCC_AdhocSR_PR_0001_E.csv", "Age Group"),
  pr_sr("IRCC_AdhocSR_PR_0004_E.csv", "Country of Citizenship"),
  pr_sr("IRCC_AdhocSR_PR_0006_E.csv", "Gender"),
  pr_sr("IRCC_AdhocSR_PR_0007_E.csv", "Immigration Category"),
  pr_sr("IRCC_AdhocSR_PR_0011_E.csv", "Total"),
  pr_cma("IRCC_PRadmiss_0011_E.xls"),
  sp_citizenship("IRCC_IS_0006_E.csv"),
  sp_gender("IRCC_IS_0009_E.csv")
) |>
  filter(!is.na(value)) |>
  group_by(theme, series, facet, b1, b2, b3, geo_level, geo_1, geo_2, year, file) |>
  summarise(value = sum(value), .groups = "drop")

# ---- every label must already exist after 2015 -------------------------------------
# In any of the theme's series (the H&C component aside): the whole path for
# Immigration Category, the top level elsewhere (post-2015 citizenship rows
# are split further, by category). "Other Countries", for one, is only in
# the Francophone series after 2015.
existing <- dbGetQuery(con, "
  SELECT DISTINCT theme, facet, geo_level, breakdown_1 AS b1,
         CASE WHEN facet = 'Immigration Category' THEN breakdown_2 END AS b2,
         CASE WHEN facet = 'Immigration Category' THEN breakdown_3 END AS b3,
         CASE WHEN geo_level IN ('PT', 'CMA') THEN geo_1 END AS geo_1,
         CASE WHEN geo_level = 'CMA' THEN geo_2 END AS geo_2
  FROM series_facts WHERE theme IN (?, ?) AND period_type = 'month'", params = list(PR[["theme"]], SP[["theme"]]))
unmatched <- all_years |>
  filter(year <= LAST_YEAR, value != 0) |>
  distinct(theme, facet, geo_level, b1, b2, b3, geo_1, geo_2) |>
  filter(!(facet == "Immigration Category" & b2 %in% HC_FAMILY[["en"]])) |>
  anti_join(existing, by = c("theme", "facet", "geo_level", "b1", "b2", "b3", "geo_1", "geo_2"))
if (nrow(unmatched) > 0) {
  print(as.data.frame(unmatched))
  stop("pre-2015 labels with no post-2015 match - map them in 09c_add_pre2015.R")
}

# ---- check the splice: 2015 in these files vs the monthly tables ---------------
# Each file's 2015 total (per geography) against the published 2015 total,
# and every category or place with `big`+ in 2015 against the monthly
# tables' own figure. The files are 2016-2017 extracts and the monthly
# tables current, and both are rounded. Smaller categories, and facets'
# own sums, aren't compared: the monthly citizenship figures come from
# country x category x month cells, so many small ones are suppressed
# (their 2015 sum is 4% under the total, Ethiopia's 13%). Study permits
# allow 3% on the total: the extract counts 2.7% fewer 2015 students.
TOLERANCE <- tibble::tribble(
  ~theme,               ~total, ~big, ~category,
  PR[["theme"]],        0.02,   5000, 0.10,
  SP[["theme"]],        0.03,   2000, 0.10
)
db_2015 <- dbGetQuery(con, "
  SELECT theme, series, facet, geo_level, breakdown_1 AS b1, geo_1, geo_2, sum(value) AS db
  FROM series_facts
  WHERE ((theme = ? AND series = ?) OR (theme = ? AND series = ?)) AND period_year = 2015 AND period_type = 'month'
  GROUP BY ALL", params = list(PR[["theme"]], PR[["series"]], SP[["theme"]], SP[["series"]]))
published <- db_2015 |>
  filter(facet == "Total", geo_level == "National") |>
  group_by(theme) |>
  summarise(published = sum(db), .groups = "drop")
file_2015 <- all_years |> filter(year == 2015)
totals <- file_2015 |>
  group_by(theme, file, facet, geo_level) |>
  summarise(sr = sum(value), .groups = "drop") |>
  inner_join(published, by = "theme") |>
  inner_join(TOLERANCE, by = "theme") |>
  mutate(rel = abs(sr - published) / published)
cells <- file_2015 |>
  group_by(theme, facet, geo_level, b1, geo_1, geo_2) |>
  summarise(sr = sum(value), .groups = "drop") |>
  inner_join(db_2015 |> select(-series), by = c("theme", "facet", "geo_level", "b1", "geo_1", "geo_2")) |>
  inner_join(TOLERANCE, by = "theme") |>
  filter(db >= big, !grepl("^Other - ", coalesce(geo_2, ""))) |>
  mutate(rel = abs(sr - db) / db)
cli::cli_alert_info(
  "2015 overlap: totals within {round(100 * max(totals$rel), 2)}%, largest category/place gap {round(100 * max(cells$rel), 1)}%")
if (any(totals$rel > totals$total) || any(cells$rel > cells$category)) {
  print(as.data.frame(totals |> filter(rel > total)))
  print(as.data.frame(cells |> filter(rel > category)))
  stop("pre-2015 files don't line up with the monthly tables in 2015")
}

# ---- series_facts rows --------------------------------------------------------
rows <- all_years |>
  filter(year <= LAST_YEAR, value != 0) |>
  mutate(source_table_id = vapply(file, source_id, character(1))) |>
  group_by(theme, series, facet, b1, b2, b3, geo_level, geo_1, geo_2, year, source_table_id) |>
  summarise(value = sum(value), .groups = "drop") |>
  transmute(theme, series, facet, breakdown_1 = b1, breakdown_2 = b2, breakdown_3 = b3,
            geo_level, geo_1, geo_2, geo_3 = NA_character_,
            period_type = "year", period_year = year, period_quarter = NA_integer_, period_month = NA_integer_,
            value, is_stock = FALSE, source_table_id)

cols <- dbListFields(con, "series_facts")
stopifnot(setequal(cols, names(rows)))
# Everything this script ever wrote, whatever its slug was at the time.
prefixes <- unique(sprintf("%s/%s__", resources$theme, substr(resources$resource_id, 1, 8)))
invisible(dbExecute(con, sprintf("DELETE FROM series_facts WHERE %s",
                                 paste(sprintf("starts_with(source_table_id, %s)", DBI::dbQuoteString(con, prefixes)),
                                       collapse = " OR "))))
dbAppendTable(con, "series_facts", rows[, cols])

# ---- French label for the one new category ------------------------------------
invisible(dbExecute(con, "DELETE FROM category_translations WHERE source = 'pre2015'"))
dbAppendTable(con, "category_translations", tibble::tibble(
  en_text = HC_FAMILY[["en"]], context = "breakdown_2", table_id = NA_character_,
  fr_text = HC_FAMILY[["fr"]], source = "pre2015"
)[, dbListFields(con, "category_translations")])

# ---- citation records, in source_manifest.csv's format -----------------------
readr::write_csv(resources |> transmute(
  dataset = theme, dataset_id, resource_id,
  table_key = tolower(table_name), table_name, format, url, last_modified_ckan
), SOURCES_CSV)

summary <- rows |> group_by(theme) |> summarise(n = n(), from = min(period_year), facets = n_distinct(facet))
for (i in seq_len(nrow(summary))) {
  cli::cli_alert_success("{summary$theme[i]} {summary$from[i]}-{LAST_YEAR}: {summary$n[i]} series_facts rows across {summary$facets[i]} facets")
}
