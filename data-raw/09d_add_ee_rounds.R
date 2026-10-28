# Adds IRCC's Express Entry rounds of invitations to the express_entry theme
# from canada.ca's own data file (the one behind the "Express Entry: Rounds
# of invitations" pages), which isn't on the Open Government Portal:
# https://www.canada.ca/content/dam/ircc/documents/json/ee_rounds_123_en.json
# (and _fr.json for the French round names).
#
# One record per draw since January 2015. This writes three series:
#  - "Invitations issued": invitations per month by round type (a flow),
#  - "Candidates in the pool": candidates by CRS score range on the date
#    IRCC took the distribution before each draw, from January 2022 (a
#    stock: each month keeps its last distribution),
#  - "CRS score of lowest-ranked candidate invited": each round type's
#    lowest score invited in the month - a level, not a count, which the
#    web app draws as lines and rolls up to quarters and years by taking the
#    lowest value (series_summary.measure = "level", data-raw/10).
# Round names carry version suffixes ("(Version 1)", "2026-Version 2") and
# were renamed over time; ROUND_TYPES below groups them into stable types,
# which in turn sit in three groups (all programs, program-specific,
# category-based).
#
# Also writes category_translations rows for the labels (source
# "canada_ca") and app/data/canada_ca_sources.csv, the citation record
# 10_export_web.R adds to sources.json. 08 rewrites series_facts and 09
# category_translations, so run this after both (and after 09b/09c, before
# 10). Run from the project root.

library(DBI)
library(duckdb)
library(dplyr)

DB_PATH <- "app/data/immigration.duckdb"
THEME <- "express_entry"
# 8 hex characters like every other table's resource hash (the app finds a
# row's citation by it); "ee" for Express Entry, 123 from the file's name.
HASH <- "ee000123"
TABLE_ID <- sprintf("%s/%s__express_entry_rounds_of_invitations", THEME, HASH)
URL <- c(en = "https://www.canada.ca/content/dam/ircc/documents/json/ee_rounds_123_en.json",
         fr = "https://www.canada.ca/content/dam/ircc/documents/json/ee_rounds_123_fr.json")
PAGE <- c(en = "https://www.canada.ca/en/immigration-refugees-citizenship/services/immigrate-canada/express-entry/rounds-invitations.html",
          fr = "https://www.canada.ca/fr/immigration-refugies-citoyennete/services/immigrer-canada/entree-express/rondes-invitations.html")
DOWNLOAD_DIR <- "data-raw/downloads/express_entry"
SOURCES_CSV <- "app/data/canada_ca_sources.csv"
SERIES <- c(invitations = "Invitations issued", pool = "Candidates in the pool",
            cutoff = "CRS score of lowest-ranked candidate invited")

if (!file.exists(DB_PATH)) stop("app/data/immigration.duckdb not found - run data-raw/05 through 09 first")
dir.create(DOWNLOAD_DIR, recursive = TRUE, showWarnings = FALSE)

# ---- download (every run: IRCC adds a record after each draw) ---------------------
ua <- "canadian-immigration-statistics ingest pipeline"
rounds <- lapply(c("en", "fr"), function(lang) {
  path <- file.path(DOWNLOAD_DIR, sprintf("ee_rounds_123_%s.json", lang))
  # Through the system curl: canada.ca resets or stalls R's own HTTP
  # client (httr2/libcurl) on this file - "HTTP/2 stream was not closed
  # cleanly", then no response at all - while command-line curl gets it.
  status <- system2("curl", c("--silent", "--show-error", "--fail", "--location", "--retry", "3",
                              "--max-time", "120", "--user-agent", shQuote(ua), "--output", shQuote(path),
                              shQuote(URL[[lang]])))
  if (status != 0) stop("Could not download ", URL[[lang]])
  jsonlite::fromJSON(path)$rounds |> as_tibble()
})
names(rounds) <- c("en", "fr")
num <- function(x) as.numeric(gsub("[^0-9]", "", x))

# ---- round types: raw name -> stable type and group ----------------------------------
# Every raw name must be listed (a new kind of round stops the script).
GROUPS <- tibble::tribble(
  ~group,              ~group_fr,
  "All programs",      "Tous les programmes",
  "Program-specific",  "Propres à un programme",
  "Category-based",    "Fondées sur une catégorie"
)
ROUND_TYPES <- tibble::tribble(
  ~pattern,                                              ~group,              ~type,                                              ~type_fr,
  "^No Program Specified$|^General$",                   "All programs",      NA,                                                 NA,
  "^Canadian Experience Class$",                        "Program-specific",  "Canadian Experience Class",                        "Catégorie de l'expérience canadienne",
  "^Provincial Nominee Program$",                       "Program-specific",  "Provincial Nominee Program",                       "Programme des candidats des provinces",
  "^Federal Skilled Worker$",                           "Program-specific",  "Federal Skilled Worker Program",                   "Programme des travailleurs qualifiés (fédéral)",
  "^Federal Skilled Trades$",                           "Program-specific",  "Federal Skilled Trades Program",                   "Programme des travailleurs de métiers spécialisés (fédéral)",
  "^French[- ][Ll]anguage proficiency",                 "Category-based",    "French-language proficiency",                      "Compétence linguistique en français",
  "^Healthcare",                                        "Category-based",    "Healthcare and social services occupations",       "Professions de la santé et des services sociaux",
  "^Trades? [Oo]ccupations",                            "Category-based",    "Trade occupations",                                "Métiers",
  "^STEM occupations",                                  "Category-based",    "STEM occupations",                                 "Professions des STIM",
  "^Transport [Oo]ccupations",                          "Category-based",    "Transport occupations",                            "Métiers des transports",
  "^Agriculture and agri-food occupations",             "Category-based",    "Agriculture and agri-food occupations",            "Métiers de l'agriculture et de l'agroalimentaire",
  "^Education occupations",                             "Category-based",    "Education occupations",                            "Professions de l'éducation",
  "^Senior managers with Canadian [Ww]ork [Ee]xperience", "Category-based",  "Senior managers with Canadian work experience",    "Cadres supérieurs ayant de l'expérience de travail au Canada",
  "^Physicians with Canadian [Ww]ork [Ee]xperience",    "Category-based",    "Physicians with Canadian work experience",         "Médecins ayant de l'expérience de travail au Canada",
  "^Skilled Military Recruits",                         "Category-based",    "Skilled military recruits",                        "Recrues militaires qualifiées"
)
classify <- function(name) {
  hit <- vapply(name, function(n) {
    i <- which(vapply(ROUND_TYPES$pattern, grepl, logical(1), x = n))
    if (length(i) != 1) NA_integer_ else i
  }, integer(1))
  if (anyNA(hit)) stop("Express Entry round names with no type in 09d: ", paste(unique(name[is.na(hit)]), collapse = "; "))
  ROUND_TYPES[hit, c("group", "type")]
}

# Draw "numbers" are text: two same-day draws in May 2018 are 91a and 91b.
draws <- rounds$en |>
  transmute(draw = drawNumber, date = as.Date(drawDate), name = drawName,
            size = num(drawSize), crs = num(drawCRS)) |>
  bind_cols(classify(rounds$en$drawName)) |>
  mutate(period_year = as.integer(format(date, "%Y")), period_month = as.integer(format(date, "%m")),
         period_quarter = (period_month - 1L) %/% 3L + 1L)
stopifnot(!anyNA(draws$size), !anyNA(draws$crs), !anyDuplicated(draws$draw))

# ---- pool distribution: CRS score ranges ------------------------------------------
# dd1..dd18 as on the rounds page: the bold ranges, two of them broken down
# further (dd4-dd8 make up dd3, dd10-dd14 make up dd9), and the total.
BANDS <- tibble::tribble(
  ~col,   ~b1,         ~b2,
  "dd1",  "601-1200",  NA,
  "dd2",  "501-600",   NA,
  "dd4",  "451-500",   "491-500",
  "dd5",  "451-500",   "481-490",
  "dd6",  "451-500",   "471-480",
  "dd7",  "451-500",   "461-470",
  "dd8",  "451-500",   "451-460",
  "dd10", "401-450",   "441-450",
  "dd11", "401-450",   "431-440",
  "dd12", "401-450",   "421-430",
  "dd13", "401-450",   "411-420",
  "dd14", "401-450",   "401-410",
  "dd15", "351-400",   NA,
  "dd16", "301-350",   NA,
  "dd17", "0-300",     NA
)
dd <- rounds$en |>
  transmute(draw = drawNumber, as_on = as.Date(drawDistributionAsOn, format = "%B %d, %Y"),
            across(all_of(paste0("dd", 1:18)), num)) |>
  filter(dd18 > 0)  # draws before 2022 carry zeros
stopifnot(!anyNA(dd$as_on))
# The ranges should add up to their subtotals and the total. IRCC's own
# figures don't always (draw 247, April 2023: 451-500 is 180 more than its
# five ranges), so a few mismatches are reported and the published ranges
# and total kept - the gap shows as a small residual. Many would mean the
# columns have changed meaning, so that stops the script.
mismatch <- dd |>
  filter(dd3 != dd4 + dd5 + dd6 + dd7 + dd8 | dd9 != dd10 + dd11 + dd12 + dd13 + dd14 |
           dd18 != dd1 + dd2 + dd3 + dd9 + dd15 + dd16 + dd17)
if (nrow(mismatch) > 3) stop(nrow(mismatch), " pool distributions don't add up - check the dd columns' meaning")
if (nrow(mismatch) > 0) {
  cli::cli_alert_warning("Pool distribution doesn't add up in draw(s) {paste(mismatch$draw, collapse = ', ')}; kept as published")
}
# A stock: each month keeps its latest distribution.
pool <- dd |>
  mutate(period_year = as.integer(format(as_on, "%Y")), period_month = as.integer(format(as_on, "%m")),
         period_quarter = (period_month - 1L) %/% 3L + 1L) |>
  group_by(period_year, period_month) |>
  slice_max(as_on, n = 1, with_ties = FALSE) |>
  ungroup()

# ---- series_facts rows ------------------------------------------------------------
month_rows <- function(d, series, facet, b1 = NA_character_, b2 = NA_character_, is_stock = FALSE) {
  tibble::tibble(theme = THEME, series = series, facet = facet,
                 breakdown_1 = b1, breakdown_2 = b2, breakdown_3 = NA_character_,
                 geo_level = "National", geo_1 = NA_character_, geo_2 = NA_character_, geo_3 = NA_character_,
                 period_type = "month", period_year = d$period_year, period_quarter = d$period_quarter,
                 period_month = d$period_month, value = d$value, is_stock = is_stock, source_table_id = TABLE_ID)
}
by_month <- function(d, fun, ...) {
  d |> group_by(period_year, period_quarter, period_month, ...) |> summarise(value = fun(value), .groups = "drop")
}

inv <- draws |> mutate(value = size)
inv_type <- by_month(inv, sum, group, type)
inv_total <- by_month(inv, sum)
cut_type <- by_month(draws |> mutate(value = crs), min, group, type)
pool_long <- pool |>
  tidyr::pivot_longer(all_of(BANDS$col), names_to = "col", values_to = "value") |>
  inner_join(BANDS, by = "col")

rows <- bind_rows(
  month_rows(inv_type, SERIES[["invitations"]], "Round Type", inv_type$group, inv_type$type),
  month_rows(inv_total, SERIES[["invitations"]], "Total"),
  month_rows(cut_type, SERIES[["cutoff"]], "Round Type", cut_type$group, cut_type$type),
  month_rows(pool_long, SERIES[["pool"]], "CRS Score Range", pool_long$b1, pool_long$b2, is_stock = TRUE),
  month_rows(pool |> mutate(value = dd18), SERIES[["pool"]], "Total", is_stock = TRUE)
)

con <- dbConnect(duckdb(), DB_PATH)
on.exit(dbDisconnect(con, shutdown = TRUE), add = TRUE)
cols <- dbListFields(con, "series_facts")
stopifnot(setequal(cols, names(rows)))
invisible(dbExecute(con, "DELETE FROM series_facts WHERE source_table_id = ?", params = list(TABLE_ID)))
dbAppendTable(con, "series_facts", rows[, cols])

# ---- French labels ------------------------------------------------------------------
# Round types from the table above (checked against the French file's own
# names when written); the score ranges read the same in both languages.
fr_names <- rounds$fr |> transmute(draw = drawNumber, name_fr = drawName)
stopifnot(nrow(inner_join(draws, fr_names, by = "draw")) == nrow(draws))
tr <- bind_rows(
  GROUPS |> transmute(en_text = group, fr_text = group_fr, context = "breakdown_1"),
  ROUND_TYPES |> filter(!is.na(type)) |> distinct(en_text = type, fr_text = type_fr) |> mutate(context = "breakdown_2")
) |>
  transmute(en_text, context, table_id = NA_character_, fr_text, source = "canada_ca")
invisible(dbExecute(con, "DELETE FROM category_translations WHERE source = 'canada_ca'"))
dbAppendTable(con, "category_translations", tr[, dbListFields(con, "category_translations")])

# ---- citation record ----------------------------------------------------------------
latest <- max(draws$date)
readr::write_csv(tibble::tibble(
  hash = HASH,
  agency = "Immigration, Refugees and Citizenship Canada (IRCC)",
  agency_fr = "Immigration, Réfugiés et Citoyenneté Canada (IRCC)",
  table_name = "Express Entry: Rounds of invitations",
  table_name_fr = "Entrée express : Rondes d’invitations",
  format = "JSON",
  url = URL[["en"]],
  url_fr = URL[["fr"]],
  dataset_url = PAGE[["en"]],
  dataset_url_fr = PAGE[["fr"]],
  updated_at = format(latest),
  data_through = format(latest, "%Y-%m")
), SOURCES_CSV)

cli::cli_alert_success(paste0(
  "{THEME}: {nrow(draws)} draws ({min(draws$date)} to {latest}), {nrow(rows)} series_facts rows, ",
  "pool distribution from {min(dd$as_on)}"))
