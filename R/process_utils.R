# Turns raw IRCC/IRB files (data-raw/downloads/) into tidy long + wide tables.
#
# Three source shapes appear across the downloaded tables:
#
#  1. IRCC "flat" CSVs: already one row per (year, quarter, month,
#     ...dimensions), with a single TOTAL value column and parallel EN_/FR_
#     columns. These just need the FR_ columns dropped and the period
#     columns parsed.
#
#  2. IRCC "pivot" Excel sheets (most XLSX/XLS files, sometimes several
#     sheets per workbook): a title row, then 1-3 header rows encoding a
#     Year / Quarter / Month hierarchy across columns, then 1-4 leading
#     row-header columns encoding a nested row category (e.g. Province >
#     Immigration Category > Group > Component), where a row's label
#     appears in whichever column matches its level of nesting and blank
#     cells to the right mark it as a subtotal/total row for that level. A
#     trailing "Notes:" block ends the table.
#
#  3. IRB (Refugee Protection Division) tables: much simpler - a single
#     header row of plain English column names (no EN_/FR_ prefixing, no
#     title/blank rows, no nested headers), with one row per category x
#     Year already, and a TOTAL-like value column. Annual granularity only
#     (no quarter/month breakdown).
#
# All three are converted to a common tidy shape: one row per (row-category
# combination x period), with is_row_subtotal / is_period_subtotal flags so
# consumers can exclude subtotal rows/columns to avoid double-counting, and a
# `suppressed` flag for the "--" (values between 0 and 5) privacy code IRCC
# and IRB both use.

month_abb_en <- c("Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec")

#' Parse an IRCC value cell: "--" (suppressed), "12.3%", "1,234", or plain
#' number.
parse_ircc_value <- function(x) {
  x <- trimws(x)
  tibble::tibble(
    value = dplyr::case_when(
      is.na(x) | x == "" ~ NA_real_,
      x == "--" ~ NA_real_,
      grepl("%$", x) ~ suppressWarnings(as.numeric(sub("%$", "", gsub(",", "", x))) / 100),
      TRUE ~ suppressWarnings(as.numeric(gsub(",", "", x)))
    ),
    suppressed = !is.na(x) & x == "--",
    is_percent = grepl("%$", x)
  )
}

# ---- Shape 1: flat "already tidy" CSVs --------------------------------

#' Clean an EN_* column name into snake_case, dropping the EN_ prefix.
clean_dimension_name <- function(x) {
  x <- sub("^EN_", "", x)
  x <- gsub("[-]", "_", x)
  x <- gsub("[^A-Za-z0-9]+", "_", x)
  x <- gsub("_+", "_", x)
  tolower(sub("_+$", "", x))
}

#' Process a "flat" CSV resource (already one row per period x dimensions).
process_flat_csv <- function(path) {
  raw <- readr::read_delim(path, delim = "\t", col_types = readr::cols(.default = "c"),
                            progress = FALSE, show_col_types = FALSE)

  value_col <- names(raw)[toupper(names(raw)) == "TOTAL"][1]
  if (is.na(value_col)) cli::cli_abort("No TOTAL column found in {path}")

  en_cols <- grep("^EN_", names(raw), value = TRUE)
  has_quarter <- "EN_QUARTER" %in% names(raw)
  period_cols <- c("EN_YEAR", if (has_quarter) "EN_QUARTER", "EN_MONTH")
  dim_cols <- setdiff(en_cols, period_cols)

  out <- raw |>
    dplyr::select(dplyr::all_of(c(period_cols, dim_cols, value_col))) |>
    dplyr::rename_with(clean_dimension_name, dplyr::all_of(dim_cols)) |>
    dplyr::mutate(
      period_year = as.integer(.data$EN_YEAR),
      period_month = match(.data$EN_MONTH, month_abb_en),
      period_quarter = if (has_quarter) as.integer(sub("^Q", "", .data$EN_QUARTER)) else ceiling(.data$period_month / 3),
      period_type = "month",
      period_label = sprintf("%04d-%02d", .data$period_year, .data$period_month),
      is_period_subtotal = FALSE,
      is_row_subtotal = FALSE
    ) |>
    dplyr::select(-dplyr::all_of(period_cols))

  vals <- parse_ircc_value(out[[value_col]])
  out[[value_col]] <- NULL
  long <- dplyr::bind_cols(out, vals) |>
    dplyr::relocate("period_year", "period_quarter", "period_month", "period_type",
                     "period_label", "is_period_subtotal", "is_row_subtotal",
                     .after = dplyr::last_col())

  row_id_cols <- dim_cols |> clean_dimension_name()
  wide <- long |>
    dplyr::select(-"suppressed", -"is_percent", -"period_type",
                   -"is_period_subtotal", -"is_row_subtotal",
                   -"period_year", -"period_quarter", -"period_month") |>
    tidyr::pivot_wider(names_from = "period_label", values_from = "value")

  list(long = long, wide = wide)
}

# ---- Shape 3: IRB flat annual tables ------------------------------------

#' Process an IRB (RPD) table: a single header row of plain English column
#' names, one row per category x Year, and a value column ("Total"). Reads
#' XLSX directly; falls back to latin1 for CSV since IRB's CSV exports are
#' not UTF-8 (unlike IRCC's).
process_flat_annual_table <- function(path) {
  ext <- tolower(tools::file_ext(path))
  raw <- if (ext == "csv") {
    readr::read_csv(path, col_types = readr::cols(.default = "c"),
                     locale = readr::locale(encoding = "latin1"),
                     progress = FALSE, show_col_types = FALSE)
  } else {
    readxl::read_excel(path, sheet = 1, col_types = "text")
  }

  value_col <- names(raw)[toupper(names(raw)) == "TOTAL"][1]
  year_col <- names(raw)[toupper(names(raw)) == "YEAR"][1]
  if (is.na(value_col) || is.na(year_col)) {
    cli::cli_abort("Expected a Year and Total column in {path}, found: {paste(names(raw), collapse = ', ')}")
  }

  dim_cols <- setdiff(names(raw), c(year_col, value_col))

  out <- raw |>
    dplyr::rename_with(clean_dimension_name, dplyr::all_of(dim_cols)) |>
    dplyr::mutate(
      period_year = as.integer(.data[[year_col]]),
      period_quarter = NA_integer_,
      period_month = NA_integer_,
      period_type = "year",
      period_label = as.character(.data$period_year),
      is_period_subtotal = FALSE,
      is_row_subtotal = FALSE
    ) |>
    dplyr::select(-dplyr::all_of(year_col))

  vals <- parse_ircc_value(out[[value_col]])
  out[[value_col]] <- NULL
  long <- dplyr::bind_cols(out, vals) |>
    dplyr::relocate("period_year", "period_quarter", "period_month", "period_type",
                     "period_label", "is_period_subtotal", "is_row_subtotal",
                     .after = dplyr::last_col())

  # IRB's source file has a handful of exact-duplicate rows (same category x
  # year, both suppressed "--"/NA) - collapse them for the wide pivot rather
  # than erroring or falling back to list-cols.
  wide <- long |>
    dplyr::select(-"suppressed", -"is_percent", -"period_type",
                   -"is_period_subtotal", -"is_row_subtotal",
                   -"period_year", -"period_quarter", -"period_month") |>
    tidyr::pivot_wider(names_from = "period_label", values_from = "value",
                        values_fn = function(x) if (all(is.na(x))) NA_real_ else sum(x, na.rm = TRUE))

  list(long = long, wide = wide)
}

# ---- Shape 2: nested pivot Excel sheets --------------------------------

is_year_token <- function(x) grepl("^(19|20)[0-9]{2}$", trimws(x))

#' Reconstruct the nested column-header path across a block of header rows,
#' using the same ancestor-stack idea as `fill_row_hierarchy`: scanning left
#' to right, an explicit (non-blank) value at header level `h` becomes the
#' new ancestor for that level and clears any deeper levels (h+1..n) - this
#' matters because the most recent (in-progress) year is often broken into
#' Q1/Q2 sub-columns while a trailing year-to-date "Total" column reverts to
#' a coarser level without a corresponding entry at the deeper level, which
#' a plain per-row LOCF would otherwise carry over incorrectly.
fill_column_hierarchy <- function(header_block) {
  n_levels <- nrow(header_block)
  n_cols <- ncol(header_block)
  path <- rep(NA_character_, n_levels)
  out <- matrix(NA_character_, n_levels, n_cols)

  for (c in seq_len(n_cols)) {
    for (h in seq_len(n_levels)) {
      v <- header_block[h, c]
      if (!is.na(v) && v != "") {
        path[h] <- v
        if (h < n_levels) path[(h + 1):n_levels] <- NA_character_
      }
    }
    out[, c] <- path
  }
  out
}

#' Classify one column's header path (as returned by
#' `fill_column_hierarchy`, top = year down to the finest level present).
classify_period <- function(tokens) {
  nonblank <- tokens[!is.na(tokens)]
  year <- suppressWarnings(as.integer(tokens[1]))
  last <- if (length(nonblank) > 0) nonblank[length(nonblank)] else NA_character_

  if (length(nonblank) <= 1) {
    return(tibble::tibble(period_year = year, period_quarter = NA_integer_,
                           period_month = NA_integer_, period_type = "year",
                           is_period_subtotal = FALSE))
  }

  if (last %in% month_abb_en) {
    month <- match(last, month_abb_en)
    return(tibble::tibble(period_year = year, period_quarter = ceiling(month / 3),
                           period_month = month, period_type = "month",
                           is_period_subtotal = FALSE))
  }

  if (grepl("^Q[1-4] Total$", last)) {
    q <- as.integer(sub("^Q([1-4]).*", "\\1", last))
    return(tibble::tibble(period_year = year, period_quarter = q,
                           period_month = NA_integer_, period_type = "quarter_total",
                           is_period_subtotal = TRUE))
  }

  if (tolower(last) == "total") {
    return(tibble::tibble(period_year = year, period_quarter = NA_integer_,
                           period_month = NA_integer_, period_type = "year",
                           is_period_subtotal = TRUE))
  }

  tibble::tibble(period_year = year, period_quarter = NA_integer_,
                 period_month = NA_integer_, period_type = "other",
                 is_period_subtotal = grepl("total", last, ignore.case = TRUE))
}

#' Strip a trailing "Total" / "- Total" / "Total Percentage" suffix so a
#' subtotal row's label can double as the clean category name inherited by
#' its detail rows (IRCC writes subtotal rows as e.g. "Ontario Total", not
#' "Ontario" - without stripping, that literal suffix would propagate down
#' to every detail row beneath it). A bare "Total" (grand total) strips to
#' NA - it names no specific category.
strip_total_suffix <- function(label) {
  stripped <- trimws(sub("\\s*-?\\s*[Tt]otal(\\s+[Pp]ercentage)?$", "", label))
  dplyr::if_else(stripped == "", NA_character_, stripped)
}

#' Reconstruct the nested row-category path for a block of `k` leading
#' label columns. IRCC writes each group's subtotal row as a *trailing*
#' footer for the detail rows above it (leaf rows first, then e.g.
#' "Ontario Total" closing out the block) - so the ancestor stack is built
#' by scanning bottom-to-top: each row's own label lives in whichever
#' column is non-blank; columns to the right are cleared for that row (a
#' not-yet-closed-out child level), and columns to the left carry forward
#' from the nearest total row *below* at that level. Subtotal rows' "Total"
#' suffix is stripped before being used as the ancestor value so it
#' doesn't propagate into the detail rows above it.
fill_row_hierarchy <- function(raw_labels) {
  k <- ncol(raw_labels)
  n <- nrow(raw_labels)
  path <- rep(NA_character_, k)
  out <- matrix(NA_character_, n, k)
  own_level <- integer(n)
  own_label_raw <- character(n)

  for (i in rev(seq_len(n))) {
    nonblank <- which(!is.na(raw_labels[i, ]) & raw_labels[i, ] != "")
    lvl <- if (length(nonblank) == 0) NA_integer_ else max(nonblank)
    if (is.na(lvl)) {
      # fully blank row-header (shouldn't happen inside the data block) -
      # treat as a continuation of the current path
      out[i, ] <- path
      own_level[i] <- k
      own_label_raw[i] <- NA_character_
      next
    }
    own_label_raw[i] <- raw_labels[i, lvl]
    path[lvl] <- strip_total_suffix(raw_labels[i, lvl])
    if (lvl < k) path[(lvl + 1):k] <- NA_character_
    out[i, ] <- path
    own_level[i] <- lvl
  }

  is_subtotal <- (own_level < k) | grepl("(^|\\s)total$", own_label_raw, ignore.case = TRUE)

  colnames(out) <- paste0("level_", seq_len(k))
  list(labels = tibble::as_tibble(out), is_row_subtotal = is_subtotal,
       row_label_raw = own_label_raw, row_level = own_level)
}

#' Process one sheet of a "pivot" Excel resource.
process_pivot_sheet <- function(path, sheet) {
  m <- readxl::read_excel(path, sheet = sheet, col_names = FALSE, col_types = "text",
                           .name_repair = "minimal")
  m <- as.matrix(m)
  m[is.na(m)] <- ""
  m <- apply(m, c(1, 2), trimws)

  title <- m[1, 1]

  year_row <- NA_integer_
  for (r in 2:min(10, nrow(m))) {
    if (any(is_year_token(m[r, ]))) { year_row <- r; break }
  }
  if (is.na(year_row)) cli::cli_abort("Could not find a year header row in {path} [{sheet}]")

  k <- min(which(is_year_token(m[year_row, ]))) - 1
  if (k < 1) cli::cli_abort("Could not determine row-label column count in {path} [{sheet}]")

  data_token <- function(x) grepl("^-?[0-9,]+(\\.[0-9]+)?%?$|^--$", x)
  data_start <- NA_integer_
  for (r in (year_row + 1):nrow(m)) {
    if (data_token(m[r, k + 1])) { data_start <- r; break }
  }
  if (is.na(data_start)) cli::cli_abort("Could not find data start row in {path} [{sheet}]")

  header_rows <- year_row:(data_start - 1)
  # drop pure spacer rows (e.g. the blank row some annual-only sheets insert
  # between the "Total" header row and the data) - they contribute no tokens
  header_rows <- header_rows[apply(m[header_rows, (k + 1):ncol(m), drop = FALSE], 1,
                                     function(rr) any(rr != ""))]

  data_end <- nrow(m) + 1
  for (r in data_start:nrow(m)) {
    label1 <- tolower(m[r, 1])
    if (grepl("^notes", label1) || grepl("^source", label1)) { data_end <- r; break }
    if (all(m[r, ] == "")) { data_end <- r; break }
  }
  data_rows <- data_start:(data_end - 1)
  if (length(data_rows) == 0) cli::cli_abort("No data rows found in {path} [{sheet}]")

  ncol_m <- ncol(m)
  period_cols <- (k + 1):ncol_m
  header_block <- m[header_rows, period_cols, drop = FALSE]
  header_block[header_block == ""] <- NA_character_
  filled_header <- fill_column_hierarchy(header_block)
  period_meta <- purrr::map(seq_along(period_cols), function(i) {
    tokens <- filled_header[, i]
    classify_period(tokens) |>
      dplyr::mutate(col = period_cols[i],
                     period_label = paste(tokens[!is.na(tokens)], collapse = " "))
  }) |> dplyr::bind_rows()

  row_hier <- fill_row_hierarchy(m[data_rows, 1:k, drop = FALSE])

  long <- purrr::map(seq_along(data_rows), function(i) {
    row_vals <- m[data_rows[i], period_cols]
    vals <- parse_ircc_value(row_vals)
    dplyr::bind_cols(
      row_hier$labels[i, ],
      is_row_subtotal = row_hier$is_row_subtotal[i],
      row_label_raw = row_hier$row_label_raw[i],
      row_level = row_hier$row_level[i],
      period_meta |> dplyr::select("period_year", "period_quarter", "period_month",
                                    "period_type", "period_label", "is_period_subtotal"),
      vals
    )
  }) |> dplyr::bind_rows()

  wide <- long |>
    dplyr::select(-"suppressed", -"is_percent", -"period_type", -"row_label_raw", -"row_level",
                   -"is_period_subtotal", -"period_year", -"period_quarter", -"period_month") |>
    tidyr::pivot_wider(names_from = "period_label", values_from = "value")

  list(title = title, long = long, wide = wide)
}

#' Process every sheet of a pivot Excel resource.
process_pivot_excel <- function(path) {
  sheets <- readxl::excel_sheets(path)
  purrr::map(sheets, function(s) {
    res <- process_pivot_sheet(path, s)
    list(sheet = s, title = res$title, long = res$long, wide = res$wide)
  }) |> rlang::set_names(sheets)
}
