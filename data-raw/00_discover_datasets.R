# Survey open.canada.ca for every "... - Monthly IRCC Updates" dataset,
# via the CKAN package_search API (the same catalogue behind the HTML search
# page at search.open.canada.ca, queried directly instead of scraped).
#
# This is read-only: it writes data-raw/discovered_datasets.csv and flags any
# dataset not yet listed in `ircc_datasets` (R/ingest_utils.R) so you can
# decide whether to track it. It does not change what 01_build_manifest.R /
# 02_download_data.R pull.

library(dplyr)
source("R/ingest_utils.R")

cli::cli_h1("Discovering IRCC 'Monthly Update' datasets on open.canada.ca")

discovered <- discover_cic_monthly_update_datasets()
readr::write_csv(discovered, "data-raw/discovered_datasets.csv")

cli::cli_alert_success(
  "Found {nrow(discovered)} 'Monthly IRCC Updates' dataset(s) ({sum(discovered$archived)} archived)"
)

tracked_ids <- unname(ircc_datasets)
new_ones <- discovered |>
  filter(!.data$dataset_id %in% tracked_ids, !.data$archived)

if (nrow(new_ones) > 0) {
  cli::cli_alert_warning("{nrow(new_ones)} active dataset(s) not yet tracked in `ircc_datasets`:")
  print(new_ones |> select(dataset_id, title, n_resources))
  cli::cli_alert_info(
    "Review these at https://open.canada.ca/data/en/dataset/<dataset_id> and, if relevant, add them to `ircc_datasets` in R/ingest_utils.R, then re-run 01_build_manifest.R."
  )
} else {
  cli::cli_alert_success("All active 'Monthly IRCC Updates' datasets are already tracked.")
}

untracked_but_gone <- setdiff(tracked_ids, discovered$dataset_id)
if (length(untracked_but_gone) > 0) {
  cli::cli_alert_warning(
    "Tracked dataset id(s) not found in this search - verify they still exist: {paste(untracked_but_gone, collapse = ', ')}"
  )
}
