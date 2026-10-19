# Data audit: 18 October 2026

A read-only audit of `app/data/immigration.duckdb` (`series_facts`, `facts`, `catalog`) after the refresh to July 2026 and the double-counting fixes in commits `8d98421` and `4b1dd3c`. **Nothing was changed.** Each finding lists a proposed fix awaiting approval.

## Checks run

| # | Check | Result |
|---|---|---|
| 1 | Duplicate keys in `series_facts` | None |
| 2 | Any breakdown larger than its series total, year by year | 1 case (finding A) |
| 3 | Province sums vs national, CD/CSD/CMA sums vs province | Only expected gaps (suppression in small places; Top-25 series, already documented) |
| 4 | Monthly sums vs annual rows, where both exist | No differences over 1% |
| 5 | Annual and monthly rows for the same cell and year | 1 series (finding E) |
| 6 | Negative, non-integer and non-multiple-of-5 values | Findings B and F |
| 7 | Category labels differing only by case or punctuation | 14 groups (finding D) |
| 8 | Categories that look like totals ("Total", "All …") | None, apart from IRCC's real "All Other Immigration" category |
| 9 | Non-place values in geography columns | Only "not stated" placeholders |
| 10 | Drill levels repeating their parent | 1 case, all zero values (harmless) |
| 11 | Year-over-year jumps over 60% | All match known events (2020 COVID drop, 2021 TR-to-PR pathway, 2022 asylum surge, 2023 permit boom) |
| 12 | Stock/flow flags vs month-to-quarter behaviour | 1 misflag (finding B) |
| 13 | Near-duplicate breakdown names | None of concern |
| 14 | Coverage: series starting later than their source tables | 1 series (finding C) |
| 15 | Source tables whose detail rows exceed their subtotals | 13 tables, 2–9% over, small cells only; consistent with IRCC's rounding to multiples of 5 |

## Findings

### A. Francophone admissions by immigration category double-counted in the current year (2026 only)
- **Symptom:** the 2026 national "Immigration Category" breakdown sums to 31,450 against a published total of 15,745.
- **Cause:** table `f72b7082` (French-speaking PRs by Immigration Category) has "Canada (excluding Quebec)" as its first level. That's a place, but it's labelled and treated as a category, so the table's rows form an extra category beside the real ones.
- **Why only 2026:** for past years the table has only annual rows, which `08` drops in favour of other tables' monthly rows. The current year has monthly rows, so they're kept.
- **Impact:** recurs every January with the new year's monthly data.
- **Proposed fix:** treat a level with a single distinct value across a whole table as filler, not a breakdown. That's the same "a split that never splits" rule `table_facet_leaf_rows()` already applies below the first level. Alternatively, a one-off override for this table.

### B. Percentage tables mixed into count series
- **Tables:** `0d2c1908` (percentage of French-speaking PRs) and `08cde424` (percentage of English-speaking PRs) feed the Francophone and Anglophone series as if their values (e.g. 0.0037, 0.0811) were counts.
- **Side effect:** the stock detector flags `0d2c1908` as a stock table, so the Francophone series appears as both stock and flow.
- **Impact:** negligible on totals, but wrong in principle.
- **Proposed fix:** exclude tables whose `facts.is_percent` is true from `series_facts`. The flag already exists and is set correctly for exactly these two tables.

### C. "Anglophone admissions within Québec" loses 2015–2025
- **Symptom:** in the app this series covers only 2026.
- **Cause:** its source table `2d5c04fe` has annual rows for 2015–2025 (e.g. 12,855 admissions to Quebec in 2024) and monthly rows only for 2026. `08` reads only monthly rows from any table that has monthly data (`period_type_filter`), so the annual history is dropped.
- **Scope:** only four tables have this shape, all official-language tables. Two are the percentage tables from finding B and one is `f72b7082` from finding A.
- **Proposed fix:** in `table_geo_subtotals()` and `table_facet_leaf_rows()`, also read annual rows for years with no monthly data.

### D. Capitalisation changes split one category into two
- **Symptom:** in multi-year charts some categories appear twice in the legend, because IRCC changed spelling between years. Examples:
  - "Study level not stated" / "Study Level not stated"
  - "Other countries" / "Other Countries"
  - "Province/territory not stated" / "Province / Territory not stated"
  - a few country names ("Samoa, Independent State Of / of")
- **Not double counting:** the variants never occur in the same place and period.
- **Not affected:** "St. Mary's / St. Marys" and "Saint-Simon / Saint-Siméon" are genuinely different municipalities.
- **Proposed fix:** normalise spelling when building `series_facts`, matching case- and punctuation-insensitively and keeping the most recent spelling.

### E. Annual and monthly rows together for December-31 study permits by country (minor)
- **Symptom:** "All permits (at December 31)", Country of Citizenship, National, has both an annual year-end row and monthly rows for 2015–2017.
- **Not affected:** the Annual view correctly takes December.
- **Affected:** the Monthly view shows the annual figure as an extra "2015" point among the months.
- **Proposed fix:** drop annual rows where a full year of monthly rows exists, for stock series.

### F. Adoptions are published unrounded and unsuppressed (documentation)
- **Finding:** IRCC publishes the adoptions table (`840a3387`) with exact small counts, including 1,402 values between 1 and 4. The data is correct as published.
- **Problem:** the About page says "Values are rounded to multiples of 5; counts of 0–5 are suppressed", which isn't true for this table.
- **Proposed fix:** add an exception to the About text, or to the theme's (i) popup once those exist.

## Resolution (applied 18 October 2026, after approval)

| Finding | Change | Result |
|---|---|---|
| A | `really_filler_levels()`: a non-geographic level with a single value across a table is filler. `f72b7082` relabelled in `label_overrides.xlsx` as its own breakdown, "Immigration Category and Express Entry" › "Express Entry". | Francophone › Immigration Category 2026: 31,450 → 15,695 (total 15,745). New breakdown covers 2015–2026. |
| B | `08` excludes tables flagged `facts.is_percent` (2 tables). | No more percentages in count series; Francophone series is no longer flagged stock. |
| C | `period_rows()`: flow tables also read annual rows for years without monthly rows. Stock tables are unchanged, because their annual figures aren't necessarily year-end snapshots. | Anglophone admissions within Québec: 2026 only → 2015–2026 (e.g. 12,855 in 2024, as published). |
| D | `08` unifies spellings that differ only in case or whitespace (most recent spelling wins). Cells that turn out to be the same are merged by the usual "larger value" rule. | 12 variant groups unified. 281 same-cell duplicates resolved; these were a small double count in "Province/Territory not stated" and one college. |
| E | `08` drops an annual row when the same cell has monthly rows through December of that year. | 566 redundant year-end rows removed (December 31 study permits by country). Years whose months stop early keep their year-end figure. |
| F | About page (EN/FR): adoptions table exception. | Done. |

**Verification:**
- The full audit was re-run. No breakdown exceeds its series total, and there are no duplicate keys.
- The remaining flags are expected: three genuine pairs of different municipalities with similar names, the adoptions table's exact counts, and about 28 small countries that have only year-end figures in the December 31 series.
- A year-by-year comparison against the pre-fix database shows changes only in the intended series.
- Parity tests: 677/677.

## Known and documented (no action)
- **Top-25 province totals:** asylum "Top 25 ranking" province totals cover only the top 25 countries (about 70–80%). This is in the README.
- **Intended occupation coverage:** permanent residents by intended occupation (NOC 2011) cover about 76% of admissions every year, because only people who state an occupation are included.
- **Refugee decisions splice:** the series joins two IRB tables at 2021/2022.

## Reproducing
The audit script ran read-only against the local database. It's kept outside the repo; it can be added as `data-raw/12_audit.R` so it runs after each refresh.
