# Shared helpers for the IRCC open data ingest pipeline.

#' IRCC "Monthly Update" CKAN datasets tracked by this pipeline.
#'
#' Names are the internal dataset slugs used for folder names; values are the
#' CKAN package ids from open.canada.ca.
ircc_datasets <- c(
  temporary_workers    = "360024f2-17e9-4558-bfc1-3616485d65b9",
  asylum_claimants     = "b6cbcf4d-f763-4924-a2fb-8cc4a06e3de4",
  study_permit_holders = "90115b00-f9b8-49e8-afa3-b4cff8facaee",
  tr_to_pr_transition  = "1b026aab-edb3-4d5d-8231-270a09ed4e82",
  permanent_residents  = "f7e5498e-0ad8-4417-85c9-9b8aff9b9eda"
)

#' Immigration and Refugee Board (IRB) datasets tracked by this pipeline.
#' These are structured differently from the IRCC "Monthly Update" series
#' above: `rpd_decisions` republishes the SAME cumulative table under a new
#' dated resource each quarter (rather than replacing one stable URL), so
#' building its manifest means picking out the latest quarter's resource
#' rather than deduping by name; `rpd_1997_2021` is a one-off historical
#' extract with no ongoing updates. Both are already flat/tidy tables (one
#' row per category x year) with no nested headers, unlike the IRCC pivots.
irb_datasets <- c(
  rpd_decisions  = "6e47f705-71ed-41f0-8fd5-d1a8508a3b63",
  rpd_1997_2021  = "bf181c11-8c67-4b98-a002-c0f016b2e43c"
)

ckan_package_show_url   <- "https://open.canada.ca/data/api/action/package_show"
ckan_package_search_url <- "https://open.canada.ca/data/api/action/package_search"

#' Fetch the full CKAN package record for one dataset id.
fetch_ckan_package <- function(dataset_id) {
  resp <- httr2::request(ckan_package_show_url) |>
    httr2::req_url_query(id = dataset_id) |>
    httr2::req_user_agent("canadian-immigration-statistics ingest pipeline") |>
    httr2::req_retry(max_tries = 3) |>
    httr2::req_perform()

  httr2::resp_body_json(resp, simplifyVector = FALSE)
}

#' Discover every "... - Monthly IRCC Updates" dataset published under the
#' IRCC/CIC organization on open.canada.ca, via the CKAN `package_search` API
#' (i.e. the same catalogue backing the HTML search page, queried directly).
#'
#' This does NOT change what `01_build_manifest.R` downloads - it's a
#' read-only survey so you can spot new datasets IRCC has added (or archived)
#' and decide whether to add their id to `ircc_datasets` above.
discover_cic_monthly_update_datasets <- function() {
  resp <- httr2::request(ckan_package_search_url) |>
    httr2::req_url_query(fq = "organization:cic", rows = 200) |>
    httr2::req_user_agent("canadian-immigration-statistics ingest pipeline") |>
    httr2::req_retry(max_tries = 3) |>
    httr2::req_perform()

  body <- httr2::resp_body_json(resp, simplifyVector = FALSE)
  results <- body$result$results

  rows <- purrr::map(results, function(r) {
    title <- if (is.list(r$title)) r$title$en else r$title
    if (is.null(title) || !nzchar(title)) return(NULL)

    tibble::tibble(
      dataset_id = r$id,
      title      = title,
      archived   = grepl("archived", title, ignore.case = TRUE),
      n_resources = length(r$resources),
      metadata_modified = r$metadata_modified %||% NA_character_
    )
  })

  dplyr::bind_rows(rows) |>
    dplyr::filter(grepl("monthly ircc updates", tolower(.data$title))) |>
    dplyr::arrange(.data$archived, .data$title)
}

#' Strip a leading bracketed note (e.g. "[rounded numbers - not for
#' calculations] "), collapse whitespace/dash/comma variants, and normalize
#' "resident"/"residents", so that the same table published under two
#' slightly different names (case, punctuation, singular/plural) groups
#' under one key instead of silently surviving as two separate resources.
#' Found via a post-hoc audit of the built catalog: two pairs of tables
#' turned out to hold the same data under names this function didn't yet
#' collapse - see README's "Known limitations" for the two exact titles and
#' how their values were confirmed to match before adding these rules.
normalize_table_key <- function(name) {
  name <- sub("^\\[[^]]*\\]\\s*", "", name)
  name <- gsub("[–—]", "-", name) # en/em dash -> hyphen
  name <- gsub(",", "", name) # serial-comma variants ("X, Y and Z" vs "X, Y, and Z")
  name <- gsub("residents?\\b", "resident", name, ignore.case = TRUE) # singular/plural
  name <- gsub("\\s+", " ", name)
  tolower(trimws(sub("\\.$", "", name)))
}

#' Build the resource manifest for one CKAN dataset.
#'
#' For each distinct table (grouped by its cleaned English name) this keeps a
#' single resource, preferring XLSX/XLS over CSV since IRCC's Excel exports
#' are not rounded/suppressed the way some CSV twins are. HTML resources
#' (documentation landing pages, not data) are dropped. Non-English-language
#' resources are dropped.
build_dataset_manifest <- function(dataset_id, slug) {
  pkg <- fetch_ckan_package(dataset_id)
  resources <- pkg$result$resources

  fmt_rank <- c(XLSX = 1, XLS = 2, CSV = 3)

  rows <- purrr::map(resources, function(r) {
    fmt <- toupper(r$format %||% "")
    if (!fmt %in% names(fmt_rank)) return(NULL)

    langs <- unlist(r$language)
    if (!"en" %in% langs) return(NULL)

    name_en <- if (is.list(r$name)) r$name$en else r$name
    if (is.null(name_en) || !nzchar(name_en)) return(NULL)

    tibble::tibble(
      dataset     = slug,
      dataset_id  = dataset_id,
      resource_id = r$id,
      table_key   = normalize_table_key(name_en),
      table_name  = trimws(sub("^\\[[^]]*\\]\\s*", "", name_en)),
      format      = fmt,
      format_rank = fmt_rank[[fmt]],
      url         = r$url,
      last_modified_ckan = r$metadata_modified %||% NA_character_
    )
  })

  dplyr::bind_rows(rows)
}

`%||%` <- function(x, y) if (is.null(x)) y else x

#' Build the manifest for the RPD Decisions dataset: unlike the IRCC series,
#' IRB keeps every past quarterly snapshot as its own dated resource (e.g.
#' "Refugee Protection Division Decisions 2025 Q4", "... 2026 Q1") instead
#' of replacing one stable URL - so this picks out only the most recent
#' quarter's English resource (preferring XLSX) rather than deduping by
#' name. The one-off Data Dictionary resource is kept too, tagged
#' separately so the processing step can skip it as documentation, not data.
build_rpd_decisions_manifest <- function(dataset_id = irb_datasets[["rpd_decisions"]], slug = "rpd_decisions") {
  pkg <- fetch_ckan_package(dataset_id)
  resources <- pkg$result$resources
  fmt_rank <- c(XLSX = 1, XLS = 2, CSV = 3)

  en_resources <- purrr::keep(resources, function(r) {
    fmt <- toupper(r$format %||% "")
    langs <- unlist(r$language)
    fmt %in% names(fmt_rank) && "en" %in% langs
  })

  snapshots <- purrr::map(en_resources, function(r) {
    name_en <- if (is.list(r$name)) r$name$en else r$name
    m <- regmatches(name_en, regexec("(\\d{4})\\s*Q([1-4])", name_en))[[1]]
    if (length(m) == 0) return(NULL)
    tibble::tibble(
      resource_id = r$id, name = name_en, format = toupper(r$format),
      format_rank = fmt_rank[[toupper(r$format)]],
      year = as.integer(m[2]), quarter = as.integer(m[3]), url = r$url,
      last_modified_ckan = r$metadata_modified %||% NA_character_
    )
  }) |> dplyr::bind_rows()

  latest <- snapshots |>
    dplyr::arrange(dplyr::desc(.data$year), dplyr::desc(.data$quarter), .data$format_rank) |>
    dplyr::slice_head(n = 1) |>
    dplyr::transmute(
      dataset = slug, dataset_id = dataset_id, resource_id = .data$resource_id,
      table_key = "rpd decisions", table_name = "Refugee Protection Division (RPD) Decisions",
      format = .data$format, url = .data$url, last_modified_ckan = .data$last_modified_ckan
    )

  dict <- purrr::keep(en_resources, function(r) {
    name_en <- if (is.list(r$name)) r$name$en else r$name
    grepl("data dictionary", name_en, ignore.case = TRUE)
  })
  dict_row <- if (length(dict) > 0) {
    r <- dict[[1]]
    name_en <- if (is.list(r$name)) r$name$en else r$name
    tibble::tibble(
      dataset = slug, dataset_id = dataset_id, resource_id = r$id,
      table_key = "rpd decisions data dictionary", table_name = name_en,
      format = toupper(r$format), url = r$url,
      last_modified_ckan = r$metadata_modified %||% NA_character_
    )
  } else NULL

  dplyr::bind_rows(latest, dict_row)
}

#' Build and return the full manifest across all tracked datasets, keeping
#' one (preferred-format) resource per distinct table.
build_full_manifest <- function(datasets = ircc_datasets) {
  ircc <- purrr::imap(datasets, build_dataset_manifest) |>
    dplyr::bind_rows() |>
    dplyr::arrange(.data$dataset, .data$format_rank) |>
    dplyr::distinct(.data$dataset, .data$table_key, .keep_all = TRUE) |>
    dplyr::select(-"format_rank") |>
    dplyr::arrange(.data$dataset, .data$table_name)

  rpd_decisions <- build_rpd_decisions_manifest()
  rpd_1997_2021 <- build_dataset_manifest(irb_datasets[["rpd_1997_2021"]], "rpd_1997_2021") |>
    dplyr::arrange(.data$format_rank) |>
    dplyr::distinct(.data$table_key, .keep_all = TRUE) |>
    dplyr::select(-"format_rank")

  dplyr::bind_rows(ircc, rpd_decisions, rpd_1997_2021)
}
