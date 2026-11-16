# Adds the Immigration and Refugee Board's refugee claims statistics to the
# asylum_claimants theme from the IRB's own web pages, which aren't on the
# Open Government Portal: one table a year, "Claims by Country of Alleged
# Persecution", 2013 to the current year to date:
# https://www.irb-cisr.gc.ca/en/statistics/protection/Pages/index.aspx
# (French: https://www.irb-cisr.gc.ca/fr/statistiques/asile/Pages/index.aspx).
#
# The IRB's open dataset (rpd_decisions, in the refugees theme) splits
# decisions only into Positive / Negative / Other. These pages also split
# "Other" into abandoned and withdrawn, and give the claims referred to the
# IRB and those still pending, so this writes three series:
#  - "Claims referred to the IRB": new claims in the year (a flow),
#  - "Claims finalized by the IRB": decisions in the year, by decision
#    (accepted, rejected, abandoned, withdrawn and other) (a flow),
#  - "Claims pending at the IRB (end of year)": claims waiting on December 31
#    (a stock; the current year's page gives its latest quarter-end instead).
# Each by country of alleged persecution as well as in total. All are
# annual rows (period_type "year"); the current year is year to date, which
# the web app marks as a partial year.
#
# Values between 1 and 4 are shown as "--" and read as missing, like IRCC's;
# the Total row is the IRB's own, so it includes them.
#
# Country names are paired with their French versions by matching each
# country's figures across every year (the French table sorts differently).
# Also writes category_translations rows (source "irb") and
# app/data/irb_sources.csv, the citation record 10_export_web.R adds to
# sources.json. 08 rewrites series_facts and 09 category_translations, so
# run this after both (and after 09b-09d, before 10). Run from the project root.

library(DBI)
library(duckdb)
library(dplyr)

DB_PATH <- "app/data/immigration.duckdb"
THEME <- "asylum_claimants"
# 8 hex characters like every other table's resource hash (the app finds a
# row's citation by it); "1eb" for IRB.
HASH <- "1eb00001"
TABLE_ID <- sprintf("%s/%s__irb_claims_by_country_of_alleged_persecution", THEME, HASH)
PAGE <- c(en = "https://www.irb-cisr.gc.ca/en/statistics/protection/Pages/RPDStat%d.aspx",
          fr = "https://www.irb-cisr.gc.ca/fr/statistiques/asile/Pages/SPRStat%d.aspx")
INDEX <- c(en = "https://www.irb-cisr.gc.ca/en/statistics/protection/Pages/index.aspx",
           fr = "https://www.irb-cisr.gc.ca/fr/statistiques/asile/Pages/index.aspx")
FIRST_YEAR <- 2013L  # the IRB no longer publishes claims referred before December 15, 2012
DOWNLOAD_DIR <- "data-raw/downloads/irb_claims"
SOURCES_CSV <- "app/data/irb_sources.csv"
SERIES <- c(referred = "Claims referred to the IRB", finalized = "Claims finalized by the IRB",
            pending = "Claims pending at the IRB (end of year)")
COUNTRY <- "Country of Alleged Persecution"
DECISION <- "Decision"
# The table's columns after the country, in order.
COLS <- c("referred", "Accepted", "Rejected", "Abandoned", "Withdrawn and other", "finalized", "pending")
DECISIONS <- c("Accepted", "Rejected", "Abandoned", "Withdrawn and other")
DECISIONS_FR <- c("Accueillies", "Rejetées", "Désistements", "Retraits ou autres")

if (!file.exists(DB_PATH)) stop("app/data/immigration.duckdb not found - run data-raw/05 through 09 first")
dir.create(DOWNLOAD_DIR, recursive = TRUE, showWarnings = FALSE)

# ---- download (every run: the current year's page is updated each quarter) -------
# Through the system curl, as in 09d.
fetch <- function(url, path) {
  system2("curl", c("--silent", "--show-error", "--fail", "--location", "--retry", "3",
                    "--max-time", "120", "--output", shQuote(path), shQuote(url)), stderr = FALSE) == 0
}
this_year <- as.integer(format(Sys.Date(), "%Y"))
pages <- list()
for (year in FIRST_YEAR:this_year) {
  for (lang in c("en", "fr")) {
    path <- file.path(DOWNLOAD_DIR, sprintf("irb_claims_%d_%s.html", year, lang))
    if (!fetch(sprintf(PAGE[[lang]], year), path)) {
      # early in a year its page may not exist yet
      if (year == this_year) break
      stop("Could not download ", sprintf(PAGE[[lang]], year))
    }
    pages[[paste(year, lang)]] <- list(year = year, lang = lang, path = path)
  }
}

# ---- parse ------------------------------------------------------------------------
num <- function(x) {
  x <- gsub("[^0-9-]", "", x)  # thousands separators: commas, spaces, zero-width spaces
  ifelse(x == "--", NA_real_, suppressWarnings(as.numeric(x)))
}
read_page <- function(p) {
  table <- xml2::read_html(p$path, encoding = "UTF-8") |> rvest::html_element("table")
  caption <- rvest::html_text2(rvest::html_element(table, "caption"))
  cells <- rvest::html_elements(table, "tr") |>
    lapply(function(tr) gsub("\\s+", " ", trimws(gsub("[\u200b\u00a0]", " ", rvest::html_text2(rvest::html_elements(tr, "th, td"))))))
  body <- Filter(function(r) length(r) == 1 + length(COLS), cells)
  if (length(body) < 50 || body[[1]][1] != "Total") stop("Unexpected table layout in ", p$path)
  pending_as_of <- regmatches(cells[[1]][4], regexpr("[0-9]{4}/[0-9]{2}/[0-9]{2}", cells[[1]][4]))
  d <- as_tibble(do.call(rbind, body), .name_repair = ~ c("place", COLS)) |>
    mutate(across(all_of(COLS), num), year = p$year, lang = p$lang)
  attr(d, "caption") <- gsub("\\s+", " ", gsub("\u200b", "", caption))
  attr(d, "pending_as_of") <- as.Date(pending_as_of, "%Y/%m/%d")
  d
}
parsed <- lapply(pages, read_page)
en <- bind_rows(Filter(function(d) d$lang[1] == "en", parsed))
fr <- bind_rows(Filter(function(d) d$lang[1] == "fr", parsed))
latest_en <- parsed[[paste(max(en$year), "en")]]

# The four decisions make up "finalized", and the countries the total (where
# none is suppressed).
bad <- en |> filter(!is.na(finalized), finalized != Accepted + Rejected + Abandoned + `Withdrawn and other`)
if (nrow(bad) > 0) stop(nrow(bad), " rows where the decisions don't add up to Finalized, e.g. ", bad$place[1], " ", bad$year[1])
sums <- en |>
  group_by(year) |>
  summarise(across(all_of(COLS), ~ sum(.x[place != "Total"], na.rm = TRUE) - sum(.x[place == "Total"])), .groups = "drop")
if (any(as.matrix(sums[COLS]) > 0)) stop("Countries add up to more than the published total - check the table layout")

# ---- French country names ---------------------------------------------------------
# Within a year, a country's row of figures identifies it in both tables.
# Rows that tie with another (small countries: "1, --, --, ...") are left
# out rather than guessed; FR_EXTRA below covers those with no French yet.
signature <- function(d) {
  d |>
    filter(place != "Total") |>
    mutate(sig = do.call(paste, c(across(all_of(COLS)), sep = ";"))) |>
    group_by(year, sig) |> filter(n() == 1) |> ungroup() |>
    select(year, sig, place)
}
pairs <- inner_join(signature(en), signature(fr), by = c("year", "sig"), suffix = c("_en", "_fr"))

# ---- one name per country -----------------------------------------------------------
# The IRB respells countries between years; each spelling maps to the
# current one, so a country stays one category across the years. Where the
# IRB lists two rows that are the same place (Slovakia and "Slovakia (Slovak
# Republic)" until 2019; "Unknown" and "(Blank)" in 2021-2023), they're added
# together. Distinct places it lists separately (Palestine and the Occupied
# Palestinian Territory, England and the United Kingdom) stay separate.
PLACE_NAMES <- c(
  "(Blank)" = "Not stated", "Unknown" = "Not stated",
  "Belarus (Byelorussia)" = "Belarus", "Belarus(Byelorussia)" = "Belarus",
  "Central African Rep" = "Central African Republic",
  "Congo (Brazzaville)" = "Congo, Republic of the (Brazzaville)",
  "Congo, Democratic Republic" = "Congo, Democratic Republic of the",
  "Congo, Democratic Republic of the (Zaire)" = "Congo, Democratic Republic of the",
  "Ivory Coast" = "Côte d'Ivoire (Ivory Coast)",
  "Hong Kong (SAR)" = "Hong Kong",
  "Korea DPR (North)" = "Korea, Democratic People's Republic of (North Korea)",
  "Korea, Democratic People's Republic of (North)" = "Korea, Democratic People's Republic of (North Korea)",
  "Korea, Democratic People's Republic of (North Korea" = "Korea, Democratic People's Republic of (North Korea)",
  "Korea R. (South)" = "Korea, Republic of (South Korea)",
  "Korea, Republic of (South)" = "Korea, Republic of (South Korea)",
  "Macedonia" = "North Macedonia", "North Macedonia, Republic Of" = "North Macedonia",
  "Moldova" = "Moldova, Republic of",
  "Myanmar, Burma" = "Myanmar (Burma)",
  "Palestine Territory, Occupied" = "Palestinian Territory, Occupied",
  "Saint Kitts and Nevis, Fed. Of" = "Saint Kitts and Nevis",
  "Saint Kitts and Nevis, Federation of" = "Saint Kitts and Nevis",
  "Saint Vincent" = "Saint Vincent and the Grenadines",
  "Slovakia (Slovak Republic)" = "Slovakia",
  "Sudan (South)" = "South Sudan",
  "Swaziland" = "Eswatini (Swaziland)",
  "Turkey" = "Türkiye",
  "United States of America" = "United States",
  "Vietnam" = "Viet Nam",
  "Western Samoa" = "Samoa", "Western Saomoa" = "Samoa"
)
rename_place <- function(x) ifelse(x %in% names(PLACE_NAMES), PLACE_NAMES[x], x)
sum_or_na <- function(x) if (all(is.na(x))) NA_real_ else sum(x, na.rm = TRUE)
en <- en |>
  mutate(place = rename_place(place)) |>
  group_by(year, place) |>
  summarise(across(all_of(COLS), sum_or_na), .groups = "drop")
# A country's French name: from the latest year it was paired in.
pairs <- pairs |>
  mutate(place_en = rename_place(place_en)) |>
  group_by(place_en) |> slice_max(year, n = 1, with_ties = FALSE) |> ungroup()
# Countries never paired (rows too small to tell apart) mostly have French
# from IRCC's tables already; these don't.
FR_EXTRA <- c(
  "Anguilla" = "Anguilla", "Bosnia and Herzegovina" = "Bosnie-Herzégovine", "Botswana" = "Botswana",
  "British Virgin Island" = "Îles Vierges britanniques", "Cape Verde" = "Cap-Vert", "Cayman Islands" = "Îles Caïmans",
  "Cyprus" = "Chypre", "Denmark" = "Danemark", "England" = "Angleterre", "Equatorial Guinea" = "Guinée équatoriale",
  "Estonia" = "Estonie", "Falkland Islands" = "Îles Falkland", "Finland" = "Finlande", "French Guiana" = "Guyane française",
  "Gibraltar" = "Gibraltar", "Grenada" = "Grenade", "Guadeloupe" = "Guadeloupe", "Guinea-Bissau" = "Guinée-Bissau",
  "Lesotho" = "Lesotho", "Macao" = "Macao", "Maldives" = "Maldives", "Malta" = "Malte", "Marshall Islands" = "Îles Marshall",
  "Moldova, Republic of" = "Moldavie, République de", "Montenegro" = "Monténégro", "Mozambique" = "Mozambique",
  "North Macedonia" = "Macédoine du Nord", "Northern Ireland" = "Irlande du Nord",
  "Palestinian Territory, Occupied" = "Territoire palestinien occupé", "Saint Kitts and Nevis" = "Saint-Kitts-et-Nevis",
  "Samoa" = "Samoa", "San Marino" = "Saint-Marin", "Serbia" = "Serbie", "Seychelles" = "Seychelles",
  "Slovenia" = "Slovénie", "Stateless" = "Apatride", "Suriname" = "Suriname", "Switzerland" = "Suisse",
  "Turkmenistan" = "Turkménistan", "Turks and Caicos Islands" = "Îles Turques-et-Caïques",
  "UK - Brit. protected person" = "R.-U. - Protégé britannique", "Western Sahara" = "Sahara occidental"
)

# ---- series_facts rows ------------------------------------------------------------

year_rows <- function(d, series, facet, b1 = NA_character_, b2 = NA_character_, is_stock = FALSE) {
  tibble::tibble(theme = THEME, series = series, facet = facet,
                 breakdown_1 = b1, breakdown_2 = b2, breakdown_3 = NA_character_,
                 geo_level = "National", geo_1 = NA_character_, geo_2 = NA_character_, geo_3 = NA_character_,
                 period_type = "year", period_year = d$year, period_quarter = NA_integer_,
                 period_month = NA_integer_, value = d$value, is_stock = is_stock, source_table_id = TABLE_ID) |>
    filter(!is.na(value))
}
total <- en |> filter(place == "Total")
countries <- en |> filter(place != "Total")
decisions <- function(d) {
  d |> tidyr::pivot_longer(all_of(DECISIONS), names_to = "decision") |> mutate(decision = factor(decision, DECISIONS))
}
dec_total <- decisions(total)
dec_country <- decisions(countries)

rows <- bind_rows(
  year_rows(total |> mutate(value = referred), SERIES[["referred"]], "Total"),
  year_rows(countries |> mutate(value = referred), SERIES[["referred"]], COUNTRY, countries$place),
  year_rows(total |> mutate(value = finalized), SERIES[["finalized"]], "Total"),
  year_rows(dec_total, SERIES[["finalized"]], DECISION, as.character(dec_total$decision)),
  year_rows(countries |> mutate(value = finalized), SERIES[["finalized"]], COUNTRY, countries$place),
  year_rows(dec_country, SERIES[["finalized"]], paste(DECISION, "and", COUNTRY),
            as.character(dec_country$decision), dec_country$place),
  year_rows(total |> mutate(value = pending), SERIES[["pending"]], "Total", is_stock = TRUE),
  year_rows(countries |> mutate(value = pending), SERIES[["pending"]], COUNTRY, countries$place, is_stock = TRUE)
)

con <- dbConnect(duckdb(), DB_PATH)
on.exit(dbDisconnect(con, shutdown = TRUE), add = TRUE)
cols <- dbListFields(con, "series_facts")
stopifnot(setequal(cols, names(rows)))
invisible(dbExecute(con, "DELETE FROM series_facts WHERE source_table_id = ?", params = list(TABLE_ID)))
dbAppendTable(con, "series_facts", rows[, cols])

# ---- French labels ------------------------------------------------------------------
# Only labels with no French yet: country names already translated from
# IRCC's tables keep their translation.
tr <- bind_rows(
  tibble::tibble(en_text = DECISIONS, fr_text = DECISIONS_FR),
  tibble::tibble(en_text = "Not stated", fr_text = "Non déclaré"),
  pairs |> filter(place_en != "Not stated") |> transmute(en_text = place_en, fr_text = place_fr),
  tibble::tibble(en_text = names(FR_EXTRA), fr_text = unname(FR_EXTRA)) |> filter(!en_text %in% pairs$place_en)
) |>
  tidyr::crossing(context = c("breakdown_1", "breakdown_2")) |>
  transmute(en_text, context, table_id = NA_character_, fr_text, source = "irb")
invisible(dbExecute(con, "DELETE FROM category_translations WHERE source = 'irb'"))
have <- dbGetQuery(con, "SELECT DISTINCT en_text, context FROM category_translations WHERE table_id IS NULL")
tr <- anti_join(tr, have, by = c("en_text", "context"))
dbAppendTable(con, "category_translations", tr[, dbListFields(con, "category_translations")])
missing_fr <- setdiff(unique(c(countries$place, DECISIONS)), c(have$en_text[have$context == "breakdown_1"], tr$en_text))
if (length(missing_fr) > 0) {
  cli::cli_alert_warning("No French for {length(missing_fr)} label{?s} (shown in English): {paste(missing_fr, collapse = '; ')}")
}

# ---- citation record ----------------------------------------------------------------
as_of <- attr(latest_en, "pending_as_of")
FR_MONTHS <- c("janvier", "février", "mars", "avril", "mai", "juin", "juillet", "août", "septembre",
               "octobre", "novembre", "décembre")
readr::write_csv(tibble::tibble(
  hash = HASH,
  agency = "Immigration and Refugee Board of Canada (IRB)",
  agency_fr = "Commission de l'immigration et du statut de réfugié du Canada (CISR)",
  table_name = sprintf("Refugee claims statistics: Claims by Country of Alleged Persecution, %d to %s",
                       FIRST_YEAR, format(as_of, "%B %Y")),
  table_name_fr = sprintf("Statistiques sur les demandes d'asile : Demandes d'asile par pays présenté comme pays de persécution, %d à %s %s",
                          FIRST_YEAR, FR_MONTHS[as.integer(format(as_of, "%m"))], format(as_of, "%Y")),
  format = "HTML",
  url = INDEX[["en"]],
  url_fr = INDEX[["fr"]],
  dataset_url = INDEX[["en"]],
  dataset_url_fr = INDEX[["fr"]],
  updated_at = format(as_of),
  data_through = format(as_of, "%Y-%m")
), SOURCES_CSV)

cli::cli_alert_success(paste0(
  "{THEME}: IRB claims {FIRST_YEAR}-{max(en$year)} ({attr(latest_en, 'caption')}), {nrow(rows)} series_facts rows, ",
  "{nrow(tr)} French labels, {nrow(pairs)} of {length(unique(countries$place))} countries paired"))
