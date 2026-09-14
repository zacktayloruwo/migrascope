### À propos de cette application

Cette application visualise les statistiques canadiennes sur l'immigration et les réfugiés publiées en tant que données ouvertes par **Immigration, Réfugiés et Citoyenneté Canada (IRCC)** et la **Commission de l'immigration et du statut de réfugié du Canada (CISR)**. Choisissez un thème et un tableau de données dans le panneau latéral, choisissez comment agréger et répartir les données, et le graphique se met à jour automatiquement.

L'application a été créée par le Dr Zack Taylor, département de science politique, à l'Université Western Ontario, par frustration face à la création de graphiques ponctuels à partir de ces feuilles Excel.

#### Thèmes

- **Résidents permanents** — admissions de nouveaux résidents permanents.
- **Programme de mobilité internationale** / **Programme des travailleurs étrangers temporaires** — les deux programmes de permis de travail temporaire, présentés séparément puisqu'ils sont administrativement distincts.
- **Titulaires d'un permis d'études** — étudiants internationaux détenant un permis d'études valide.
- **Transition de résident temporaire à résident permanent** — résidents temporaires devenus par la suite résidents permanents.
- **Demandeurs d'asile** — personnes ayant présenté une demande d'asile au Canada.
- **Réfugiés** — décisions de la Section de la protection des réfugiés (SPR) (acceptée / rejetée / autre résultat), combinant deux tableaux sources en une seule série continue de 1997 à 2026.

#### Comment lire le graphique

- L'**agrégation temporelle** regroupe les données par mois, trimestre ou année, selon ce que le tableau sélectionné prend réellement en charge.
- La **répartition par catégorie** choisit quelle dimension (p. ex. province, genre, pays de citoyenneté) divise les barres en un graphique empilé; « Total » affiche une seule série.
- Le **nombre maximal de catégories affichées** regroupe toute catégorie au-delà des N premières (selon la valeur totale) sous « Autre » afin que les graphiques comportant des centaines de valeurs distinctes (p. ex. pays, subdivisions de recensement) restent lisibles.
- Les catégories sont empilées de la plus grande (en bas) à la plus petite (en haut), et « Autre » est toujours affiché en gris tout en bas.
- Pour les tableaux de **stock** (instantanés ponctuels, p. ex. « avec un permis valide au 31 décembre »), les vues trimestrielles/annuelles affichent la valeur du dernier mois disponible par entité plutôt que la somme des mois - le titre du graphique le signale explicitement.

#### Remarques sur la qualité des données

- IRCC/CISR censurent (« -- ») toute valeur de cellule entre 0 et 5 pour protéger la vie privée des personnes. Les cellules censurées sont exclues des sommes, donc les totaux peuvent être légèrement sous-estimés, et probablement plus encore pour les tableaux finement répartis (p. ex. par pays) que pour les tableaux plus généraux (p. ex. par province), puisque les tableaux plus fins comptent beaucoup plus de petites cellules à censurer. Dans certains cas, la censure des données réduit le total global de jusqu'à 13 %.
- La citation sous chaque graphique nomme le ou les tableaux sources originaux, la date de leur dernière mise à jour par IRCC/CISR, et la date du dernier accès par cette application.

#### Source

Les données proviennent du [Portail du gouvernement ouvert du Canada](https://open.canada.ca/) via son API et sont chargées dans une base de données locale selon un cycle de rafraîchissement périodique. Il ne s'agit pas d'une requête en direct sur les systèmes d'IRCC/CISR. Voir la citation sous chaque graphique pour le tableau source exact et sa date de dernière mise à jour.

Un total de {{N_TABLES}} tableaux distincts sont inclus dans la base de données.

Notez que lorsque plusieurs tableaux de données ouvertes contiennent une information équivalente, celui dont les données sont le moins censurées a été utilisé. Il s'agit toujours du fichier Excel lorsqu'il existe à la fois un fichier Excel et un fichier CSV.

#### Pour plus d'information

Pour plus d'information, contactez Zack Taylor à [zack.taylor\@uwo.ca](mailto:zack.taylor@uwo.ca){.email}.
