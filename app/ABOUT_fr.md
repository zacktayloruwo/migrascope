MigraScope visualise les statistiques canadiennes sur l'immigration et les réfugiés publiées en tant que données ouvertes par **Immigration, Réfugiés et Citoyenneté Canada (IRCC)**, la **Commission de l'immigration et du statut de réfugié du Canada (CISR)** et **Statistique Canada**. Choisissez ce qu'il faut afficher dans la phrase en haut de la page, ajustez les options en dessous, et le graphique se met à jour immédiatement.

L'application a été créée par le Dr Zack Taylor, département de science politique, à l'Université Western Ontario, par frustration face à la création de graphiques ponctuels à partir de ces feuilles Excel.

#### Thèmes

- **Résidents permanents** — admissions de nouveaux résidents permanents. *Toutes les admissions* remontent à 2000 (voir « Données antérieures à 2015 » ci-dessous).
- **Programme de mobilité internationale** / **Programme des travailleurs étrangers temporaires** — les deux programmes de permis de travail temporaire, présentés séparément puisqu'ils sont administrativement distincts.
- **Titulaires d'un permis d'études** — étudiants internationaux titulaires d'un permis d'études. *Tous les permis (année d'entrée en vigueur)* remontent à 2004 (voir « Données antérieures à 2015 » ci-dessous).
- **Transition de résident temporaire à résident permanent** — résidents temporaires devenus par la suite résidents permanents.
- **Demandeurs d'asile** — personnes ayant présenté une demande d'asile au Canada.
- **Réfugiés** — décisions de la Section de la protection des réfugiés (SPR) (acceptée / rejetée / autre résultat), combinant deux tableaux sources en une seule série continue de 1997 à 2026.
- **Population de résidents non permanents** — estimations trimestrielles de Statistique Canada de toutes les personnes vivant au Canada avec un permis de travail ou d'études, des membres de leur famille, et des demandeurs d'asile, personnes protégées et groupes apparentés, depuis juillet 2021. Contrairement aux thèmes d'IRCC, qui comptent des permis et des demandes, ce thème compte des personnes, chacune dans un seul type. Chaque estimation est un stock, datée par Statistique Canada au premier jour d'un trimestre; elle est présentée à la fin du trimestre précédent (le 1er juillet comme juin, le 1er janvier comme décembre de l'année précédente), de sorte que la barre d'une année correspond à sa population au 31 décembre.
- **Entrée express** — le système d'IRCC pour sélectionner des travailleurs qualifiés en vue de la résidence permanente (le Québec sélectionne les siens et ne l'utilise pas). Le thème suit les candidats de l'invitation à l'admission :
  - *Invitations envoyées* — les invitations à présenter une demande lors de chaque ronde, par type de ronde : rondes ouvertes à tous les programmes, rondes propres à un programme (p. ex. le Programme des candidats des provinces) et rondes fondées sur une catégorie (p. ex. compétence linguistique en français, santé). IRCC renomme les rondes d'une version à l'autre; les versions d'une même catégorie sont présentées comme un seul type (p. ex. « Professions de la santé (Version 1) » et « Professions de la santé et des services sociaux (Version 2) »).
  - *Note obtenue dans le SCG par le candidat invité le moins bien classé* — la note du Système de classement global du dernier candidat invité, tracée en lignes par type de ronde. Lorsqu'un mois, un trimestre ou une année compte plusieurs rondes d'un même type, la note la plus faible de la période est affichée.
  - *Candidats dans le bassin* — les candidats du bassin d'Entrée express par note du SCG, depuis janvier 2022, tels qu'IRCC les a comptés peu avant chaque ronde (un stock : chaque période présente son dernier décompte).
  - *Candidats invités ayant présenté une demande* — les candidats invités qui ont ensuite présenté une demande, par année, répartis par province ou territoire, catégorie d'invitation, note du SCG, âge, citoyenneté, études, domaine d'études et langue; des séries distinctes présentent les professions pour chaque programme.
  - *Admissions* — les résidents permanents admis par Entrée express, par mois.

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
- La citation sous chaque graphique nomme le ou les tableaux sources originaux des années affichées, la date de leur dernière mise à jour par IRCC/CISR et la date de votre consultation. Lorsque le graphique comprend un résidu censuré, le ou les tableaux qui contiennent le total publié sont aussi cités.

#### Données antérieures à 2015

Les tableaux mensuels de données ouvertes d'IRCC commencent en janvier 2015. Pour deux séries, les années précédentes proviennent d'extractions ponctuelles qu'IRCC a publiées sur le Portail du gouvernement ouvert en 2016–2017 et n'a pas mises à jour depuis :

- **Résidents permanents › Toutes les admissions**, 2000–2014 — tirées des [Ensemble de données de recherches spécialisées : Résidents permanents](https://ouvert.canada.ca/data/fr/dataset/970ff3c4-50fd-4eeb-b402-f82f9ee22990) : le Canada par catégorie d'immigration, groupe d'âge, genre et pays de citoyenneté, et le total par province ou territoire. Le total par région métropolitaine de recensement, 2006–2014, provient de [Résidents permanents – Ad Hoc IRCC](https://ouvert.canada.ca/data/fr/dataset/ad975a26-df23-456a-8ada-756191a23695).
- **Titulaires d'un permis d'études › Tous les permis (année d'entrée en vigueur)**, 2004–2014 — tirés de [Détenteurs de permis d'étude – Ad Hoc IRCC](https://ouvert.canada.ca/data/fr/dataset/b813dcb6-cc08-4e06-97d4-85b7e4daa822) : le total et le genre pour le Canada et chaque province ou territoire, et le pays de citoyenneté pour le Canada.

Comment les deux sources sont jointes :

- **Chaque source couvre ses propres années.** Les extractions ne fournissent que les années antérieures à 2015; toutes les années à partir de 2015 proviennent des tableaux mensuels. Aucune année ne mélange les deux.
- **Le chevauchement est d'abord vérifié.** Les extractions couvrent aussi 2015; leurs chiffres de 2015 sont donc comparés à ceux des tableaux mensuels avant toute jonction. Le total de chaque extraction doit être à moins de 2 % du total publié de 2015 (3 % pour les permis d'études), et chaque catégorie ou lieu d'au moins 5 000 admissions (2 000 étudiants) à moins de 10 %. Dans les données affichées, les totaux des résidents permanents concordent à 0,02 % près et le plus grand écart par catégorie est de 3,4 %. L'extraction des permis d'études compte 2,7 % moins d'étudiants en 2015 que les tableaux actuels : elle date de mars 2016, et IRCC a révisé ses chiffres depuis.
- **Chiffres annuels seulement.** Les extractions donnent un chiffre par année; les vues mensuelle et trimestrielle commencent donc en 2015, et seule la vue annuelle remonte plus loin.
- **Mêmes catégories.** Chaque libellé est apparié à celui utilisé à partir de 2015, par exemple pour un pays dont le nom a changé. Lorsque les tableaux actuels sont moins détaillés, le détail plus ancien est additionné à leur niveau : les trois types de personnes protégées au Canada deviennent « Personnes protégées au Canada », et les six types de « Toute autre immigration » sont regroupés. Une catégorie n'a pas d'équivalent actuel et est conservée telle quelle : *Membres de la famille parrainés - CH* (2002–2014), des membres de la famille parrainés pour des considérations d'ordre humanitaire. Il s'agit d'un groupe différent des admissions « Circonstances d'ordre humanitaire » de Toute autre immigration.
- **Lieux.** Les agglomérations de recensement présentées séparément dans l'ancien tableau des RMR, mais pas dans l'actuel (Leamington, Cold Lake, Saint-Jean-sur-Richelieu, Temiskaming Shores), sont comptées dans « Autre – <province> », comme à partir de 2015; Belleville figure sous son nom actuel, Belleville – Quinte West. Les permis d'études pour le Canada par pays de citoyenneté additionnent les provinces, ce qui peut compter deux fois un étudiant ayant étudié dans deux provinces (moins de 0,2 % du total).
- **Répartitions qui commencent en 2015.** Les extractions ne répartissent pas les pays de citoyenneté par catégorie d'immigration; explorer un pays n'affiche donc que les années à partir de 2015. Les étudiants dont la province n'est pas précisée figurent dans le total, mais pas dans la répartition par genre, comme dans les tableaux actuels.
- **Légendes.** Chaque fois qu'un graphique utilise les extractions, sa note le précise et la citation énumère les tableaux d'extraction avec les tableaux mensuels.

Exclus délibérément :

- **La profession envisagée avant 2015.** Les professions précises des extractions (codes CNP à 4 chiffres) correspondent à celles des tableaux actuels, mais la catégorie regroupant toutes les personnes sans profession précise (surtout des personnes qui n'ont pas l'intention de travailler : enfants, conjoints accompagnateurs, étudiants, retraités) est définie autrement. En 2015, elle compte 76 % des admissions dans les extractions, mais 56 % dans les tableaux actuels, qui en perdent un autre quart à la censure. Une fois jointes, le graphique montrerait en 2015 un changement qui ne serait qu'un changement de source; la profession commence donc en 2015.
- **La catégorie d'immigration par province ou territoire avant 2015.** La seule extraction par province utilise un ancien ensemble de catégories qui ne correspond pas à l'actuel (par exemple, les membres de la famille parrainés pour des considérations d'ordre humanitaire y sont comptés parmi les « autres immigrants » plutôt que dans la famille); la répartition provinciale commence donc en 2015.

#### Source

Les données d'IRCC et de la CISR proviennent du [Portail du gouvernement ouvert du Canada](https://ouvert.canada.ca/) (y compris les extractions d'IRCC antérieures à 2015, ci-dessus), les estimations des résidents non permanents du [tableau 17-10-0121-01 de Statistique Canada](https://www150.statcan.gc.ca/t1/tbl1/fr/tv.action?pid=1710012101), et les rondes d'invitations d'Entrée express du fichier de données de la page [Rondes d’invitations](https://www.canada.ca/fr/immigration-refugies-citoyennete/services/immigrer-canada/entree-express/rondes-invitations.html) d'IRCC, mise à jour après chaque ronde. Elles sont téléchargées périodiquement, traitées, puis publiées avec ce site sous forme de fichiers de données compacts que votre navigateur lit et met en graphique lui-même. Il ne s'agit pas d'une requête en direct sur les systèmes d'IRCC/CISR; la date du dernier téléchargement figure au bas de cette page.

Un total de {{N_TABLES}} tableaux distincts sont inclus.

Lorsque plusieurs tableaux de données ouvertes contiennent une information équivalente, celui dont les données sont le moins censurées est utilisé. Il s'agit toujours du fichier Excel lorsqu'il existe à la fois un fichier Excel et un fichier CSV.

#### Pour plus d'information

Pour plus d'information, contactez Zack Taylor à [zack.taylor@uwo.ca](mailto:zack.taylor@uwo.ca).
