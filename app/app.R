# Canadian Immigration Statistics — Shiny app
#
# One theme ("dataset") selected via a sidebar pulldown. Each theme has one
# or more Series (a genuinely distinct population/program/metric, e.g.
# "All admissions" vs "Adoptions via PR") - always shown, since with
# duplication resolved at the pipeline level (see below) there's no longer
# any per-query table ambiguity left for a hidden selector to resolve.
# Within a Series: a temporal aggregation (Monthly / Quarterly / Annual,
# limited to what that series actually supports), a Geographic Aggregation
# level, and a category breakdown (Break down by, with up to two more
# "drill into..." levels when a facet nests that deep) - then renders a
# stacked longitudinal bar chart.
#
# This directory (app/) is the self-contained deployment unit for
# shinyapps.io (`rsconnect::deployApp("app")`) - everything it reads is
# inside app/, nothing reaches back into the data-prep tree one level up.
#
# Data comes from data/immigration.duckdb - built by the data-prep pipeline
# at the repo root (../data-raw/05_build_duckdb.R -> 06_build_label_lookups.R
# -> 08_build_series_facts.R) and copied here, not generated in place. See
# ../README.md for the full pipeline. This app reads exactly one table from
# it, `series_facts`: one row per genuinely distinct (theme, series,
# breakdown facet/depth, geography, period) fact, already deduplicated
# across every raw source table that contributes to it - many tables
# within one series independently publish the same underlying total (e.g.
# a province's grand total, once broken down by Sex, once by Occupation,
# once by CD/CSD) with slightly different suppression, and that
# duplication is resolved once, at the row level, by
# data-raw/08_build_series_facts.R - not here. This app never reads the
# raw `facts`/`catalog` tables that `series_facts` was built from.

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

# ---- series summary ---------------------------------------------------------
# One row per (theme, series, facet, geo_level) combination actually present
# in series_facts - what every selector in the sidebar is driven from.
# Computed once at startup (like `catalog` used to be) - see
# build_series_summary() in R/app_utils.R.
series_summary <- build_series_summary(con)

#' Translate the Geographic Aggregation radio's "national" sentinel to
#' series_facts' own "National" geo_level value; every other value (PT,
#' CMA, CD, CSD) already matches directly.
geo_level_query_value <- function(x) if (identical(x, "national")) "National" else x

# ---- source citation ------------------------------------------------------
# data/source_manifest.csv is a copy of the data-prep pipeline's
# data-raw/manifest.csv (see data-raw/05_build_duckdb.R), placed under the
# app's own data/ directory so the deployable app bundle (this app/
# directory) is self-contained and doesn't reach outside itself into the
# data-prep tree. Records each source table's CKAN resource (agency,
# format, direct file URL, dataset landing page) - joined back to whichever
# raw table_id(s) actually contributed to the currently-displayed cells
# (see series_source_table_ids() in R/app_utils.R) via the hash prefix in
# each one (extract_table_hash()) to build a citation for the bottom of the
# plot card.
manifest <- readr::read_csv("data/source_manifest.csv", show_col_types = FALSE,
                             col_types = readr::cols(last_modified_ckan = "c"))
source_lookup <- build_source_lookup(manifest)

#' Build the citation UI for the table_id(s) actually contributing to the
#' current view - usually one, but a merged "Total" view can span several
#' sibling source tables (see data-raw/08_build_series_facts.R). Any
#' synthetic/derived id (extract_table_hash() returns NA - e.g. the merged
#' refugees table) falls back to citing every other real table_id in
#' `theme_table_ids` instead (its own siblings, from the same theme).
table_citation_ui <- function(table_ids, theme_table_ids) {
  hashes <- vapply(table_ids, extract_table_hash, character(1))
  if (all(is.na(hashes))) {
    hashes <- vapply(theme_table_ids, extract_table_hash, character(1))
  }
  hashes <- unique(hashes[!is.na(hashes)])
  if (length(hashes) == 0) return(NULL)

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
      // series - the server recomputes this per series switch (see
      // build_series_summary() in R/app_utils.R and the input$series
      // observer in app.R).
      Shiny.addCustomMessageHandler('setGeoAvailability', function(available) {
        setRadioAvailability('geo_level', available);
      });
      // Percentage of Total is meaningless (always exactly 100%) whenever
      // the resolved view is a single unbroken-down bar - the server
      // recomputes this whenever the resolved scope changes and also
      // resets the selection back to Absolute Values if it was on
      // Percentage when this fires.
      Shiny.addCustomMessageHandler('setPercentAllowed', function(allowed) {
        setRadioAvailability('display_as', allowed ? ['absolute', 'percent'] : ['absolute']);
      });
      // Drive the conditionalPanels wrapping the cascading 'drill into...'
      // selectors - genuine Shiny inputs (not just UI toggles) so
      // `conditionalPanel`'s JS-evaluated condition can reference them
      // directly. Only rendered when the current facet's own nesting
      // actually goes that deep (see build_series_summary()'s
      // has_breakdown_2/3).
      Shiny.addCustomMessageHandler('setDrill1Needed', function(needed) {
        Shiny.setInputValue('drill_1_needed', needed);
      });
      Shiny.addCustomMessageHandler('setDrill2Needed', function(needed) {
        Shiny.setInputValue('drill_2_needed', needed);
      });
    "))
  ),
  sidebar = sidebar(
    width = 340,
    h6("Select Theme"),
    selectInput("theme", NULL, choices = THEME_CHOICES),
    h6("Series"),
    selectInput("series", NULL, choices = NULL),
    conditionalPanel(
      "input.geo_level != 'national'",
      h6("Geographic unit"),
      selectizeInput("geo_unit", NULL, choices = c("All" = "All"), options = list(server = TRUE))
    ),
    conditionalPanel(
      "input.geo_level == 'national' || input.geo_unit != 'All'",
      h6("Break down by"),
      selectInput("cat_level", NULL, choices = c("None" = "none")),
      conditionalPanel(
        "input.drill_1_needed",
        h6("Drill into"),
        selectInput("drill_1", NULL, choices = c("None" = "none"))
      ),
      conditionalPanel(
        "input.drill_1_needed && input.drill_2_needed",
        h6("Drill further"),
        selectInput("drill_2", NULL, choices = c("None" = "none"))
      )
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
    h6("Display as"),
    radioButtons("display_as", NULL,
                 choices = c("Absolute Values" = "absolute", "Percentage of Total" = "percent")),
    h6("Year Range"),
    sliderInput("years", NULL, min = 2000, max = 2026, value = c(2015, 2026), sep = ""),
    h6("Max categories shown (rest grouped as ‘Other’)"),
    numericInput("top_n", NULL,
                 value = 10, min = 2, max = 15),
    helpText("Note: IRCC/IRB suppress (“--”) any value between 0 and 5 to protect privacy; ",
             "suppressed values are excluded from sums, so totals may be understated. ",
             "The Suppressed Residual item in the plot indicates the difference between the ",
             "calculated sum of category values displayed and the total value contained in ",
             "the source data.")
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

  # This theme's rows from the precomputed series summary - every other
  # reactive below filters over this instead of re-querying series_facts.
  theme_series <- reactive({
    req(input$theme)
    series_summary[series_summary$theme == input$theme, , drop = FALSE]
  })

  # On theme change: populate the Series list (always shown - with
  # duplication resolved at the pipeline level, there's no longer any
  # per-query ambiguity left for a hidden selector to resolve; Series is
  # now a plain top-level choice, like Theme) and select the first one.
  observeEvent(input$theme, {
    opts <- sort(unique(theme_series()$series))
    display <- ifelse(nzchar(opts), opts, "(unnamed series)")
    updateSelectInput(session, "series", choices = stats::setNames(opts, display), selected = opts[1])
  })

  # This series' rows - drives Geographic Aggregation/Break down by choices.
  series_rows <- reactive({
    req(input$series)
    theme_series()[theme_series()$series == input$series, , drop = FALSE]
  })

  # Resets the series-scoped selectors to their defaults on every series
  # switch (including the theme-driven automatic first selection) -
  # updateRadioButtons() is a no-op (no invalidation) if geo_level is
  # already "national", which would otherwise skip Break down by's
  # choices getting rebuilt for the new series.
  observeEvent(input$series, {
    rows <- series_rows()
    available_ranks <- setdiff(unique(rows$geo_level), "National")
    session$sendCustomMessage("setGeoAvailability", c("national", available_ranks))
    updateRadioButtons(session, "geo_level", selected = "national")

    # geo_level defaults to National on every series switch, so Break down
    # by must be narrowed to facets with actual National-level rows here
    # too (see the geo_level observer below for why this can't just be
    # every facet the series has anywhere).
    national_facets <- rows$facet[rows$geo_level == "National"]
    facets <- sort(setdiff(unique(national_facets), "Total"))
    cat_choices <- c("none", facets)
    names(cat_choices) <- c("None", facets)
    # "None" resolves to facet = "Total" (see current_scope() below) - some
    # series (e.g. a Top-25-only ranking table, which never publishes a
    # grand-total row at all - see data-raw/08_build_series_facts.R) have no
    # "Total" facet whatsoever, so defaulting to "None" would open the
    # series on a guaranteed-blank chart. Default to the first real facet
    # instead whenever no Total exists; only fall back to "None" itself when
    # there's genuinely nothing else to show.
    has_total <- "Total" %in% national_facets
    default_facet <- if (has_total || length(facets) == 0) "none" else facets[1]
    updateSelectInput(session, "cat_level", choices = cat_choices, selected = default_facet)
  })

  # Reacts to the Geographic Aggregation *rank* changing (clicks, or the
  # server-driven reset to "national" on a series switch above) -
  # repopulates the Geographic unit picker for that rank (from the
  # series' own "Total" rows - real places don't depend on which specific
  # breakdown facet is chosen), and re-scopes Break down by's choices to
  # facets that actually reach this rank (matters once a specific
  # Geographic unit turns Break down by into the fill - see the routing
  # rule in current_scope() below; harmless while it's still hidden).
  observeEvent(input$geo_level, {
    rows <- series_rows()
    gl <- geo_level_query_value(input$geo_level)

    # Facets are narrowed to this rank specifically - a facet's rows can
    # exist at only some geo levels of a series (e.g. a table nested
    # under Province/Territory contributes its facet's rows only at
    # geo_level "PT", never "National"), same rule at every rank
    # including National, so Break down by never offers a facet with no
    # data at the currently-selected Geographic Aggregation.
    rank_rows <- rows[rows$geo_level == gl, , drop = FALSE]
    facets <- sort(setdiff(unique(rank_rows$facet), "Total"))
    has_total <- "Total" %in% rank_rows$facet

    if (identical(input$geo_level, "national")) {
      updateSelectizeInput(session, "geo_unit", choices = c("All" = "All"), selected = "All", server = TRUE)
    } else {
      total_row <- rank_rows[rank_rows$facet == "Total", , drop = FALSE]
      if (nrow(total_row) == 0) {
        updateSelectizeInput(session, "geo_unit", choices = c("All" = "All"), selected = "All", server = TRUE)
      } else {
        units <- list_series_geo_units(con, input$theme, input$series, "Total", gl, total_row$geo_depth[1])
        updateSelectizeInput(session, "geo_unit", choices = units, selected = "All", server = TRUE)
      }
    }

    cat_choices <- c("none", facets)
    names(cat_choices) <- c("None", facets)
    # Same "don't default to a guaranteed-blank Total" rule as the series
    # switch handler above - a rank change can newly land on a geo_level
    # this series has no Total facet at either (e.g. switching Geographic
    # Aggregation to a rank a Top-25-only ranking table only publishes real
    # breakdown rows for, never a grand total).
    selected <- if (!is.null(input$cat_level) && input$cat_level %in% facets) {
      input$cat_level
    } else if (has_total || length(facets) == 0) {
      "none"
    } else {
      facets[1]
    }
    updateSelectInput(session, "cat_level", choices = cat_choices, selected = selected)
  }, ignoreInit = TRUE)

  # Keeps the cascading "Drill into"/"Drill further" selectors in sync -
  # only shown when the chosen facet's own nesting goes that deep (see
  # build_series_summary()'s has_breakdown_2/3). Plain observe() (not
  # observeEvent(), and no ignoreInit) so this always evaluates at least
  # once at startup and whenever series/geo_level/cat_level change -
  # otherwise the client's drill_1_needed/drill_2_needed inputs would stay
  # permanently unset (Shiny's conditionalPanel treats an unset JS
  # variable as neither reliably true nor false) whenever an
  # updateSelectInput() call happens to leave cat_level's value unchanged
  # (e.g. it was already "none" going into a series switch).
  observe({
    rows <- series_rows()
    gl <- geo_level_query_value(input$geo_level)
    facet <- input$cat_level %||% "none"
    needs_drill1 <- FALSE
    if (!identical(facet, "none")) {
      match_row <- rows[rows$facet == facet & rows$geo_level == gl, , drop = FALSE]
      needs_drill1 <- nrow(match_row) >= 1 && isTRUE(match_row$has_breakdown_2[1])
    }
    session$sendCustomMessage("setDrill1Needed", needs_drill1)
    if (needs_drill1) {
      vals <- list_series_breakdown_values(con, input$theme, input$series, facet, gl)
      updateSelectInput(session, "drill_1", choices = c("None" = "none", stats::setNames(vals, vals)),
                          selected = "none")
    }
  })

  observe({
    rows <- series_rows()
    gl <- geo_level_query_value(input$geo_level)
    facet <- input$cat_level %||% "none"
    drill1 <- if (!is.null(input$drill_1) && !identical(input$drill_1, "none")) input$drill_1 else NULL
    needs_drill2 <- FALSE
    vals <- character(0)
    if (!is.null(drill1)) {
      match_row <- rows[rows$facet == facet & rows$geo_level == gl, , drop = FALSE]
      if (nrow(match_row) >= 1 && isTRUE(match_row$has_breakdown_3[1])) {
        vals <- list_series_breakdown_values(con, input$theme, input$series, facet, gl, drill1)
        needs_drill2 <- length(vals) > 0
      }
    }
    session$sendCustomMessage("setDrill2Needed", needs_drill2)
    if (needs_drill2) {
      updateSelectInput(session, "drill_2", choices = c("None" = "none", stats::setNames(vals, vals)),
                          selected = "none")
    }
  })

  # Defensive fallback for the one narrow case constraint propagation
  # doesn't fully resolve on its own: a specific Geographic unit filter is
  # active and the user picks a Break down by facet that doesn't reach
  # this rank. Rather than leaving a dead-end selection, drop the place
  # filter back to "All" so the facet choice stays honored (facets are
  # already narrowed to this rank in the geo_level observer above, so
  # this should rarely fire - kept as a safety net, same spirit as before).
  observeEvent(input$cat_level, {
    if (!identical(input$geo_unit %||% "All", "All")) {
      rows <- series_rows()
      gl <- geo_level_query_value(input$geo_level)
      facet_query <- if (identical(input$cat_level %||% "none", "none")) "Total" else input$cat_level
      if (nrow(rows[rows$facet == facet_query & rows$geo_level == gl, , drop = FALSE]) == 0) {
        updateSelectizeInput(session, "geo_unit", selected = "All", server = TRUE)
      }
    }
  }, ignoreInit = TRUE)

  # Routing rule: geography is the chart's fill dimension only when a real
  # rank is picked AND no specific unit narrows it - otherwise Break down
  # by (or "none"/Total) is the fill, and a specific unit (if any) becomes
  # a row filter instead (see build_series_plot_data() below). Exactly one
  # axis is ever the fill; never both, never faceted. Resolves to the one
  # (series, facet, geo_level) row in series_summary this view reads from.
  current_scope <- reactive({
    req(input$series, input$geo_level)
    rows <- series_rows()
    geo_real <- !identical(input$geo_level, "national")
    geo_all_units <- identical(input$geo_unit %||% "All", "All")
    gl <- geo_level_query_value(input$geo_level)
    facet_query <- if (geo_real && geo_all_units) {
      "Total"
    } else if (identical(input$cat_level %||% "none", "none")) {
      "Total"
    } else {
      input$cat_level
    }
    match_row <- rows[rows$facet == facet_query & rows$geo_level == gl, , drop = FALSE]
    req(nrow(match_row) >= 1)
    match_row[1, , drop = FALSE]
  })

  observeEvent(current_scope(), {
    scope <- current_scope()
    granularity_choices <- if (isTRUE(scope$has_month)) c("Monthly", "Quarterly", "Annual") else "Annual"
    updateRadioButtons(session, "granularity", choices = granularity_choices,
                        selected = utils::tail(granularity_choices, 1))
    updateSliderInput(session, "years", min = scope$min_year, max = scope$max_year,
                       value = c(scope$min_year, scope$max_year))
  })

  # Percentage of Total is meaningless (every bar would be exactly 100%)
  # whenever the resolved view is a single unbroken-down "Total" bar -
  # only geography (when it's the fill) or a real Break-down-by selection
  # ever have more than one segment to take a percentage of.
  observe({
    scope <- current_scope()
    single_bar <- identical(scope$facet, "Total") &&
      (identical(scope$geo_level, "National") || !identical(input$geo_unit %||% "All", "All"))
    allow_percent <- !single_bar
    session$sendCustomMessage("setPercentAllowed", allow_percent)
    if (!allow_percent && identical(input$display_as, "percent")) {
      updateRadioButtons(session, "display_as", selected = "absolute")
    }
  })

  plot_data <- reactive({
    scope <- current_scope()
    req(input$granularity, input$years, input$top_n)
    valid_granularity <- if (isTRUE(scope$has_month)) c("Monthly", "Quarterly", "Annual") else "Annual"
    req(input$granularity %in% valid_granularity)

    geo_unit <- input$geo_unit %||% "All"
    geo_real <- !identical(input$geo_level, "national")
    geo_all_units <- identical(geo_unit, "All")
    filter_prefix <- if (geo_real && !geo_all_units) parse_geo_unit(geo_unit) else character(0)

    drill1 <- if (!is.null(input$drill_1) && !identical(input$drill_1, "none")) input$drill_1 else NULL
    drill2 <- if (!is.null(input$drill_2) && !identical(input$drill_2, "none")) input$drill_2 else NULL

    build_series_plot_data(
      con, theme = input$theme, series = input$series,
      facet = scope$facet, geo_level = scope$geo_level, geo_depth = scope$geo_depth,
      granularity = input$granularity, year_range = input$years, is_stock = scope$is_stock,
      top_n = input$top_n, display_as = input$display_as %||% "absolute",
      geo_unit_prefix = filter_prefix, drill_1 = drill1, drill_2 = drill2
    )
  })

  output$plot_title <- renderText({
    scope <- current_scope()
    # Theme -> Series -> Breakdown -> Drill into -> Drill further, each
    # segment only present when it's actually adding information beyond the
    # one before it (a "Total" facet contributes nothing to say, and the
    # drill segments only exist once the user has actually drilled).
    parts <- c(unname(DATASET_LABELS[input$theme]), input$series)
    if (!identical(scope$facet, "Total")) parts <- c(parts, scope$facet)
    drill1 <- if (!is.null(input$drill_1) && !identical(input$drill_1, "none")) input$drill_1 else NULL
    drill2 <- if (!is.null(input$drill_2) && !identical(input$drill_2, "none")) input$drill_2 else NULL
    if (!is.null(drill1)) parts <- c(parts, drill1)
    if (!is.null(drill2)) parts <- c(parts, drill2)
    title <- paste(parts, collapse = " → ")
    geo_unit <- input$geo_unit %||% "All"
    if (!identical(input$geo_level, "national") && !identical(geo_unit, "All")) {
      place <- utils::tail(parse_geo_unit(geo_unit), 1)
      title <- paste0(title, " — ", place)
    }
    if (isTRUE(scope$is_stock)) {
      title <- paste(title, "— point-in-time snapshot, not summed across months")
    }
    title
  })

  output$source_citation <- renderUI({
    scope <- current_scope()
    ids <- series_source_table_ids(con, input$theme, input$series, scope$facet, scope$geo_level)
    theme_ids <- series_source_table_ids(con, input$theme, input$series)
    table_citation_ui(ids, theme_ids)
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
