# Plan: pre-2015 history and Express Entry themes

Status: proposal only. No data or pipeline changes have been made.
Surveyed 2026-10-27.

## 1. What the three ad hoc datasets contain

All three are on the Open Government Portal. The CKAN API (`package_show`)
returns every resource, so the portal's page-by-page listing doesn't matter.
There are 59 English files in total. Every file is a one-off extract from
2016–2017, with two exceptions (0022–0024 and the 2021–2023 tables), and none
of them is updated.

### A. Specialized Research Datasets: Permanent Residents (`970ff3c4`)

These are 12 tidy long CSVs (count, landing_year, label…). They are annual,
**national only**, cover **2000–2016**, and use random rounding to 5 with
"--" for 1–4.

| File | Dimension | Matches existing facet? | 2015 overlap check vs DB |
|---|---|---|---|
| SR_PR_0001 | Age (7 bands) | Age Group | totals within 0.1%, bands within 0.2% (median) |
| SR_PR_0002 | CMA of destination | Total @ CMA | 307 CMAs match; 18/29 names differ (2011 vs 2021 boundaries) |
| SR_PR_0003 | Country of birth | *none* | – |
| SR_PR_0004 | Country of citizenship | Country of Citizenship | India 39,525 vs 39,265; names differ ("Hong Kong" vs "Hong Kong SAR", "UK and Colonies"…) |
| SR_PR_0005 | Education level | *none* | – |
| SR_PR_0006 | Gender | Gender | within 0.02% |
| SR_PR_0007 | Immigration category, 3 levels | Immigration Category | **same hierarchy as the current data** (Economic → Worker Program → Skilled Worker …); components within 1% |
| SR_PR_0008 | Marital status | *none* | – |
| SR_PR_0009 | Intended occupation, NOC 2011 4-digit | Intended Occupation (NOC 2011) | 942 codes match; non-worker buckets differ ("Other" 206k vs "Other occupations" 152k) |
| SR_PR_0010 | Official language | *none* | – |
| SR_PR_0011 | Province/territory | Total @ PT | within 0.1% |
| SR_PR_0012 | Skill level | *none* | – |

### B. Permanent Residents – Ad Hoc (`ad975a26`)

These are XLS pivots (some also in CSV) in the older *Facts and Figures* style.

| File | Content | Years | Notes |
|---|---|---|---|
| PRadmiss_0002 | Category (Facts & Figures scheme, p.a./s.d. split) | **1980**–Q2 2016 | national; **unrounded** |
| PRadmiss_0004 | Citizenship | **1980**–Q2 2016 | national; unrounded |
| PRadmiss_0007 | PT × category (old scheme) | 2000–Mar 2016 | only PT-by-category source before 2015 |
| PRadmiss_0008 | PT × citizenship | 2000–Mar 2016 | |
| PRadmiss_0011/0012 | PT × CMA / CD | 2006–Apr 2016 | "Other CMA" buckets |
| PRadmiss_0013–0020 | CMA/CD × category (4 top groups), age, citizenship, birth | 2006–Apr 2016 | large; CD = 2011 census divisions |
| pradmiss_0023 | PT × NOC4 | **1991–2020** | extends the NOC facet to PT level |
| 0021/0022 | PGP applications received 2017–2020 | – | out of scope (post-2015, applications) |
| SUV_0001 | Start-up Visa processing 2013–2020 | – | small processing table (see §3) |
| 0024, Guardian Angel, Vancouver | one-off post-2015 extracts | – | out of scope |

The old category scheme maps onto the current top level directly:
Family class → Sponsored Family, Economic immigrants → Economic, Refugees →
Resettled Refugee & Protected Person in Canada, Other immigrants → All Other
Immigration. Components need a lookup table, and the p.a./s.d. rows have to be
summed.

### C. Study Permit Holders – Ad Hoc (`b813dcb6`)

| File | Content | Years | Use |
|---|---|---|---|
| IS_0006 | PT × citizenship, year became effective | 2004–Mar 2016 | Country of Citizenship facet (adds PT level, which the DB lacks) |
| IS_0008 | PT × CMA, year became effective | 2004–Mar 2016 | Total @ CMA |
| IS_0009 | PT × gender, year became effective | 2004–Mar 2016 | Gender and Total @ PT |
| IS_0007 | Valid on Dec 31, PT × citizenship | 2004–2015 | **redundant**: DB stocks already go back to 2000; use only as a cross-check |
| IS_0002 | Citizenship, "signed in current year" | 2006–Q3 2016 | different concept, so skip |

Overlap check: in 2015, IS_0009 gives 222,000 *unique* holders and the DB has
228,190 (−2.7%). The provincial shares are close. Splicing will leave a small
step at 2014/15 that the chart should explain in a note.

### Gaps (no pre-2015 source in these datasets)

The datasets have no pre-2015 data for asylum claimants, TFWP/IMP flows by
year effective, TR→PR transitions, or study level and institution type. The
temporary-worker and study stocks already reach back to 2000. Refugees
already reach back to 1997.

## 2. How to incorporate them

### Recommended approach

Write a dedicated script, `data-raw/09c_add_pre2015.R`, modelled on
`09b_add_statcan_npr.R`. It should not go through 01–08 for these files:

* The generic parser in 03 expects the "Monthly IRCC Updates" pivot layout.
  These files are long CSVs, or pivots with "Jan-Mar 2016"-style headers and
  p.a./s.d. rows.
* The datasets are frozen, so the script can download once (with caching) and
  carry hard-coded label maps without maintenance worry.
* It keeps the merge logic in 08 (max-merge across tables, padding collapse)
  away from data it was never tuned for.

The script would:

1. Download the needed resources by CKAN resource id into
   `data-raw/downloads/pre2015/`.
2. Parse each file into series_facts rows with `period_type = 'year'`,
   `period_month = NA` and **`period_year <= 2014` only**. The 2015–2016
   columns are used only for validation.
3. **Validate the overlap before writing.** For each mapped facet and each
   geography in 2015, compare the old file with the existing DB rows and
   stop if they diverge beyond a tolerance (for example 3% for the total and
   10% for the largest categories). This is what keeps the splice honest.
4. Harmonize labels against the current DB values. Examples: "Not stated" →
   "Age not stated" / "Gender not stated" / "Province/Territory not stated";
   country names; CMA names. Keep the maps as explicit tribbles, as 09b does.
   Unmapped labels are an error, not a silent new category.
5. Store leaves only, as in 09b, so the app's sums and the Suppressed Residual
   work unchanged.
6. Replace its own rows on re-run, keyed by a `source_table_id` prefix, so it
   is idempotent.
7. Add citation records. These are Open Canada resources, so the existing
   CKAN-hash lookup in 10 should cover them once their hashes are in
   `source_table_id`. That needs checking.

Run order: … 08 → 09 → 09b → **09c** → 10.

### What goes where (proposed scope, 2000–2014)

| Theme / series | Facet | Source | Geography |
|---|---|---|---|
| permanent_residents / All admissions | Total | SR_PR_0011 (PT), SR_PR_0002 (CMA), sum of PT (National) | National, PT, CMA |
| 〃 | Immigration Category (3 levels) | SR_PR_0007 | National |
| 〃 | Immigration Category (top level, plus mapped components) | PRadmiss_0007 | PT |
| 〃 | Age Group | SR_PR_0001 | National |
| 〃 | Gender | SR_PR_0006 | National |
| 〃 | Country of Citizenship | SR_PR_0004 (National), PRadmiss_0008 (PT) | National, PT |
| 〃 | Intended Occupation (NOC 2011) | SR_PR_0009 (National), pradmiss_0023 (PT) | National, PT |
| study_permit_holders / All permits (Year became effective) | Total, Gender | IS_0009; IS_0008 for CMA | National, PT, CMA |
| 〃 | Country of Citizenship | IS_0006 | National, PT |

Start year: 2000 for permanent residents and 2004 for study permits, since
those are where the detailed files begin.

### Items that don't map onto post-2015 categories

Checked label by label against the DB, for 2000–2014 counts.

* **PR category (SR_PR_0007).**
  * "Sponsored Family Member – H&C Consideration" (37,800) has no
    post-2015 component.
  * The components of Protected Person in Canada (Protected Person,
    Dependant, Post-determination Refugee Claimant) and of All Other
    Immigration (H&C, Public Policy, Permit Holder, DROC, DCBC, Retired)
    have no post-2015 split. Roll them up to their group.
* **PR PT × category (PRadmiss_0007, old scheme).** This needs a lookup:
  * Sons and daughters → Sponsored Children.
  * "Others" mixes Extended Family and H&C family.
  * Refugees landed in Canada + Refugee dependants → Protected Person in
    Canada.
  * Live-in caregivers / Caregivers → Caregiver.
  * Category not stated has no equivalent.
  * Fiancé(e)s appears only in the national 1980 table (0002).
  * Principal-applicant and dependant rows are summed.
* **PR NOC.** The 4-digit codes match. The catch-all "Other" (75% of counts,
  including non-workers) is not the post-2015 "Other occupations".
* **Citizenship (PR and study).** These need mapping or a decision:
  * UK and Colonies → UK and Overseas Territories
  * Hong Kong → Hong Kong SAR
  * Other Countries / Other country of citizenship, Macau, Panama Canal
    Zone, Solomons / Soloman Islands
  * Benin, Peoples Republic of; Guinea, Equatorial; Republic of Kosovo
* **CMA (PR).** "Outside of defined CMA" and "Territories, outside CA" have
  no equivalent. Belleville, Leamington, Saint-Jean-sur-Richelieu, Cold Lake
  and Temiskaming Shores are pre-2016 boundaries.
* **Study-permit CMA (IS_0008).** The post-2015 year-effective series has no
  CMA level at all (only the Dec 31 stock does), so there is nothing to
  splice onto.
* **No post-2015 facet.** PR country of birth, education, marital status,
  official language and skill level. These would be pre-2015-only facets.
* **"Not stated"** for age, gender and PT is a simple rename.

### App behaviour to check (no code yet)

* **Mixed granularity.** These series would have annual-only rows for
  2000–2014 and monthly rows from 2015. Annual should span 2000–present.
  Monthly and Quarterly should start at 2015 without treating 2000–2014 as
  "partial" years or drawing them as zero. `has_month` / `quarterly_only`
  currently apply to the whole series, so the granularity choice needs a
  per-granularity year range. The Refugees series already mixes annual and
  monthly rows, so its handling is a starting point.
* **The slider's default range.** A 2000 start would make the default view
  much wider. Consider keeping the default at 2015+ and letting users extend
  it.
* **A splice note.** Add a caption when the range crosses 2014/15, for
  example "2000–2014 from IRCC ad hoc extracts (2016); figures may differ
  slightly from current IRCC data."

## 3. Express Entry: candidate themes

| Source | What it is | Coverage | Fit |
|---|---|---|---|
| **Rounds of invitations** (canada.ca JSON `ee_rounds_123_en.json`, not on the open-data portal) | One record per draw: date, round type (22 types), ITAs issued, CRS cutoff, tie-break time, and from Jan 2022 the pool's CRS distribution (17 bands plus total, nested) | 453 draws, Jan 2015 → today | **Good.** ITA totals reproduce IRCC's annual figures (2015: 31,063) |
| **Express Entry-Invited Candidates** (`593e9165`, Monthly IRCC Updates) | Candidates who were invited *and applied*, by PT × invitation category × {ITA score band, age, citizenship, field of study, first official language, CMA, Canadian / foreign education, occupation for each program} | annual 2015 → current year to date | **Good.** Standard IRCC format. Already found by `00_discover`, not yet tracked |
| **Express Entry Permanent Residents** (`52e4b14b`, Monthly IRCC Updates) | PR admissions via EE by PT × {category, gender, citizenship, birth, occupation, age, CSD} | monthly Jan 2015 → | **Good.** Same format. Found, not tracked |
| Processing times (`data-ptime-en.json`) | Current snapshot only: durations by application type and country | no history | **Poor.** No back series, and they are durations, not counts |

### Proposed themes

1. **New theme "Express Entry Invitations"** (`ee_invitations`), built by a
   09b-style script from the rounds JSON:
   * Series "Invitations issued": a monthly flow, national. Facet
     "Round Type" with breakdown_1 as All-program / Program-specific
     (CEC, PNP, FSW, FST) / Category-based (French, healthcare, STEM, trades,
     transport, agriculture, education, …) and breakdown_2 as the specific
     round. The 22 raw names need a version-collapsing map
     ("Healthcare occupations (Version 1)" and "(Version 2)" become one
     "Healthcare" group).
   * Series "Candidates in the pool": a stock, using the last draw of each
     month, faceted by CRS band (the 13 leaf bands, checked against the
     nested subtotals). Available from Jan 2022 only.
   * The CRS cutoff is a score, not a count, so the current
     share-of-total and stacked model can't show it. It would need a new
     "level" series type, such as a line overlay. Defer it.
   * Licence: Crown copyright on canada.ca rather than the Open Government
     Licence, so the citation needs a "canada.ca" portal variant like the
     StatCan one.

2. **New theme "Express Entry Applications"** from `593e9165`: added to
   `ircc_datasets` and themed through the normal 01–08 pipeline. The data is
   annual only, so Monthly and Quarterly are greyed out (already supported).
   Facets: Invitation Category (main), ITA Score, Age, Citizenship, Field of
   Study, First Official Language, Canadian / Foreign Education, and
   Occupation (per category). Geography: PT and CMA.

3. **Express Entry admissions as a series in the existing
   permanent_residents theme** ("Express Entry admissions"), from `52e4b14b`,
   in the same way as "Francophone admissions outside Québec". It needs
   checking against the existing "Immigration Category and Express Entry"
   facet so the same counts aren't stored twice under two names.

Processing: defer. A time series would have to be built from now on by
saving the snapshot on a schedule (for example a weekly GitHub Action). It
would also need the "level" series type. The Start-up Visa processing table
(SUV_0001) is too narrow to be a theme.

## 4. Existing-data defect found during this survey (needs approval)

**The family components are dropped from the PR "Immigration Category"
facet.** In source `permanent_residents/5582034d`, Sponsored Family has a
pass-through level (Sponsored Family → Sponsored Family → Children / Extended
Family / Parent or Grandparent / Spouse or Partner). The padding collapse in
`app/R/app_utils.R` (around line 482) sees that middle level has one child
and nulls it *together with everything below it*. The four components then
share one key, and 08's cross-table max-merge keeps only the largest,
Spouse or Partner.

* National 2016: the DB has Sponsored Family = 56,790. The source total is
  78,005, and Spouse or Partner alone is 56,785.
* Result: about 21,000 family admissions a year are missing from the
  category facet (it sums to 92.7% of the total instead of about 99%). They
  show up in the app as a large Suppressed Residual, and the family
  sub-categories can't be drilled into.
* Possible fix: when a pad level has real children below it, *drop* that
  level and shift the deeper levels up instead of nulling them, or sum
  after nulling. This touches the pipeline, so it's left for your approval.
* It matters for this plan: SR_PR_0007 has the same pass-through structure.
  Pre-2015 and post-2015 family data should be stored the same way, so this
  fix should land first.
* Not yet checked whether the same pattern affects
  tr_to_pr_transition / Immigration Category (0.925–0.941 of total).

## 5. Suggested order

1. Fix the family-component defect (§4) and regenerate. *Pipeline change:
   needs approval.*
2. `09c_add_pre2015.R` for permanent residents (Total, Category, Age, Gender,
   Citizenship), plus the app change for mixed annual and monthly ranges.
3. Extend to NOC, PT-by-category (old-scheme map), CMA, and study permits.
4. Express Entry Invitations theme (rounds JSON).
5. Track `593e9165` and `52e4b14b`: the Applications theme and the PR series.
