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
source("R/i18n.R")

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

# French twin of DATASET_LABELS, same `dataset` slugs as names. Sourced from
# CKAN's own `title_translated$fr` for each underlying package_show record
# (permanent_residents, study_permit_holders, tr_to_pr_transition,
# asylum_claimants, and the temporary_workers package this app splits into
# _imp/_tfwp - see split_temporary_workers()) - not a guess. `refugees` is
# this app's own synthetic merge of rpd_decisions + rpd_1997_2021 (no single
# CKAN package of its own), translated the same way DATASET_LABELS's English
# "Refugees" was chosen (short, generic, matching the two source packages'
# shared subject).
DATASET_LABELS_FR <- c(
  permanent_residents    = "Résidents permanents",
  temporary_workers_imp  = "Programme de mobilité internationale",
  temporary_workers_tfwp = "Programme des travailleurs étrangers temporaires",
  study_permit_holders   = "Titulaires d'un permis d'études",
  tr_to_pr_transition    = "Transition de résident temporaire à résident permanent",
  asylum_claimants       = "Demandeurs d'asile",
  refugees               = "Réfugiés"
)

# selectInput's named-vector convention is names = displayed label, values =
# option value - the reverse of DATASET_LABELS (slug = name, label = value).
THEME_CHOICES <- setNames(names(DATASET_LABELS), DATASET_LABELS)
THEME_CHOICES_FR <- setNames(names(DATASET_LABELS_FR), DATASET_LABELS_FR)

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
table_citation_ui <- function(table_ids, theme_table_ids, lang = "en") {
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
      sprintf(tr("citation_last_updated", lang), rows$updated_at[i]),
      if (i < nrow(rows)) "; " else NULL
    )
  })
  dataset_links <- lapply(seq_along(dataset_urls), function(i) {
    tagList(
      tags$a(href = dataset_urls[i], target = "_blank", rel = "noopener",
             if (length(dataset_urls) > 1) sprintf("%s %d", tr("citation_dataset_page", lang), i)
             else tr("citation_dataset_page", lang)),
      if (i < length(dataset_urls)) ", " else NULL
    )
  })

  tags$small(
    class = "text-muted",
    tr("citation_source", lang), agency, tr("citation_portal", lang),
    source_links, " (", dataset_links, "). ",
    sprintf(tr("citation_last_accessed", lang), format(Sys.Date(), "%Y-%m-%d"))
  )
}

# ---- About page -----------------------------------------------------------
# Static content (doesn't depend on any input), so it's read and rendered to
# HTML once at startup rather than per-session, for each language. ABOUT_fr.md
# is a hand-translated sibling (genuine long-form prose - not derived from
# STRINGS/i18n.R, which only covers short chrome strings).
#
# {{N_TABLES}} is substituted with the live catalog row count before
# markdown conversion - the table count changes as tables are added/
# excluded across pipeline runs, and a hand-typed number here has already
# gone stale once (the page said "85" when the catalog actually held 71).
n_tables_text <- as.character(dbGetQuery(con, "SELECT COUNT(*) n FROM catalog")$n)
about_html_en <- markdown(gsub("{{N_TABLES}}",
  n_tables_text, paste(readLines("ABOUT.md", warn = FALSE), collapse = "\n"), fixed = TRUE))
about_html_fr <- if (file.exists("ABOUT_fr.md")) {
  markdown(gsub("{{N_TABLES}}",
    n_tables_text, paste(readLines("ABOUT_fr.md", warn = FALSE), collapse = "\n"), fixed = TRUE))
} else {
  about_html_en
}

# ---- UI ----------------------------------------------------------------

ui <- page_sidebar(
  title = div(
    class = "d-flex justify-content-between align-items-center w-100",
    h1(
      id = "app_title", class = "bslib-page-title navbar-brand",
      # "MigraScope" is the brand name and never changes with language -
      # only the descriptive suffix after it does (app_title_suffix,
      # swapped via the setLang custom message below, which retargets
      # #app_title_suffix's own textContent and so never touches this
      # sibling span).
      tags$span("MigraScope", class = "brand-name"),
      " | ",
      tags$span(tr("app_title_suffix"), id = "app_title_suffix", class = "brand-suffix")
    ),
    div(
      class = "d-flex gap-2 align-items-center",
      actionButton("lang_toggle", tr("lang_toggle_to_fr"), class = "btn-sm btn-outline-light"),
      actionButton("go_plot", tr("nav_visualize"), class = "btn-sm btn-outline-light"),
      actionButton("go_about", tr("nav_about"), class = "btn-sm btn-outline-light")
    )
  ),
  # `title` is now a tag (buttons alongside the heading), not a plain
  # string - bslib infers the browser tab title by extracting all text
  # from it otherwise, which would pull in the button labels too.
  window_title = "MigraScope | Canadian Immigration Statistics Visualizer",
  # heading_font matches app/www/custom.css's existing "Noto Sans"
  # font-family rules for h4/h5/h6/the navbar title (those were previously
  # a no-op fallback to generic `serif` since nothing actually loaded Noto
  # Sans from Google Fonts until now). Noto Serif is loaded separately
  # below (a plain Google Fonts <link>, not font_google()) purely for the
  # "MigraScope" brand mark - bs_theme()'s base/heading_font both stay
  # Noto Sans, the font used everywhere else in the app.
  theme = bs_theme(version = 5, primary = "#0b4f6c",
                    base_font = font_google("Noto Sans"),
                    heading_font = font_google("Noto Sans")),
  tags$head(
    tags$link(rel = "stylesheet",
               href = "https://fonts.googleapis.com/css2?family=Noto+Serif:wght@700&family=Noto+Sans:wght@300&display=swap"),
    # A cache-busting query string keyed to the file's own mtime - without
    # one, a browser that already cached an older custom.css (e.g. from a
    # previous deploy) can keep serving those stale styles indefinitely
    # after a redeploy changes the file's content but not its URL.
    tags$link(rel = "stylesheet", type = "text/css",
               href = paste0("custom.css?v=", as.integer(file.info("www/custom.css")$mtime))),
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
      // event), this only ever removes options from being choosable. A
      // disabled native radio gives no feedback at all when clicked (no
      // event, no visual change), which reads as nothing happens rather
      // than this option isn't available - a title tooltip on the label
      // makes the reason visible on hover instead of a silent no-op.
      function setRadioAvailability(inputName, available, disabledTitle) {
        document.querySelectorAll('input[name=\"' + inputName + '\"]').forEach(function(input) {
          var ok = available.indexOf(input.value) !== -1;
          input.disabled = !ok;
          var label = input.closest('label') || input.parentElement;
          if (label) {
            label.classList.toggle('text-muted', !ok);
            if (!ok && disabledTitle) {
              label.title = disabledTitle;
            } else {
              label.removeAttribute('title');
            }
          }
        });
      }
      // Which Geographic Aggregation ranks are available for the current
      // series - the server recomputes this per series switch (see
      // build_series_summary() in R/app_utils.R and the input$series
      // observer in app.R).
      Shiny.addCustomMessageHandler('setGeoAvailability', function(msg) {
        setRadioAvailability('geo_level', msg.available, msg.disabledTitle);
      });
      // Retargets a radioButtons group's visible option text in place
      // (the <span> Shiny renders next to each <input>), without touching
      // the input elements themselves - unlike updateRadioButtons(), which
      // rebuilds the whole group's DOM from scratch and would silently wipe
      // out the disabled/title state setRadioAvailability just applied (the
      // two custom messages and the updateRadioButtons() call all land in
      // the same Shiny message batch, and updateRadioButtons's own DOM
      // rebuild isn't guaranteed to run before this handler). Used by the
      // lang() switch below for geo_level/display_as, whose *values* never
      // change - only their displayed label text does.
      function setRadioLabels(inputName, labels) {
        document.querySelectorAll('input[name=\"' + inputName + '\"]').forEach(function(input) {
          if (!Object.prototype.hasOwnProperty.call(labels, input.value)) return;
          var label = input.closest('label') || input.parentElement;
          var span = label && label.querySelector('span');
          if (span) span.textContent = labels[input.value];
        });
      }
      Shiny.addCustomMessageHandler('setRadioLabels', function(msg) {
        setRadioLabels(msg.inputName, msg.labels);
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
      // Swaps textContent on every static-chrome element tagged with an id
      // this app recognizes - covers headers/buttons/help text/title that
      // never go through a render*()/update*Input() call, so have no other
      // way to react to a language toggle. `strings` is a flat {id: text}
      // map built server-side from R/i18n.R's STRINGS for whichever
      // language was just selected (see the lang_toggle observer below).
      Shiny.addCustomMessageHandler('setLang', function(strings) {
        Object.keys(strings).forEach(function(id) {
          var el = document.getElementById(id);
          if (el) el.textContent = strings[id];
        });
        document.documentElement.lang = strings['__lang'] || 'en';
      });
    "))
  ),
  sidebar = sidebar(
    width = 340,
    h6(tr("theme_label"), id = "lbl_theme"),
    selectInput("theme", NULL, choices = THEME_CHOICES),
    h6(tr("series_label"), id = "lbl_series"),
    selectInput("series", NULL, choices = NULL),
    conditionalPanel(
      "input.geo_level != 'national'",
      h6(tr("geo_unit_label"), id = "lbl_geo_unit"),
      selectizeInput("geo_unit", NULL, choices = c("All" = "All"), options = list(server = TRUE))
    ),
    conditionalPanel(
      "input.geo_level == 'national' || input.geo_unit != 'All'",
      h6(tr("breakdown_label"), id = "lbl_breakdown"),
      selectInput("cat_level", NULL, choices = c("None" = "none")),
      conditionalPanel(
        "input.drill_1_needed",
        h6(tr("drill1_label"), id = "lbl_drill1"),
        selectInput("drill_1", NULL, choices = c("None" = "none"))
      ),
      conditionalPanel(
        "input.drill_1_needed && input.drill_2_needed",
        h6(tr("drill2_label"), id = "lbl_drill2"),
        selectInput("drill_2", NULL, choices = c("None" = "none"))
      )
    ),
    h6(tr("granularity_label"), id = "lbl_granularity"),
    radioButtons("granularity", NULL, choices = "Annual"),
    h6(tr("geo_agg_label"), id = "lbl_geo_agg"),
    radioButtons("geo_level", NULL, choices = c(
      "National" = "national",
      "Province/Territory" = "PT",
      stats::setNames("CMA", tr("cma")),
      stats::setNames("CD", tr("cd")),
      stats::setNames("CSD", tr("csd"))
    ), selected = "national"),
    h6(tr("display_as_label"), id = "lbl_display_as"),
    radioButtons("display_as", NULL,
                 choices = c("Absolute Values" = "absolute", "Percentage of Total" = "percent")),
    h6(tr("year_range_label"), id = "lbl_year_range"),
    sliderInput("years", NULL, min = 2000, max = 2026, value = c(2015, 2026), sep = ""),
    h6(tr("top_n_label"), id = "lbl_top_n"),
    numericInput("top_n", NULL,
                 value = 10, min = 2, max = 15),
    helpText(id = "lbl_suppression_note", tr("suppression_note"))
  ),
  # navset_hidden()'s own markup (plain Bootstrap .tabbable/.tab-content/
  # .tab-pane divs, via shiny::tabsetPanel_()) isn't part of bslib's fill
  # system at all, so a percentage-height card inside it has nothing to
  # size against and collapses to 0. as_fill_carrier(x) (no css_selector)
  # only ever tags `x`'s own root tag(s), not arbitrary descendants - and
  # navset_hidden()'s actual root here is the wrapping div below, not
  # .tabbable/.tab-content/.tab-pane nested inside it - so each of those
  # three needs its own explicit css_selector pass (bslib/htmltools doesn't
  # support comma-separated selectors) to get the same fill-item +
  # fill-container roles page_sidebar's own main area already has,
  # propagating fillable height all the way down to the plot card.
  as_fill_carrier(
    as_fill_carrier(
      as_fill_carrier(
        as_fill_carrier(div(navset_hidden(
          id = "main_view",
          nav_panel(
            "plot",
            card(
              full_screen = TRUE,
              card_header(textOutput("plot_title")),
              plotlyOutput("plot", height = "100%"),
              card_footer(uiOutput("source_citation"))
            )
          ),
          nav_panel(
            "about",
            card(
              full_screen = TRUE,
              card_header(tr("about_page_title"), id = "lbl_about_header"),
              div(class = "p-4", uiOutput("about_content"))
            )
          )
        ))),
        css_selector = ".tabbable"
      ),
      css_selector = ".tab-content"
    ),
    css_selector = ".tab-pane"
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

  # ---- language switcher ----------------------------------------------------
  # The one piece of session state this app didn't have before (everything
  # else is plain input-derived reactives) - every language-aware
  # render*()/update*Input() call below reads this. Static chrome (headers,
  # buttons, help text - anything with no other reason to re-render on its
  # own) is instead swapped client-side via the "setLang" custom message,
  # rather than moving the whole static sidebar into renderUI (see the ids
  # tagged throughout the `ui <- page_sidebar(...)` block above).
  lang <- reactiveVal("en")
  # Track the current *set* of English choice values (as opposed to their
  # displayed label) for the two dropdowns whose choices are built inside
  # observeEvent() blocks keyed on input$theme/input$series/input$geo_level -
  # observeEvent() only reacts to its own event expression, not to lang()
  # changing on its own, so the language-switch observer below re-issues
  # each dropdown's already-current choice set with newly translated labels
  # (same pattern as granularity_choices_en() further down).
  series_choices_en <- reactiveVal(character(0))
  cat_choices_en <- reactiveVal(character(0))
  observeEvent(input$lang_toggle, lang(if (identical(lang(), "en")) "fr" else "en"))

  observeEvent(lang(), {
    l <- lang()
    updateActionButton(session, "lang_toggle", label = tr("lang_toggle_to_fr", l))
    updateActionButton(session, "go_plot", label = tr("nav_visualize", l))
    updateActionButton(session, "go_about", label = tr("nav_about", l))
    session$sendCustomMessage("setLang", list(
      "__lang"               = l,
      app_title_suffix        = tr("app_title_suffix", l),
      lbl_theme                = tr("theme_label", l),
      lbl_series               = tr("series_label", l),
      lbl_geo_unit              = tr("geo_unit_label", l),
      lbl_breakdown             = tr("breakdown_label", l),
      lbl_drill1                = tr("drill1_label", l),
      lbl_drill2                = tr("drill2_label", l),
      lbl_granularity           = tr("granularity_label", l),
      lbl_geo_agg               = tr("geo_agg_label", l),
      lbl_display_as            = tr("display_as_label", l),
      lbl_year_range            = tr("year_range_label", l),
      lbl_top_n                 = tr("top_n_label", l),
      lbl_suppression_note      = tr("suppression_note", l),
      lbl_about_header          = tr("about_page_title", l)
    ))
    # Radio-button CHOICE labels (as opposed to the section header above
    # each one) aren't plain static text - they're rebuilt via
    # update*Input() the same way every other reactive choice set already
    # is, so a language change just re-issues the same update with
    # translated labels, preserving whichever value is currently selected.
    updateSelectInput(session, "theme",
                       choices = if (identical(l, "fr")) THEME_CHOICES_FR else THEME_CHOICES,
                       selected = input$theme)
    if (length(series_choices_en()) > 0) {
      opts <- series_choices_en()
      display <- ifelse(nzchar(opts), opts, "(unnamed series)")
      updateSelectInput(session, "series",
                         choices = stats::setNames(opts, translate_vec(con, display, "series", l)),
                         selected = input$series)
    }
    if (length(cat_choices_en()) > 0) {
      opts <- cat_choices_en()
      is_none <- opts == "none"
      display <- opts
      display[!is_none] <- translate_vec(con, opts[!is_none], "facet", l)
      display[is_none] <- tr("none_choice", l)
      updateSelectInput(session, "cat_level", choices = stats::setNames(opts, display),
                         selected = input$cat_level)
    }
    # geo_level/display_as values never change on a language switch - only
    # their displayed text does - so retarget label text in place
    # (setRadioLabels) rather than updateRadioButtons(), which would rebuild
    # the group's DOM and wipe the disabled/title state setGeoAvailability
    # applied for the current series (see setRadioLabels' JS comment above).
    session$sendCustomMessage("setRadioLabels", list(
      inputName = "geo_level",
      labels = list(national = tr("national", l), PT = tr("province_territory", l),
                    CMA = tr("cma", l), CD = tr("cd", l), CSD = tr("csd", l))
    ))
    # setRadioLabels above only retargets label text, leaving disabled/title
    # state untouched - but the disabled tooltip text itself is language-
    # dependent, so re-send it here (harmless no-op on already-enabled
    # options; setRadioAvailability only ever sets/clears `title`).
    if (!is.null(input$series)) {
      rows <- series_rows()
      available_ranks <- setdiff(unique(rows$geo_level), "National")
      session$sendCustomMessage("setGeoAvailability", list(
        available = c("national", available_ranks),
        disabledTitle = tr("geo_not_available", l)
      ))
    }
    session$sendCustomMessage("setRadioLabels", list(
      inputName = "display_as",
      labels = list(absolute = tr("absolute_values", l), percent = tr("percentage_total", l))
    ))
    # Granularity's *value* is the literal English word itself (unlike
    # geo_level/display_as, which already separate a stable value from its
    # label) - build_series_plot_data()/aggregate_series() check
    # input$granularity against "Monthly"/"Quarterly"/"Annual" directly, so
    # those values stay English; only the displayed label is translated,
    # via a named-choices vector (label = value), same technique as
    # geo_level above. The valid set itself depends on the current series
    # (has_month) - tracked in granularity_choices_en() (updated alongside
    # the existing current_scope_raw() observer below) rather than guessed.
    updateRadioButtons(session, "granularity",
                        choices = stats::setNames(granularity_choices_en(),
                                                    vapply(granularity_choices_en(), function(g) {
                                                      tr(tolower(g), l)
                                                    }, character(1))),
                        selected = input$granularity)
  }, ignoreInit = TRUE)

  output$about_content <- renderUI({
    if (identical(lang(), "fr")) about_html_fr else about_html_en
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
    ts <- theme_series()
    opts <- sort(unique(ts$series))
    display <- ifelse(nzchar(opts), opts, "(unnamed series)")

    # Alphabetical order is an arbitrary pick for which series opens by
    # default - it can land on a series that is a narrow/ambiguous cut
    # (e.g. an annual-only snapshot) just because its name sorts first.
    # Score each series by how much it actually offers (more geo/breakdown
    # coverage, monthly data, longer history) and default to the richest
    # one instead; alphabetical order only breaks ties.
    scored <- ts |>
      dplyr::group_by(.data$series) |>
      dplyr::summarise(
        n_scope       = dplyr::n(),
        max_geo_depth = max(.data$geo_depth),
        any_breakdown = max(.data$has_breakdown_2 | .data$has_breakdown_3),
        any_month     = max(.data$has_month),
        year_span     = max(.data$max_year) - min(.data$min_year),
        .groups = "drop"
      ) |>
      dplyr::arrange(dplyr::desc(.data$n_scope), dplyr::desc(.data$max_geo_depth),
                      dplyr::desc(.data$any_breakdown), dplyr::desc(.data$any_month),
                      dplyr::desc(.data$year_span), .data$series)

    series_choices_en(opts)
    updateSelectInput(session, "series",
                       choices = stats::setNames(opts, translate_vec(con, display, "series", lang())),
                       selected = scored$series[1])
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
    session$sendCustomMessage("setGeoAvailability", list(
      available = c("national", available_ranks),
      disabledTitle = tr("geo_not_available", lang())
    ))
    updateRadioButtons(session, "geo_level", selected = "national")

    # geo_level defaults to National on every series switch, so Break down
    # by must be narrowed to facets with actual National-level rows here
    # too (see the geo_level observer below for why this can't just be
    # every facet the series has anywhere).
    national_facets <- rows$facet[rows$geo_level == "National"]
    facets <- sort(setdiff(unique(national_facets), "Total"))
    # "None" resolves to facet = "Total" (see current_scope() below) - some
    # series (e.g. a Top-25-only ranking table, which never publishes a
    # grand-total row at all - see data-raw/08_build_series_facts.R) have no
    # "Total" facet whatsoever, so offering "None" would open (or let a user
    # pick their way into) a guaranteed-blank chart. Only offer "None" when
    # a Total facet actually exists; otherwise the real facets are the only
    # choices, and default to the first one instead.
    has_total <- "Total" %in% national_facets
    # If there's neither a Total facet nor any real facet at all, "None" is
    # kept as the only (still blank) choice - genuinely nothing else to show.
    offer_none <- has_total || length(facets) == 0
    cat_choices <- if (offer_none) c("none", facets) else facets
    cat_choices_en(cat_choices)
    display_names <- translate_vec(con, facets, "facet", lang())
    names(cat_choices) <- if (offer_none) c(tr("none_choice", lang()), display_names) else display_names
    default_facet <- if (offer_none) "none" else facets[1]
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
      # Places are normally enumerated from this rank's "Total" rows (real
      # places don't depend on which breakdown facet is chosen), but some
      # series (e.g. a Top-25-only ranking table) have no Total facet at
      # this rank at all - falling back to just "All" there would hide
      # every real place behind a Geographic Aggregation rank that looks
      # selectable but is actually empty. Fall back to enumerating from
      # whichever real facet this rank does have instead.
      geo_source_row <- rank_rows[rank_rows$facet == "Total", , drop = FALSE]
      if (nrow(geo_source_row) == 0 && length(facets) > 0) {
        geo_source_row <- rank_rows[rank_rows$facet == facets[1], , drop = FALSE]
      }
      if (nrow(geo_source_row) == 0) {
        updateSelectizeInput(session, "geo_unit", choices = c("All" = "All"), selected = "All", server = TRUE)
      } else {
        units <- list_series_geo_units(con, input$theme, input$series, geo_source_row$facet[1], gl,
                                         geo_source_row$geo_depth[1])
        # "All" units only resolves to real data when a Total facet exists
        # at this rank (current_scope()'s routing rule always requests the
        # Total facet whenever a real rank is picked with "All" units) - for
        # a series with no Total facet here, "All" would silently produce a
        # blank chart until the user manually narrows to a specific place.
        # Default straight to the first real place in that case instead.
        default_unit <- if (has_total || length(units) < 2) "All" else units[[2]]
        updateSelectizeInput(session, "geo_unit", choices = units, selected = default_unit, server = TRUE)
      }
    }

    # Same "don't offer a guaranteed-blank Total" rule as the series switch
    # handler above - a rank change can newly land on a geo_level this
    # series has no Total facet at either (e.g. switching Geographic
    # Aggregation to a rank a Top-25-only ranking table only publishes real
    # breakdown rows for, never a grand total).
    offer_none <- has_total || length(facets) == 0
    cat_choices <- if (offer_none) c("none", facets) else facets
    cat_choices_en(cat_choices)
    display_names <- translate_vec(con, facets, "facet", lang())
    names(cat_choices) <- if (offer_none) c(tr("none_choice", lang()), display_names) else display_names
    selected <- if (!is.null(input$cat_level) && input$cat_level %in% facets) {
      input$cat_level
    } else if (offer_none) {
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
      # Preserve the current selection if it's still a valid option under
      # this facet (true both when this fires from a genuine facet/series
      # change where the old value happens to still apply, and when it
      # fires purely from a language toggle, where `vals` itself is
      # unchanged) - only reset to "none" when the old value no longer
      # applies, same as before.
      selected <- if (!is.null(input$drill_1) && input$drill_1 %in% vals) input$drill_1 else "none"
      display <- translate_vec(con, vals, "breakdown_2", lang())
      updateSelectInput(session, "drill_1",
                         choices = c(stats::setNames("none", tr("none_choice", lang())), stats::setNames(vals, display)),
                         selected = selected)
    } else if (!is.null(input$drill_1) && !identical(input$drill_1, "none")) {
      # drill_1's own conditionalPanel just hides the selector when not
      # needed (e.g. Break down by reset to None, or a specific geo_unit
      # narrowed the facet away) - Shiny inputs keep their last value
      # regardless of visibility, so without this reset a stale drill_1
      # (e.g. "India" from a previous facet) silently keeps filtering
      # build_series_plot_data()'s query (app.R below, ~line 822) even
      # though the control is gone, producing a false "No data" instead of
      # the Total-level data the visible controls promise.
      updateSelectInput(session, "drill_1", choices = c("None" = "none"), selected = "none")
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
      selected <- if (!is.null(input$drill_2) && input$drill_2 %in% vals) input$drill_2 else "none"
      display <- translate_vec(con, vals, "breakdown_3", lang())
      updateSelectInput(session, "drill_2",
                         choices = c(stats::setNames("none", tr("none_choice", lang())), stats::setNames(vals, display)),
                         selected = selected)
    } else if (!is.null(input$drill_2) && !identical(input$drill_2, "none")) {
      # Same stale-value reset as drill_1's observer above, for the same
      # reason - drill_2 must not keep filtering once hidden/not applicable.
      updateSelectInput(session, "drill_2", choices = c("None" = "none"), selected = "none")
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
  # Renamed to *_raw + debounced (see plot_data below for why): this reactive
  # sits at the bottom of a long chain of update*Input() calls that each
  # take a server->client->server round trip (theme -> series -> geo_level
  # -> cat_level/geo_unit -> drill_1/drill_2), so a single user click can
  # make it (and everything downstream of it) recompute several times in
  # quick succession - visible as the whole plot/title/citation flashing
  # repeatedly instead of updating once. The two observers just below key
  # off current_scope_raw() (not the debounced current_scope()), since they
  # reset *inputs* (granularity/years/display_as choices) and should react
  # immediately rather than lag behind a render-oriented debounce.
  current_scope_raw <- reactive({
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
  current_scope <- shiny::debounce(current_scope_raw, millis = 400)

  # Tracks the current *set* of valid English granularity values (as
  # opposed to their displayed label) so the language-switch observer above
  # can rebuild the same set with translated labels without needing to know
  # anything about series/has_month itself.
  granularity_choices_en <- reactiveVal(c("Annual"))

  observeEvent(current_scope_raw(), {
    scope <- current_scope_raw()
    granularity_choices <- if (isTRUE(scope$has_month)) c("Monthly", "Quarterly", "Annual") else "Annual"
    granularity_choices_en(granularity_choices)
    updateRadioButtons(session, "granularity",
                        choices = stats::setNames(granularity_choices,
                                                    vapply(granularity_choices, function(g) tr(tolower(g), lang()), character(1))),
                        selected = utils::tail(granularity_choices, 1))
    updateSliderInput(session, "years", min = scope$min_year, max = scope$max_year,
                       value = c(scope$min_year, scope$max_year))
  })

  # Percentage of Total is meaningless (every bar would be exactly 100%)
  # whenever the resolved view is a single unbroken-down "Total" bar -
  # only geography (when it's the fill) or a real Break-down-by selection
  # ever have more than one segment to take a percentage of.
  observe({
    scope <- current_scope_raw()
    single_bar <- identical(scope$facet, "Total") &&
      (identical(scope$geo_level, "National") || !identical(input$geo_unit %||% "All", "All"))
    allow_percent <- !single_bar
    session$sendCustomMessage("setPercentAllowed", allow_percent)
    if (!allow_percent && identical(input$display_as, "percent")) {
      updateRadioButtons(session, "display_as", selected = "absolute")
    }
  })

  plot_data_raw <- reactive({
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
  plot_data <- shiny::debounce(plot_data_raw, millis = 400)

  output$plot_title <- renderText({
    scope <- current_scope()
    l <- lang()
    theme_labels <- if (identical(l, "fr")) DATASET_LABELS_FR else DATASET_LABELS
    # Theme -> Series -> Breakdown -> Drill into -> Drill further, each
    # segment only present when it's actually adding information beyond the
    # one before it (a "Total" facet contributes nothing to say, and the
    # drill segments only exist once the user has actually drilled). Series/
    # facet/drill text is translated via the category_translations lookup
    # (translate_vec()) when available; the underlying English values keep
    # driving every query untouched (see current_scope()/plot_data() above).
    parts <- c(unname(theme_labels[input$theme]),
               translate_vec(con, input$series, "series", l))
    if (!identical(scope$facet, "Total")) {
      parts <- c(parts, translate_vec(con, scope$facet, "facet", l))
    }
    drill1 <- if (!is.null(input$drill_1) && !identical(input$drill_1, "none")) input$drill_1 else NULL
    drill2 <- if (!is.null(input$drill_2) && !identical(input$drill_2, "none")) input$drill_2 else NULL
    if (!is.null(drill1)) parts <- c(parts, translate_vec(con, drill1, "breakdown_2", l))
    if (!is.null(drill2)) parts <- c(parts, translate_vec(con, drill2, "breakdown_3", l))
    title <- paste(parts, collapse = " → ")
    geo_unit <- input$geo_unit %||% "All"
    if (!identical(input$geo_level, "national") && !identical(geo_unit, "All")) {
      place <- utils::tail(parse_geo_unit(geo_unit), 1)
      title <- paste0(title, " — ", place)
    }
    if (isTRUE(scope$is_stock)) {
      title <- paste(title, tr("stock_suffix", l))
    }
    title
  })

  output$source_citation <- renderUI({
    scope <- current_scope()
    ids <- series_source_table_ids(con, input$theme, input$series, scope$facet, scope$geo_level)
    theme_ids <- series_source_table_ids(con, input$theme, input$series)
    table_citation_ui(ids, theme_ids, lang())
  })

  output$plot <- renderPlotly({
    d <- plot_data()
    validate(need(nrow(d) > 0, tr("no_data", lang())))

    l <- lang()
    single_series <- nlevels(d$category) <= 1
    is_percent <- identical(input$display_as, "percent")
    number_fmt <- if (identical(l, "fr")) scales::label_number(big.mark = " ", decimal.mark = ",") else comma
    value_fmt <- if (is_percent) function(v) paste0(round(v, 1), "%") else number_fmt

    # category's own levels are the raw English breakdown/geo values that
    # already drive color assignment (scale_fill_manual, keyed by the
    # untranslated `category` factor so a language toggle never changes
    # which color a given real-world category gets) - category_display is
    # a same-length, translated-for-display twin used only for the
    # legend/tooltip text. App-invented pseudo-categories ("Other",
    # "Suppressed Residual", the "NA" bucket - see build_series_plot_data()/
    # app_utils.R) have no source-data French twin to look up, so they're
    # translated via STRINGS/tr() directly; everything else is tried
    # against category_translations under each context it could plausibly
    # have been harvested under (breakdown_1/2/3, facet - translate_vec()
    # returns its input unchanged on no match, so trying multiple contexts
    # in sequence is safe and just keeps whichever one actually matched).
    translate_category <- function(vals) {
      known <- c("Other" = tr("other_category", l), "Suppressed Residual" = tr("suppressed_residual", l),
                 "NA" = tr("na_category", l))
      out <- vals
      # NA itself (a genuinely missing category, distinct from the literal
      # string "NA" pseudo-category above) must never enter %in%/!=
      # comparisons below - it isn't an error, just untranslatable, so it's
      # excluded from the "needs lookup" set entirely and passes through
      # unchanged like any other lookup miss would.
      is_na <- is.na(vals)
      is_known <- !is_na & vals %in% names(known)
      out[is_known] <- unname(known[vals[is_known]])
      needs_lookup <- !is_na & !is_known
      if (any(needs_lookup)) {
        remaining <- vals[needs_lookup]
        for (ctx in c("breakdown_1", "breakdown_2", "breakdown_3", "facet")) {
          translated <- translate_vec(con, remaining, ctx, l)
          changed <- !is.na(translated) & translated != remaining
          remaining[changed] <- translated[changed]
        }
        out[needs_lookup] <- remaining
      }
      out
    }
    category_display <- factor(translate_category(as.character(d$category)),
                                levels = translate_category(levels(d$category)))

    # Monthly x-axis labels are too dense to all fit without overlapping -
    # thin them to every 3rd period (quarterly spacing).
    x_breaks <- if (identical(input$granularity, "Monthly")) {
      lvls <- levels(d$period_display)
      lvls[seq(1, length(lvls), by = 3)]
    } else {
      waiver()
    }

    # ggplotly() reads trace/legend names straight off the `fill` factor
    # itself - a ggplot-level scale_fill_manual(labels = ...) remap is
    # silently ignored in the conversion, so category_display (already
    # ordered to match `category`'s own level order, preserving stack
    # order) has to BE the fill aesthetic, not just a labelling layer on
    # top of it. Colors still key off the original English levels (via
    # category_colors()) so a language toggle never changes which color a
    # given real-world category gets - only the vector's *names* move to
    # the translated levels to match the new fill variable.
    p <- ggplot(d, aes(
      x = period_display, y = value, fill = category_display,
      text = paste0(period_display, "<br>", category_display, ": ", value_fmt(value))
    )) +
      geom_col(position = "stack") +
      scale_x_discrete(breaks = x_breaks) +
      scale_y_continuous(labels = if (is_percent) function(v) paste0(v, "%") else number_fmt) +
      labs(x = NULL, y = NULL, fill = NULL) +
      theme_bw() +
      theme(
        axis.text.x = element_text(angle = 45, hjust = 1),
        legend.position = if (single_series) "none" else "bottom",
        panel.grid.minor = element_blank()
      )

    if (!single_series) {
      display_colors <- category_colors(levels(d$category))
      names(display_colors) <- levels(category_display)
      p <- p + scale_fill_manual(values = display_colors)
    } else {
      p <- p + scale_fill_manual(values = "#0b4f6c")
    }

    ggplotly(p, tooltip = "text") |>
      layout(legend = list(orientation = "h", y = -0.3), margin = list(b = 100))
  })
}

shinyApp(ui, server)
