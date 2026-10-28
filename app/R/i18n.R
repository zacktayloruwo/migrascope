# EN/FR UI-chrome strings, keyed by a stable semantic key rather than kept as
# two independently-maintained full string tables - keeping each string's
# English/French pair co-located makes a missing translation easy to spot (a
# key with only `en =` present) rather than silently drifting apart across two
# separate files. Covers only static "chrome" text (headers, button/option
# labels, templates) - data-derived text (series/facet/breakdown category
# names) is translated separately via `category_translations`
# (data-raw/09_build_translations.R), looked up at render time by
# translate_vec() in R/app_utils.R.
#' Hand-translated series/facet display names - unlike breakdown_1/2/3
#' category *values* (harvested in bulk from source-data row content via
#' data-raw/09_build_translations.R / 09_harvest_fr_translations.R),
#' series/facet names come from a table's own *title* text, which this
#' project has no automatic French-derivation step for (mirroring
#' derive_series_label()'s English title-parsing would be a much larger
#' undertaking for ~43 stable, small-vocabulary terms). Same precedent as
#' DATASET_LABELS_FR in app.R: a small, directly hand-maintained lookup
#' rather than forcing a handful of one-off terms through the auto/custom
#' pipeline built for bulk harvested data. Checked first by translate_vec()
#' (app/R/app_utils.R) for context %in% c("series", "facet"), before
#' falling back to the category_translations table.
SERIES_FACET_LABELS_FR <- c(
  # series
  "Adoptions via PR" = "Adoptions par la résidence permanente",
  "All admissions" = "Toutes les admissions",
  "All claims" = "Toutes les demandes",
  "All claims (last known address)" = "Toutes les demandes (dernière adresse connue)",
  "All permits (at December 31)" = "Tous les permis (au 31 décembre)",
  "All permits (Year became effective)" = "Tous les permis (année d'entrée en vigueur)",
  "Anglophone admissions within Québec" = "Admissions anglophones au Québec",
  "Francophone admissions outside Québec" = "Admissions francophones hors Québec",
  "Permits for humanitarian and compassionate purposes (Year became effective)" =
    "Permis pour motifs d'ordre humanitaire (année d'entrée en vigueur)",
  "Permits for work purposes only (at December 31)" = "Permis à des fins de travail seulement (au 31 décembre)",
  "Permits under post-grad employment" = "Permis dans le cadre de l'emploi postdiplôme",
  "Permits under post-grad employment (at December 31)" =
    "Permis dans le cadre de l'emploi postdiplôme (au 31 décembre)",
  "Permits under post-grad employment (Year became effective)" =
    "Permis dans le cadre de l'emploi postdiplôme (année d'entrée en vigueur)",
  "Post-Secondary (Year became effective)" = "Études postsecondaires (année d'entrée en vigueur)",
  "Prior IMP, under post-grad" = "Antérieurement PMI, emploi postdiplôme",
  "Prior IMP, work purposes only" = "Antérieurement PMI, fins de travail seulement",
  "Prior study permit" = "Antérieurement titulaire d'un permis d'études",
  "Prior TFWP" = "Antérieurement PTET",
  "Province of Claimant" = "Province du demandeur",
  "Refugee Protection Division RPD Decisions" = "Décisions de la Section de la protection des réfugiés (SPR)",
  "Top 25 ranking by citizenship (annual)" = "Classement des 25 principales nationalités (annuel)",
  "Top 25 ranking by citizenship (claim year)" = "Classement des 25 principales nationalités (année de la demande)",
  "Top 25 ranking by citizenship (monthly)" = "Classement des 25 principales nationalités (mensuel)",
  "Top 25 ranking by citizenship (most recent complete month)" =
    "Classement des 25 principales nationalités (dernier mois complet)",
  "Top 25 ranking by citizenship (most recent complete year)" =
    "Classement des 25 principales nationalités (dernière année complète)",
  # facet ("Outcome" shared between series and facet vocab - same word, kept once)
  "Age" = "Âge",
  "Age Group" = "Groupe d'âge",
  "Citizenship" = "Citoyenneté",
  "Claim Office Type" = "Type de bureau de demande",
  "Country of Citizenship" = "Pays de citoyenneté",
  "Country of Persecution" = "Pays de persécution",
  "DLI Name" = "Nom de l'ÉED",
  "Institution Type" = "Type d'établissement",
  "Institution Type and Citizenship" = "Type d'établissement et citoyenneté",
  "Immigration Category and Express Entry" = "Catégorie d'immigration et Entrée express",
  # Statistics Canada non-permanent residents (data-raw/09b_add_statcan_npr.R)
  "All non-permanent residents" = "Tous les résidents non permanents",
  "Non-Permanent Resident Type" = "Type de résident non permanent",
  # Express Entry rounds of invitations (data-raw/09d), in IRCC's own French wording.
  "Invitations issued" = "Invitations envoyées",
  "Candidates in the pool" = "Candidats dans le bassin",
  "CRS score of lowest-ranked candidate invited" = "Note obtenue dans le SCG par le candidat invité le moins bien classé",
  "Round Type" = "Type de ronde",
  # Express Entry's IRCC tables (series names set in app/data/label_overrides.xlsx).
  "Invited candidates who applied" = "Candidats invités ayant présenté une demande",
  "Invited candidates who applied (Canadian Experience Class)" =
    "Candidats invités ayant présenté une demande (Catégorie de l’expérience canadienne)",
  "Invited candidates who applied (Federal Skilled Worker Program)" =
    "Candidats invités ayant présenté une demande (Programme des travailleurs qualifiés (fédéral))",
  "Invited candidates who applied (Federal Skilled Trades Program)" =
    "Candidats invités ayant présenté une demande (Programme des travailleurs de métiers spécialisés (fédéral))",
  "Invited candidates who applied (Provincial Nominee Program)" =
    "Candidats invités ayant présenté une demande (Programme des candidats des provinces)",
  "Admissions" = "Admissions",
  "Invitation Category" = "Catégorie d'invitation",
  "Invitation Category and Age Group" = "Catégorie d'invitation et groupe d'âge",
  "Invitation Category and Country of Citizenship" = "Catégorie d'invitation et pays de citoyenneté",
  "Invitation Category and CRS Score at Invitation" = "Catégorie d'invitation et note du SCG à l'invitation",
  "Invitation Category and Field of Study" = "Catégorie d'invitation et domaine d'études",
  "Invitation Category and First Official Language Tested" = "Catégorie d'invitation et première langue officielle évaluée",
  "Invitation Category and Level of Canadian Education" = "Catégorie d'invitation et niveau d'études canadiennes",
  "Invitation Category and Level of Foreign Education" = "Catégorie d'invitation et niveau d'études étrangères",
  "Occupation" = "Profession",
  "Intended Occupation" = "Profession envisagée",
  "Country of Birth" = "Pays de naissance",
  "CRS Score Range" = "Note du SCG",
  "Public/Private" = "Public/privé",
  "Gender" = "Genre",
  "Immigration Category" = "Catégorie d'immigration",
  "Intended Occupation (4-Digit NOC 2011)" = "Profession prévue (CNP 2011 à 4 chiffres)",
  "Intended Occupation (NOC 2011)" = "Profession prévue (CNP 2011)",
  "Outcome" = "Résultat",
  "Program" = "Programme",
  "Study Level" = "Niveau d'études",
  "Top 25 Countries of Citizenship in the Most Recent Complete Year" =
    "25 principaux pays de citoyenneté de la dernière année complète",
  "Top 25 Countries of Citizenship in the Most Recent Month" = "25 principaux pays de citoyenneté du dernier mois",
  "Total" = "Total"
)

STRINGS <- list(
  # The navbar title is "MigraScope" (brand name, invariant across
  # languages) plus this descriptive suffix - kept separate from
  # nav_about/about_page_title below so the brand name can be styled
  # distinctly (Noto Serif Bold) from the rest of the title (Noto Sans
  # Light) without the language-switch textContent swap (setLang, this
  # file's own doc comment above) clobbering that markup.
  app_title_suffix   = c(en = "Canadian Immigration Statistics Visualizer",
                          fr = "Visualiseur de statistiques sur l'immigration canadienne"),
  nav_visualize      = c(en = "Visualize",              fr = "Visualiser"),
  nav_about          = c(en = "About",                  fr = "À propos"),
  about_page_title   = c(en = "About MigraScope",       fr = "À propos de MigraScope"),
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
  drill_all_choice   = c(en = "All categories",         fr = "Toutes les catégories"),
  drill_all_of       = c(en = "All %s",                 fr = "Tout : %s"),
  geo_not_available  = c(en = "Not available for this series", fr = "Non disponible pour cette série"),
  all_choice         = c(en = "All",                    fr = "Tous"),
  monthly            = c(en = "Monthly",                fr = "Mensuel"),
  quarterly          = c(en = "Quarterly",               fr = "Trimestriel"),
  annual             = c(en = "Annual",                  fr = "Annuel"),
  national           = c(en = "National",                fr = "National"),
  province_territory = c(en = "Province/Territory",     fr = "Province/Territoire"),
  cma                = c(en = "CMA",                     fr = "RMR"),
  cd                 = c(en = "CD",                      fr = "DR"),
  csd                = c(en = "CSD",                     fr = "SDR"),
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

  # Shown when a view draws on IRCC's pre-2015 ad hoc extracts (data-raw/09c).
  splice_note        = c(
    en = paste0("Years before 2015 come from IRCC's ad hoc research extracts (published 2016–2017; ",
                "annual figures only), later years from IRCC's monthly tables. The extracts' 2015 ",
                "figures were checked against the monthly tables before the two were joined; see About."),
    fr = paste0("Les années antérieures à 2015 proviennent des extractions de recherche ponctuelles ",
                "d'IRCC (publiées en 2016–2017; chiffres annuels seulement), les années suivantes des ",
                "tableaux mensuels d'IRCC. Les chiffres de 2015 des extractions ont été comparés à ceux ",
                "des tableaux mensuels avant de joindre les deux sources; voir À propos.")
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
  citation_portal_statcan = c(en = " — ",               fr = " — "),
  citation_table_page   = c(en = "table page",         fr = "page du tableau"),
  citation_web_page     = c(en = "web page",           fr = "page Web"),
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
