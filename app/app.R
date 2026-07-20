# Canadian Immigration Statistics — Shiny app
#
# One theme ("dataset") selected via a sidebar pulldown. Each theme has its
# own set of data tables (a specific breakdown, e.g. "by Province and
# Gender"), a temporal aggregation (Monthly / Quarterly / Annual, limited to
# what that table actually supports), and a category breakdown level - then
# renders a stacked longitudinal bar chart.
#
# This directory (app/) is the self-contained deployment unit for
# shinyapps.io (`rsconnect::deployApp("app")`) - everything it reads is
# inside app/, nothing reaches back into the data-prep tree one level up.
#
# Data comes from data/immigration.duckdb - built by the data-prep pipeline
# at the repo root (../data-raw/05_build_duckdb.R from ../data/processed/)
# and copied here, not generated in place. See ../README.md for the full
# pipeline; that file also (re)writes data/series_names.xlsx,
# data/breakdown_names.xlsx, and data/source_manifest.csv, this app's other
# data inputs besides the duckdb itself. The duckdb has a `facts` table
# (unified schema across all source tables - see ../R/duckdb_utils.R) and a
# `catalog` table describing each table's dimensions.

library(shiny)
library(bslib)
library(DBI)
library(duckdb)
library(dplyr)
# dbplyr isn't called directly anywhere - dplyr::tbl()/collect() on a DBI
# connection need it as a backend under the hood. rsconnect's dependency
# scanner only bundles packages it can see referenced in the source, so
# without this explicit library() call it's silently left out of the
# shinyapps.io deployment (fails at runtime with "check_dbplyr(): The
# package dbplyr is required...").
library(dbplyr)
library(plotly)
library(ggplot2)
library(scales)
library(readxl)

source("R/app_utils.R")

DB_PATH <- "data/immigration.duckdb"
if (!file.exists(DB_PATH)) {
  stop("data/immigration.duckdb not found - run the data-prep pipeline (see ../README.md) then copy its output here")
}

DATASET_LABELS <- c(
  permanent_residents    = "Permanent Residents",
  temporary_workers_imp  = "International Mobility Program",
  temporary_workers_tfwp = "Temporary Foreign Worker Program",
  study_permit_holders   = "Study Permit Holders",
  tr_to_pr_transition    = "TR → PR Transition",
  asylum_claimants       = "Asylum Claimants",
  refugees               = "Refugees"
)

# selectInput's named-vector convention is names = displayed label, values =
# option value - the reverse of DATASET_LABELS (slug = name, label = value).
THEME_CHOICES <- setNames(names(DATASET_LABELS), DATASET_LABELS)

# ---- one shared, read-only connection for the app's lifetime ----
con <- dbConnect(duckdb(), DB_PATH, read_only = TRUE)
onStop(function() dbDisconnect(con, shutdown = TRUE))

catalog <- tbl(con, "catalog") |> collect() |> split_temporary_workers()

# ---- editable name overrides ----------------------------------------------
# Two hand-editable Excel Tables (see data-raw/06_build_label_lookups.R,
# which regenerates the "(auto)" columns on every pipeline refresh while
# preserving whatever's already typed into "(custom)" - same
# survives-a-refresh spirit the old table_short_labels.xlsx short_label
# column used). Only non-blank "(custom)" values become overrides; a
# missing file (e.g. a fresh checkout before the pipeline's been run once)
# just means no overrides are active, not an error.
read_custom_name_lookup <- function(path, key_col, custom_col) {
  if (!file.exists(path)) return(character())
  d <- read_excel(path, sheet = 1)
  custom <- trimws(as.character(d[[custom_col]]))
  keep <- !is.na(custom) & nzchar(custom)
  stats::setNames(custom[keep], d[[key_col]][keep])
}
series_label_lookup <- read_custom_name_lookup("data/series_names.xlsx", "table_id", "Series (custom)")
breakdown_label_lookup <- read_custom_name_lookup("data/breakdown_names.xlsx", "Breakdown item (auto)", "Breakdown item (custom)")

# ---- theme dimension map --------------------------------------------------
# One row per table_id, classifying every level's geographic rank/category
# up front - what Geographic Aggregation, Geographic unit, Break down by,
# and the (usually hidden) Series selector are all driven from, instead of
# the old per-session "Select Data table" pick. Built once at startup like
# `catalog` itself - see build_theme_dimension_map() in R/app_utils.R.
# Known data-quality corrections (mislabeled levels, superseded duplicate
# tables) are applied upstream at database-creation time, not here - see
# data-raw/05_build_duckdb.R.
theme_dim_map <- build_theme_dimension_map(catalog, series_label_lookup = series_label_lookup,
                                            breakdown_label_lookup = breakdown_label_lookup)

# ---- source citation ------------------------------------------------------
# data/source_manifest.csv is a copy of the data-prep pipeline's
# data-raw/manifest.csv (see data-raw/05_build_duckdb.R), placed under the
# app's own data/ directory so the deployable app bundle (this app/
# directory) is self-contained and doesn't reach outside itself into the
# data-prep tree. Records each source table's CKAN resource (agency,
# format, direct file URL, dataset landing page) - joined back to the
# currently-displayed table via its table_id's hash prefix
# (extract_table_hash()) to build a citation for the bottom of the plot card.
manifest <- readr::read_csv("data/source_manifest.csv", show_col_types = FALSE,
                             col_types = readr::cols(last_modified_ckan = "c"))
source_lookup <- build_source_lookup(manifest)

#' Build the citation UI for one displayed table. `table_id` is the table
#' on screen; `sibling_ids` is every table_id in the same theme, used to
#' cite the original source table(s) when `table_id` is a synthetic/derived
#' table (extract_table_hash() returns NA for those - e.g. the merged
#' refugees table, built from two source tables that are also its
#' siblings in the "refugees" theme).
table_citation_ui <- function(table_id, sibling_ids) {
  hash <- extract_table_hash(table_id)
  hashes <- if (!is.na(hash)) {
    hash
  } else {
    sibling_hashes <- vapply(sibling_ids, extract_table_hash, character(1))
    unique(sibling_hashes[!is.na(sibling_hashes)])
  }

  rows <- source_lookup |> filter(hash %in% hashes)
  if (nrow(rows) == 0) return(NULL)

  agency <- paste(unique(rows$agency), collapse = " / ")
  dataset_urls <- unique(rows$dataset_url)

  source_links <- lapply(seq_len(nrow(rows)), function(i) {
    tagList(
      tags$a(href = rows$url[i], target = "_blank", rel = "noopener",
             sprintf('"%s" (%s)', rows$table_name[i], rows$format[i])),
      sprintf(", last updated %s", rows$updated_at[i]),
      if (i < nrow(rows)) "; " else NULL
    )
  })
  dataset_links <- lapply(seq_along(dataset_urls), function(i) {
    tagList(
      tags$a(href = dataset_urls[i], target = "_blank", rel = "noopener",
             if (length(dataset_urls) > 1) sprintf("dataset page %d", i) else "dataset page"),
      if (i < length(dataset_urls)) ", " else NULL
    )
  })

  tags$small(
    class = "text-muted",
    "Source: ", agency, ", Open Government Portal, Government of Canada — ",
    source_links, " (", dataset_links, "). ",
    sprintf("Last accessed %s.", format(Sys.Date(), "%Y-%m-%d"))
  )
}

# ---- About page -----------------------------------------------------------
# Static content (doesn't depend on any input), so it's read and rendered to
# HTML once at startup rather than per-session.
about_html <- markdown(paste(readLines("ABOUT.md", warn = FALSE), collapse = "\n"))

# ---- UI ----------------------------------------------------------------

ui <- page_sidebar(
  title = div(
    class = "d-flex justify-content-between align-items-center w-100",
    h1("Canadian Immigration Statistics Visualizer", class = "bslib-page-title navbar-brand"),
    div(
      class = "d-flex gap-2",
      actionButton("go_plot", "Visualize", class = "btn-sm btn-outline-light"),
      actionButton("go_about", "About", class = "btn-sm btn-outline-light")
    )
  ),
  # `title` is now a tag (buttons alongside the heading), not a plain
  # string - bslib infers the browser tab title by extracting all text
  # from it otherwise, which would pull in the button labels too.
  window_title = "Canadian Immigration Statistics Visualizer",
  theme = bs_theme(version = 5, primary = "#0b4f6c",
                    base_font = font_google("Roboto"),
                    heading_font = font_google("Roboto")),
  tags$head(
    tags$link(rel = "stylesheet", type = "text/css", href = "custom.css"),
    # Highlights whichever of the two nav buttons matches the current
    # main_view panel by swapping its Bootstrap variant (outline <->
    # solid) - done via a tiny custom message rather than re-rendering
    # the buttons through renderUI, which would reset their click
    # counters and risk spurious observeEvent() firings.
    tags$script(HTML("
      Shiny.addCustomMessageHandler('setActiveNav', function(active) {
        var buttons = {plot: document.getElementById('go_plot'), about: document.getElementById('go_about')};
        Object.keys(buttons).forEach(function(key) {
          var btn = buttons[key];
          if (!btn) return;
          btn.classList.toggle('btn-light', key === active);
          btn.classList.toggle('btn-outline-light', key !== active);
        });
      });

      // Greys out (native `disabled`, so it can't be clicked or tabbed to)
      // whichever radio options in a native Shiny radioButtons group aren't
      // valid right now - the input keeps its normal Shiny wiring (clicking
      // an enabled option still just works via the input's own change
      // event), this only ever removes options from being choosable.
      function setRadioAvailability(inputName, available) {
        document.querySelectorAll('input[name=\"' + inputName + '\"]').forEach(function(input) {
          var ok = available.indexOf(input.value) !== -1;
          input.disabled = !ok;
          var label = input.closest('label') || input.parentElement;
          if (label) label.classList.toggle('text-muted', !ok);
        });
      }
      // Which Geographic Aggregation ranks are available for the current
      // theme - the server recomputes this per theme switch (see
      // build_theme_dimension_map() in R/app_utils.R and the input$theme
      // observer in app.R).
      Shiny.addCustomMessageHandler('setGeoAvailability', function(available) {
        setRadioAvailability('geo_level', available);
      });
      // Percentage of Total is meaningless (always exactly 100%) whenever
      // Break down by is actually in effect and set to 'None' - the server
      // recomputes this whenever the resolved fill category changes (see
      // category_level_r() in app.R) and also resets the selection back to
      // Absolute Values if it was on Percentage when this fires.
      Shiny.addCustomMessageHandler('setPercentAllowed', function(allowed) {
        setRadioAvailability('display_as', allowed ? ['absolute', 'percent'] : ['absolute']);
      });
      // Drives the conditionalPanel wrapping the Series selector - it's a
      // genuine Shiny input (not just a UI toggle) so `conditionalPanel`'s
      // JS-evaluated condition can reference it directly.
      Shiny.addCustomMessageHandler('setSeriesNeeded', function(needed) {
        Shiny.setInputValue('series_needed', needed);
      });
    "))
  ),
  sidebar = sidebar(
    width = 340,
    h6("Select Theme"),
    selectInput("theme", NULL, choices = THEME_CHOICES),
    # Only rendered when the current Geo/Category selection still leaves
    # more than one table_id to choose from (a genuine data ambiguity that
    # can't be expressed via geography/category/time alone - see
    # match_candidates() in R/app_utils.R) - `series_needed` is a plain
    # boolean pushed from the server (see the `setSeriesNeeded` handler
    # above), true only in that case. In the common case (one candidate)
    # this never renders.
    conditionalPanel(
      "input.series_needed",
      h6("Series"),
      selectInput("series", NULL, choices = NULL)
    ),
    h6("Temporal aggregation"),
    radioButtons("granularity", NULL, choices = "Annual"),
    h6("Geographic Aggregation"),
    radioButtons("geo_level", NULL, choices = c(
      "National" = "national",
      "Province/Territory" = "PT",
      "CMA" = "CMA",
      "CD" = "CD",
      "CSD" = "CSD"
    ), selected = "national"),
    conditionalPanel(
      "input.geo_level != 'national'",
      h6("Geographic unit"),
      selectizeInput("geo_unit", NULL, choices = c("All" = "All"), options = list(server = TRUE))
    ),
    conditionalPanel(
      "input.geo_level == 'national' || input.geo_unit != 'All'",
      h6("Break down by"),
      selectInput("cat_level", NULL, choices = c("None" = "none"))
    ),
    h6("Display as"),
    radioButtons("display_as", NULL,
                 choices = c("Absolute Values" = "absolute", "Percentage of Total" = "percent")),
    h6("Year Range"),
    sliderInput("years", NULL, min = 2000, max = 2026, value = c(2015, 2026), sep = ""),
    h6("Max categories shown (rest grouped as ‘Other’)"),
    numericInput("top_n", NULL,
                 value = 5, min = 2, max = 13),
    helpText("Note: IRCC/IRB suppress (“--”) any value between 0 and 5 to protect privacy; ",
             "suppressed values are excluded from sums, so totals may be slightly understated.")
  ),
  navset_hidden(
    id = "main_view",
    nav_panel(
      "plot",
      card(
        full_screen = TRUE,
        card_header(textOutput("plot_title")),
        plotlyOutput("plot", height = "600px"),
        card_footer(uiOutput("source_citation"))
      )
    ),
    nav_panel(
      "about",
      card(
        full_screen = TRUE,
        card_header("About"),
        div(class = "p-4", style = "max-width: 800px;", about_html)
      )
    )
  )
)

# ---- server -------------------------------------------------------------

server <- function(input, output, session) {
  observeEvent(input$go_about, nav_select("main_view", selected = "about", session = session))
  observeEvent(input$go_plot, nav_select("main_view", selected = "plot", session = session))

  # Fires on every panel switch, including the initial one at page load,
  # so the "active" button styling (see the setActiveNav JS handler in
  # the UI) always matches whichever panel is actually showing.
  observeEvent(input$main_view, {
    session$sendCustomMessage("setActiveNav", input$main_view)
  })

  # This theme's rows from the precomputed dimension map - every other
  # reactive below filters/unions over this instead of talking to `catalog`
  # or the database directly.
  theme_rows <- reactive({
    req(input$theme)
    theme_dim_map[theme_dim_map$dataset == input$theme, , drop = FALSE]
  })

  # Resets the theme-scoped selectors to their defaults. Deliberately does
  # NOT rely on the input$geo_level observer below to do this via a
  # "national" reset - updateRadioButtons() is a no-op (no invalidation) if
  # geo_level is already "national" from the previous theme, which would
  # otherwise skip the Break down by choices getting rebuilt for the new
  # theme.
  observeEvent(input$theme, {
    rows <- theme_rows()
    available_ranks <- unique(unlist(rows$geo_ranks))
    session$sendCustomMessage("setGeoAvailability", c("national", available_ranks))
    updateRadioButtons(session, "geo_level", selected = "national")

    cats <- sort(unique(unlist(rows$categories)))
    cat_choices <- c("none", cats)
    names(cat_choices) <- c("None", cats)
    updateSelectInput(session, "cat_level", choices = cat_choices,
                       selected = if (length(cats) >= 1) cats[1] else "none")
  })

  # Reacts to the Geographic Aggregation *rank* changing (clicks, or the
  # server-driven reset to "national" on a theme switch above) -
  # repopulates the Geographic unit picker for that rank (via a
  # representative table sharing it - real places don't vary by which
  # sibling table is used to look them up), and re-scopes Break down by's
  # choices to categories that actually co-occur with this rank (matters
  # once a specific Geographic unit turns Break down by into the fill -
  # see the routing rule in plot_data() below; harmless while it's still
  # hidden).
  observeEvent(input$geo_level, {
    rows <- theme_rows()

    if (identical(input$geo_level, "national")) {
      updateSelectizeInput(session, "geo_unit", choices = c("All" = "All"), selected = "All", server = TRUE)
      cats <- sort(unique(unlist(rows$categories)))
    } else {
      rank_rows <- rows[vapply(rows$geo_ranks, function(s) input$geo_level %in% s, logical(1)), , drop = FALSE]
      cats <- sort(unique(unlist(rank_rows$categories)))
      idx <- if (nrow(rank_rows) >= 1) {
        cl <- rank_rows$classification[[1]]
        cl$level_index[match(input$geo_level, cl$geo_rank)]
      } else {
        NA_integer_
      }
      if (nrow(rank_rows) == 0 || is.na(idx)) {
        updateSelectizeInput(session, "geo_unit", choices = c("All" = "All"), selected = "All", server = TRUE)
      } else {
        rep_row <- rank_rows[1, ]
        units <- list_geo_units(con, rep_row$table_id, rep_row$n_levels, input$geo_level, idx)
        updateSelectizeInput(session, "geo_unit", choices = units, selected = "All", server = TRUE)
      }
    }

    cat_choices <- c("none", cats)
    names(cat_choices) <- c("None", cats)
    selected <- if (!is.null(input$cat_level) && input$cat_level %in% cats) {
      input$cat_level
    } else if (length(cats) >= 1) {
      cats[1]
    } else {
      "none"
    }
    updateSelectInput(session, "cat_level", choices = cat_choices, selected = selected)
  }, ignoreInit = TRUE)

  # Defensive fallback for the one narrow case constraint propagation
  # doesn't fully resolve on its own: a specific Geographic unit filter is
  # active (mode B - see match_candidates()) and the user picks a Break
  # down by category that doesn't co-occur with the current geo rank in
  # any table. Rather than leaving a dead-end selection, drop the place
  # filter back to "All" so the category choice stays honored.
  observeEvent(input$cat_level, {
    if (!identical(input$geo_unit %||% "All", "All")) {
      cands <- match_candidates(theme_rows(), input$geo_level, input$geo_unit, input$cat_level)
      if (nrow(cands) == 0) {
        updateSelectizeInput(session, "geo_unit", selected = "All", server = TRUE)
      }
    }
  }, ignoreInit = TRUE)

  # The set of tables consistent with the current Geo/Category selection,
  # ignoring Series - 1 row in the overwhelming majority of cases; more
  # than 1 means a genuine data ambiguity Series exists to resolve (see
  # match_candidates() in R/app_utils.R).
  series_candidates <- reactive({
    req(input$geo_level)
    match_candidates(theme_rows(), input$geo_level, input$geo_unit %||% "All", input$cat_level %||% "none")
  })

  # Keeps the (usually hidden) Series selector's choices in sync - value is
  # always the exact table_id (unambiguous even when two candidates'
  # series_label happen to collide), display text is series_label, falling
  # back to a year-range parenthetical if that's blank/duplicated.
  observe({
    cands <- series_candidates()
    ids <- unique(cands$table_id)
    needed <- length(ids) > 1
    session$sendCustomMessage("setSeriesNeeded", needed)
    if (!needed) return()

    rows <- cands[match(ids, cands$table_id), , drop = FALSE]
    display <- ifelse(nzchar(rows$series_label), rows$series_label,
                       sprintf("Series (%d-%d)", rows$min_year, rows$max_year))
    choices <- stats::setNames(rows$table_id, display)
    selected <- if (!is.null(input$series) && input$series %in% rows$table_id) input$series else rows$table_id[1]
    updateSelectInput(session, "series", choices = choices, selected = selected)
  })

  # The single table every other reactive below reads from - replaces the
  # old current_meta()/input$table. Falls back to the first candidate when
  # Series isn't shown (0 or 1 candidates) or holds a stale value.
  resolved_table <- reactive({
    cands <- series_candidates()
    if (!is.null(input$series) && input$series %in% cands$table_id) {
      cands <- cands[cands$table_id == input$series, , drop = FALSE]
    }
    req(nrow(cands) >= 1)
    cands[1, , drop = FALSE]
  })

  # This table's precomputed classify_level() output (see
  # build_theme_dimension_map()) - was recomputed per-table on every
  # reactive tick before; now just a lookup.
  level_classification <- reactive({
    resolved_table()$classification[[1]]
  })

  has_subtotals_current <- reactive({
    table_has_subtotals(con, resolved_table()$table_id)
  })

  observeEvent(resolved_table(), {
    m <- resolved_table()
    granularity_choices <- if (isTRUE(m$has_month)) c("Monthly", "Quarterly", "Annual") else "Annual"
    updateRadioButtons(session, "granularity", choices = granularity_choices,
                        selected = utils::tail(granularity_choices, 1))
    updateSliderInput(session, "years", min = m$min_year, max = m$max_year,
                       value = c(m$min_year, m$max_year))
  })

  # Routing rule: geography is the chart's fill dimension only when a real
  # rank is picked AND no specific unit narrows it - otherwise Break down
  # by (or "none"/Total) is the fill, and a specific unit (if any) becomes
  # a row filter instead (see plot_data() below). Exactly one axis is ever
  # the fill; never both, never faceted. Pulled out of plot_data() into its
  # own reactive so the Percentage-of-Total gating observer below can react
  # to the same resolved fill category without duplicating this logic.
  #
  # `input$cat_level`'s value is now a theme-wide *normalized category
  # name* (e.g. "Immigration Category" - see build_theme_dimension_map()),
  # not a level index - has to be looked up against the *resolved* table's
  # own classification to find which level_N it actually is there.
  category_level_r <- reactive({
    cl <- level_classification()
    geo_unit <- input$geo_unit %||% "All"
    cat_level <- input$cat_level %||% "none"
    geo_real <- !identical(input$geo_level, "national")
    geo_all_units <- identical(geo_unit, "All")
    if (geo_real && geo_all_units) {
      as.character(cl$level_index[match(input$geo_level, cl$geo_rank)])
    } else if (identical(cat_level, "none")) {
      "none"
    } else {
      idx <- cl$level_index[match(cat_level, cl$label_normalized)]
      if (is.na(idx)) "none" else as.character(idx)
    }
  })

  # Percentage of Total is meaningless (every bar would be exactly 100%)
  # whenever the resolved fill category is "None"/Total - only geography
  # (when it's the fill) or a real Break-down-by selection ever have more
  # than one segment to take a percentage of.
  observe({
    category_level <- category_level_r()
    allow_percent <- !(identical(category_level, "none") || identical(category_level, "total"))
    session$sendCustomMessage("setPercentAllowed", allow_percent)
    if (!allow_percent && identical(input$display_as, "percent")) {
      updateRadioButtons(session, "display_as", selected = "absolute")
    }
  })

  plot_data <- reactive({
    m <- resolved_table()
    req(input$granularity, input$years, input$top_n, input$geo_level)
    # guard against a stale granularity selection lingering mid-update
    valid_granularity <- if (isTRUE(m$has_month)) c("Monthly", "Quarterly", "Annual") else "Annual"
    req(input$granularity %in% valid_granularity)

    geo_unit <- input$geo_unit %||% "All"
    geo_real <- !identical(input$geo_level, "national")
    geo_all_units <- identical(geo_unit, "All")

    category_level <- category_level_r()
    category_level_label <- if (identical(category_level, "none") || identical(category_level, "total")) {
      NULL
    } else {
      m[[paste0("level_", category_level, "_label")]]
    }

    filter_prefix <- if (geo_real && !geo_all_units) parse_geo_unit(geo_unit) else character(0)
    filter_level <- length(filter_prefix)

    build_plot_data(
      con, table_id = m$table_id, n_levels = m$n_levels, level = category_level,
      granularity = input$granularity, year_range = input$years,
      is_stock = m$is_stock, top_n = input$top_n, has_month = m$has_month,
      level_label = category_level_label,
      filter_level = if (filter_level > 0) filter_level else NULL,
      filter_values = if (filter_level > 0) filter_prefix else NULL,
      has_subtotals = has_subtotals_current(),
      display_as = input$display_as %||% "absolute"
    )
  })

  output$plot_title <- renderText({
    m <- resolved_table()
    title <- m$table_title
    geo_unit <- input$geo_unit %||% "All"
    if (!identical(input$geo_level, "national") && !identical(geo_unit, "All")) {
      place <- utils::tail(parse_geo_unit(geo_unit), 1)
      title <- paste0(title, " — ", place)
    }
    if (isTRUE(m$is_stock)) {
      title <- paste(title, "— point-in-time snapshot, not summed across months")
    }
    title
  })

  output$source_citation <- renderUI({
    m <- resolved_table()
    table_citation_ui(m$table_id, theme_rows()$table_id)
  })

  output$plot <- renderPlotly({
    d <- plot_data()
    validate(need(nrow(d) > 0, "No data for this selection."))

    single_series <- nlevels(d$category) <= 1
    is_percent <- identical(input$display_as, "percent")
    value_fmt <- if (is_percent) function(v) paste0(round(v, 1), "%") else comma

    # Monthly x-axis labels are too dense to all fit without overlapping -
    # thin them to every 3rd period (quarterly spacing).
    x_breaks <- if (identical(input$granularity, "Monthly")) {
      lvls <- levels(d$period_display)
      lvls[seq(1, length(lvls), by = 3)]
    } else {
      waiver()
    }

    p <- ggplot(d, aes(
      x = period_display, y = value, fill = category,
      text = paste0(period_display, "<br>", category, ": ", value_fmt(value))
    )) +
      geom_col(position = "stack") +
      scale_x_discrete(breaks = x_breaks) +
      scale_y_continuous(labels = if (is_percent) function(v) paste0(v, "%") else comma) +
      labs(x = NULL, y = NULL, fill = NULL) +
      theme_bw() +
      theme(
        axis.text.x = element_text(angle = 45, hjust = 1),
        legend.position = if (single_series) "none" else "bottom",
        panel.grid.minor = element_blank()
      )

    if (!single_series) {
      p <- p + scale_fill_manual(values = category_colors(levels(d$category)))
    } else {
      p <- p + scale_fill_manual(values = "#0b4f6c")
    }

    ggplotly(p, tooltip = "text") |>
      layout(legend = list(orientation = "h", y = -0.3), margin = list(b = 100))
  })
}

shinyApp(ui, server)
