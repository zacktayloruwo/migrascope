# EN/FR UI-chrome strings, keyed by a stable semantic key rather than kept as
# two independently-maintained full string tables - keeping each string's
# English/French pair co-located makes a missing translation easy to spot (a
# key with only `en =` present) rather than silently drifting apart across two
# separate files. Covers only static "chrome" text (headers, button/option
# labels, templates) - data-derived text (series/facet/breakdown category
# names) is translated separately via `category_translations`
# (data-raw/09_build_translations.R), looked up at render time by
# translate_vec() in R/app_utils.R.
STRINGS <- list(
  app_title          = c(en = "Canadian Immigration Statistics Visualizer",
                          fr = "Visualiseur de statistiques sur l'immigration canadienne"),
  nav_visualize      = c(en = "Visualize",              fr = "Visualiser"),
  nav_about          = c(en = "About",                  fr = "À propos"),
  lang_toggle_to_fr  = c(en = "Français",                fr = "English"),

  theme_label        = c(en = "Select Theme",           fr = "Choisir un thème"),
  series_label       = c(en = "Series",                 fr = "Série"),
  geo_unit_label     = c(en = "Geographic unit",         fr = "Unité géographique"),
  breakdown_label    = c(en = "Break down by",           fr = "Répartition par"),
  drill1_label       = c(en = "Drill into",              fr = "Explorer par"),
  drill2_label       = c(en = "Drill further",           fr = "Explorer davantage"),
  granularity_label  = c(en = "Temporal aggregation",    fr = "Agrégation temporelle"),
  geo_agg_label      = c(en = "Geographic Aggregation",  fr = "Agrégation géographique"),
  display_as_label   = c(en = "Display as",              fr = "Afficher comme"),
  year_range_label   = c(en = "Year Range",              fr = "Plage d'années"),
  top_n_label        = c(en = "Max categories shown (rest grouped as ‘Other’)",
                          fr = "Nombre maximal de catégories affichées (le reste groupé sous « Autre »)"),

  none_choice        = c(en = "None",                   fr = "Aucun"),
  all_choice         = c(en = "All",                    fr = "Tous"),
  monthly            = c(en = "Monthly",                fr = "Mensuel"),
  quarterly          = c(en = "Quarterly",               fr = "Trimestriel"),
  annual             = c(en = "Annual",                  fr = "Annuel"),
  national           = c(en = "National",                fr = "National"),
  province_territory = c(en = "Province/Territory",     fr = "Province/Territoire"),
  absolute_values    = c(en = "Absolute Values",         fr = "Valeurs absolues"),
  percentage_total   = c(en = "Percentage of Total",     fr = "Pourcentage du total"),

  suppression_note   = c(
    en = paste0("Note: IRCC/IRB suppress (“--”) any value between 0 and 5 to protect ",
                "privacy; suppressed values are excluded from sums, so totals may be ",
                "understated. The Suppressed Residual item in the plot indicates the ",
                "difference between the calculated sum of category values displayed and the ",
                "total value contained in the source data."),
    fr = paste0("Remarque : IRCC/CISR censurent (« -- ») toute valeur entre 0 et 5 pour ",
                "protéger la vie privée; les valeurs censurées sont exclues des sommes, donc les ",
                "totaux peuvent être sous-estimés. L'élément « Résidu censuré » du graphique ",
                "indique la différence entre la somme calculée des valeurs de catégorie ",
                "affichées et la valeur totale contenue dans les données source.")
  ),

  no_data            = c(en = "No data for this selection.",
                          fr = "Aucune donnée pour cette sélection."),
  stock_suffix       = c(en = "— point-in-time snapshot, not summed across months",
                          fr = "— instantané ponctuel, non additionné sur les mois"),

  citation_last_updated = c(en = ", last updated %s", fr = ", dernière mise à jour le %s"),
  citation_dataset_page = c(en = "dataset page",       fr = "page du jeu de données"),
  citation_source       = c(en = "Source: ",           fr = "Source : "),
  citation_portal       = c(en = ", Open Government Portal, Government of Canada — ",
                            fr = ", Portail du gouvernement ouvert, Gouvernement du Canada — "),
  citation_last_accessed = c(en = "Last accessed %s.", fr = "Dernier accès le %s."),

  other_category     = c(en = "Other",                 fr = "Autre"),
  suppressed_residual = c(en = "Suppressed Residual",   fr = "Résidu censuré"),
  na_category        = c(en = "NA",                    fr = "N.D.")
)

#' Look up one UI-chrome string by key and language, falling back to English
#' (or the key itself, as a last resort) if a translation is somehow missing -
#' a missing chrome string should never surface as a blank label.
tr <- function(key, lang = "en") {
  entry <- STRINGS[[key]]
  if (is.null(entry)) return(key)
  val <- entry[[lang]]
  if (is.null(val) || !nzchar(val)) val <- entry[["en"]]
  val
}
