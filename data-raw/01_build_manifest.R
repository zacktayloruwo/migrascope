# Refresh data-raw/manifest.csv from the live CKAN API.
#
# IRCC republishes these "Monthly Update" datasets on a rolling basis
# (new resources are occasionally added, e.g. a new "on December 31st"
# breakdown), so re-run this whenever you want to pick up new tables before
# downloading. It does NOT download any data itself.

library(dplyr)
source("R/ingest_utils.R")

cli::cli_h1("Building manifest from CKAN")

manifest <- build_full_manifest()

cli::cli_alert_success(
  "Found {nrow(manifest)} tables across {length(unique(manifest$dataset))} datasets"
)
print(count(manifest, dataset, format))

readr::write_csv(manifest, "data-raw/manifest.csv")
cli::cli_alert_info("Wrote data-raw/manifest.csv")
