MigraScope visualise les statistiques canadiennes sur l'immigration et les réfugiés publiées en tant que données ouvertes par **Immigration, Réfugiés et Citoyenneté Canada (IRCC)**, la **Commission de l'immigration et du statut de réfugié du Canada (CISR)** et **Statistique Canada**. Choisissez ce qu'il faut afficher dans la phrase en haut de la page, ajustez les options en dessous, et le graphique se met à jour immédiatement.

L'application a été créée par le Dr Zack Taylor, département de science politique, à l'Université Western Ontario, par frustration face à la création de graphiques ponctuels à partir de ces feuilles Excel.

#### Thèmes

- **Résidents permanents** — admissions de nouveaux résidents permanents.
- **Programme de mobilité internationale** / **Programme des travailleurs étrangers temporaires** — les deux programmes de permis de travail temporaire, présentés séparément puisqu'ils sont administrativement distincts.
- **Titulaires d'un permis d'études** — étudiants internationaux titulaires d'un permis d'études.
- **Transition de résident temporaire à résident permanent** — résidents temporaires devenus par la suite résidents permanents.
- **Demandeurs d'asile** — personnes ayant présenté une demande d'asile au Canada.
- **Réfugiés** — décisions de la Section de la protection des réfugiés (SPR) (acceptée / rejetée / autre résultat), combinant deux tableaux sources en une seule série continue de 1997 à 2026.
- **Population de résidents non permanents** — estimations trimestrielles de Statistique Canada de toutes les personnes vivant au Canada avec un permis de travail ou d'études, des membres de leur famille, et des demandeurs d'asile, personnes protégées et groupes apparentés, depuis juillet 2021. Contrairement aux thèmes d'IRCC, qui comptent des permis et des demandes, ce thème compte des personnes, chacune dans un seul type. Chaque estimation est un stock, datée par Statistique Canada au premier jour d'un trimestre; elle est présentée à la fin du trimestre précédent (le 1er juillet comme juin, le 1er janvier comme décembre de l'année précédente), de sorte que la barre d'une année correspond à sa population au 31 décembre.

#### Choisir ce qu'il faut afficher

- **La phrase en haut** choisit le thème, la série au sein de ce thème (p. ex. toutes les admissions, ou les admissions francophones hors Québec) et la dimension qui répartit les barres (p. ex. catégorie d'immigration, groupe d'âge, pays de citoyenneté). Choisissez « Aucun » pour un total unique. Lorsqu'une répartition comporte des niveaux plus fins, un autre sélecteur apparaît pour explorer une catégorie, par exemple Économique, puis un programme précis.
- L'**agrégation géographique** présente le Canada dans son ensemble ou répartit les barres par province/territoire, région métropolitaine de recensement (RMR), division de recensement (DR) ou subdivision de recensement (SDR). Les niveaux auxquels une série n'est pas publiée sont grisés. Choisissez un lieu précis dans la phrase pour voir sa propre répartition.
- L'**agrégation temporelle** regroupe les données par mois, trimestre ou année, selon ce que la série sélectionnée permet.
- **Afficher comme** alterne entre les effectifs et le pourcentage de chaque catégorie dans le total.
- La **plage d'années** restreint la période affichée.
- Le **nombre maximal de catégories affichées** regroupe toute catégorie au-delà des N premières (selon la valeur totale) sous « Autre », afin que les répartitions comportant des centaines de valeurs (p. ex. pays, subdivisions de recensement) restent lisibles.

#### Comment lire le graphique

- Les catégories sont empilées de la plus grande (en bas) à la plus petite (en haut), et « Autre » est affiché en gris tout en bas. Les provinces et territoires sont plutôt présentés d'ouest en est.
- La bande hachurée **Résidu censuré** représente l'écart entre le total publié et la somme des catégories affichées (voir les remarques sur la qualité des données ci-dessous).
- Survolez une barre pour voir ses valeurs. Cliquez sur une entrée de la légende pour masquer ou afficher cette catégorie.
- Pour les séries de **stock** (instantanés ponctuels, p. ex. « avec un permis valide au 31 décembre »), les vues trimestrielles et annuelles affichent le dernier mois disponible de chaque entité plutôt que la somme des mois. Le titre du graphique le signale explicitement.
- La barre d'adresse contient toujours un lien vers la vue exacte affichée, dans la langue courante, que vous pouvez mettre en signet ou partager. Le bouton en haut à droite du graphique l'affiche en plein écran.

#### Remarques sur la qualité des données

- IRCC/CISR censurent (« -- ») toute valeur de cellule entre 0 et 5 pour protéger la vie privée des personnes. Les cellules censurées sont exclues des sommes, donc les totaux peuvent être légèrement sous-estimés, et probablement plus encore pour les tableaux finement répartis (p. ex. par pays) que pour les tableaux plus généraux (p. ex. par province), puisque les tableaux plus fins comptent beaucoup plus de petites cellules à censurer. Dans certains cas, la censure réduit le total global de jusqu'à 13 %.
- IRCC arrondit les valeurs publiées au multiple de 5; les nombres de décisions de la CISR ne sont pas arrondis.
- Exception : IRCC publie le tableau des adoptions (Résidents permanents › Adoptions par la résidence permanente) sans arrondi ni censure; il comprend donc des effectifs exacts de 1 à 4.
- La citation sous chaque graphique nomme le ou les tableaux sources originaux, la date de leur dernière mise à jour par IRCC/CISR et la date de votre consultation.

#### Source

Les données d'IRCC et de la CISR proviennent du [Portail du gouvernement ouvert du Canada](https://ouvert.canada.ca/), et les estimations des résidents non permanents du [tableau 17-10-0121-01 de Statistique Canada](https://www150.statcan.gc.ca/t1/tbl1/fr/tv.action?pid=1710012101). Elles sont téléchargées périodiquement, traitées, puis publiées avec ce site sous forme de fichiers de données compacts que votre navigateur lit et met en graphique lui-même. Il ne s'agit pas d'une requête en direct sur les systèmes d'IRCC/CISR; la date du dernier téléchargement figure au bas de cette page.

Un total de {{N_TABLES}} tableaux distincts sont inclus.

Lorsque plusieurs tableaux de données ouvertes contiennent une information équivalente, celui dont les données sont le moins censurées est utilisé. Il s'agit toujours du fichier Excel lorsqu'il existe à la fois un fichier Excel et un fichier CSV.

#### Pour plus d'information

Pour plus d'information, contactez Zack Taylor à [zack.taylor@uwo.ca](mailto:zack.taylor@uwo.ca).
