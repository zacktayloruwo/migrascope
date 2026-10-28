MigraScope visualizes Canadian immigration and refugee statistics published as open data by **Immigration, Refugees and Citizenship Canada (IRCC)**, the **Immigration and Refugee Board of Canada (IRB)** and **Statistics Canada**. Choose what to show in the sentence at the top of the page, adjust the options below it, and the chart updates immediately.

The app was created by Dr. Zack Taylor, Dept. of Political Science, at the University of Western Ontario out of frustration with making ad hoc plots from these Excel sheets.

#### Themes

- **Permanent Residents** — admissions of new permanent residents. *All admissions* reaches back to 2000 (see "Data before 2015" below).
- **International Mobility Program** / **Temporary Foreign Worker Program** — the two temporary work permit programs, shown separately since they're administratively distinct.
- **Study Permit Holders** — international students holding a study permit. *All permits (Year became effective)* reaches back to 2004 (see "Data before 2015" below).
- **TR → PR Transition** — temporary residents who went on to become permanent residents.
- **Asylum Claimants** — persons who made a refugee claim inside Canada.
- **Refugees** — Refugee Protection Division (RPD) decisions (accepted / rejected / other outcome), combining two source tables into one continuous 1997–2026 series.
- **Non-Permanent Resident Population** — Statistics Canada's quarterly estimates of everyone living in Canada on a work or study permit, their family members, and asylum claimants, protected persons and related groups, from July 2021. Unlike the IRCC themes, which count permits and claims, this counts people, each in one type only. Each estimate is a stock, dated by Statistics Canada to the first day of a quarter; it is shown at the end of the quarter before (July 1 as June, January 1 as December of the previous year), so a year's bar is its population on December 31.
- **Express Entry** — IRCC's system for selecting skilled workers for permanent residence (Quebec selects its own and doesn't use it). It follows candidates from invitation to admission:
  - *Invitations issued* — invitations to apply in each round, by round type: rounds open to all programs, rounds for one program (e.g. the Provincial Nominee Program), and category-based rounds (e.g. French-language proficiency, healthcare). IRCC renames rounds between versions; versions of the same category are shown as one type (e.g. "Healthcare occupations (Version 1)" and "Healthcare and social services occupations (Version 2)").
  - *CRS score of lowest-ranked candidate invited* — the Comprehensive Ranking System score of the last candidate invited, drawn as lines by round type. When a month, quarter or year has several rounds of a type, it shows the lowest score invited in that period.
  - *Candidates in the pool* — candidates in the Express Entry pool by CRS score range, from January 2022, as IRCC counted them shortly before each round (a stock: each period shows its latest count).
  - *Invited candidates who applied* — candidates who were invited and went on to apply, by year, broken down by province/territory, invitation category, CRS score, age, citizenship, education, field of study and language; separate series give occupations for each program.
  - *Admissions* — permanent residents admitted through Express Entry, by month.

#### Choosing what to show

- **The sentence at the top** picks the theme and the series within it (e.g. all admissions, or francophone admissions outside Québec), and what to break the bars down by (e.g. immigration category, age group, country of citizenship). Choose "None" for a single total. When a breakdown has finer levels, a further selector appears so you can drill into one category, for example Economic, then a specific program.
- **Geographic aggregation** shows Canada as a whole or splits the bars by Province/Territory, Census Metropolitan Area (CMA), Census Division (CD) or Census Subdivision (CSD). Levels a series isn't published at are greyed out. Pick a single place from the sentence to see its own breakdown.
- **Temporal aggregation** rolls the data up to Monthly, Quarterly or Annual, limited to what the selected series supports.
- **Display as** switches between counts and each category's percentage of the total.
- **Year range** narrows the period shown.
- **Max categories shown** folds every category past the top N (by total value) into "Other", so breakdowns with hundreds of values (e.g. countries, census subdivisions) stay readable.

#### Reading the chart

- Categories are stacked largest at the bottom to smallest at the top, with "Other" in grey at the very bottom. Provinces and territories are listed from west to east instead.
- The hatched **Suppressed Residual** band is the gap between the published total and the sum of the categories shown (see the data quality notes below).
- Hover over a bar to see its values. Click a legend entry to hide or show that category.
- For **stock** series (point-in-time snapshots, e.g. "with a valid permit on December 31"), Quarterly and Annual views show each entity's latest available month rather than a sum of months. The chart title flags these explicitly.
- The address bar always holds a link to the exact view on screen, in the current language, so you can bookmark or share it. The button at the top right of the chart shows it full screen.

#### Data quality notes

- IRCC/IRB suppress ("--") any cell value between 0 and 5 to protect individual privacy. Suppressed cells are excluded from sums, so totals may be slightly understated, likely more so for finely broken-down tables (e.g. by country) than coarser ones (e.g. by province), since finer tables have many more small cells to suppress. In some cases, suppression lowers the overall total by as much as 13%.
- IRCC rounds its published values to multiples of 5; IRB's refugee decision counts are not rounded.
- Exception: IRCC publishes the adoptions table (Permanent Residents › Adoptions via PR) without rounding or suppression, so it includes exact counts from 1 to 4.
- The citation under each chart names the original source table(s) behind the years shown, when IRCC/IRB last updated them, and when you accessed them. When the chart includes a Suppressed Residual, the table(s) holding the published total are cited too.

#### Data before 2015

IRCC's monthly open data tables start in January 2015. For two series, earlier years come from one-off extracts IRCC published on the Open Government Portal in 2016–2017 and has not updated since:

- **Permanent Residents › All admissions**, 2000–2014 — from the [Specialized Research Datasets: Permanent Residents](https://open.canada.ca/data/en/dataset/970ff3c4-50fd-4eeb-b402-f82f9ee22990): Canada by immigration category, age group, gender and country of citizenship, and the total by province/territory. The total by Census Metropolitan Area, 2006–2014, comes from [Permanent Residents – Ad Hoc](https://open.canada.ca/data/en/dataset/ad975a26-df23-456a-8ada-756191a23695).
- **Study Permit Holders › All permits (Year became effective)**, 2004–2014 — from [Study Permit Holders – Ad Hoc](https://open.canada.ca/data/en/dataset/b813dcb6-cc08-4e06-97d4-85b7e4daa822): the total and gender for Canada and each province/territory, and country of citizenship for Canada.

How the two sources are joined:

- **Each source covers its own years.** The extracts supply only the years before 2015; every year from 2015 on comes from the monthly tables. No year mixes the two.
- **The overlap is checked first.** The extracts also cover 2015, so their 2015 figures are compared with the monthly tables' before anything is joined. Each extract's total must be within 2% of the published 2015 total (3% for study permits), and every category or place with at least 5,000 admissions (2,000 students) within 10%. In the data now shown, permanent resident totals agree within 0.02% and the largest category gap is 3.4%. The study permit extract counts 2.7% fewer students in 2015 than the current tables: it was taken in March 2016, and IRCC has revised its figures since.
- **Annual figures only.** The extracts give one figure per year, so Monthly and Quarterly views start in 2015 and only the Annual view reaches further back.
- **Same categories.** Each label is matched to the one used from 2015 on, for example "Hong Kong" to "Hong Kong SAR". Where the current tables are less detailed, the older detail is added up to their level: the three kinds of protected persons in Canada become "Protected Person in Canada", and the six kinds of "All Other Immigration" are combined. One category has no current equivalent and is kept as it is: *Sponsored Family Member – H&C Consideration* (2002–2014), family members sponsored on humanitarian and compassionate grounds. It is a different group from the "Humanitarian & Compassionate" admissions within All Other Immigration.
- **Places.** Census agglomerations listed separately in the older CMA table but not in the current one (Leamington, Cold Lake, Saint-Jean-sur-Richelieu, Temiskaming Shores) are counted in "Other – <province>", as they are from 2015 on; Belleville is shown under its current name, Belleville – Quinte West. Study permits for Canada by country of citizenship add up the provinces, which can count a student who studied in two provinces twice (under 0.2% of the total).
- **Breakdowns that start in 2015.** The extracts don't split countries of citizenship by immigration category, so drilling into a country shows 2015 on only. Students whose province was not stated are in the total but not the gender breakdown, as in the current tables.
- **Captions.** Whenever a chart uses the extracts, its note says so, and the citation lists the extract tables alongside the monthly tables.

Left out on purpose:

- **Intended occupation before 2015.** The extracts' specific occupations (4-digit NOC codes) match the current tables, but the bucket for everyone without one (mainly people not intending to work: children, accompanying spouses, students, retirees) is defined differently. In 2015 it holds 76% of admissions in the extracts but 56% in the current tables, which lose another quarter to suppression. Joined, the chart would show a change at 2015 that is only a change of source, so occupation starts in 2015.
- **Immigration category by province/territory before 2015.** The only extract by province uses an older set of categories that doesn't map onto the current one (for example, family members sponsored on humanitarian and compassionate grounds are counted under "Other immigrants" rather than family), so the provincial breakdown starts in 2015.

#### Source

The IRCC and IRB data comes from the [Government of Canada Open Data Portal](https://open.canada.ca/) (including IRCC's pre-2015 extracts, above), the non-permanent resident estimates from [Statistics Canada table 17-10-0121-01](https://www150.statcan.gc.ca/t1/tbl1/en/tv.action?pid=1710012101), and the Express Entry rounds of invitations from the data file behind IRCC's [Rounds of invitations](https://www.canada.ca/en/immigration-refugees-citizenship/services/immigrate-canada/express-entry/rounds-invitations.html) page, updated after every round. It is downloaded periodically, processed, and published with this site as compact data files that your browser reads and charts itself. It is not a live query against IRCC/IRB systems; the date of the latest download is shown at the bottom of this page.

A total of {{N_TABLES}} distinct tables are included.

Where several open data tables contain equivalent information, the one with the least suppressed data is used. This is always the Excel file when both an Excel and a CSV file exist.

#### For more information

For more information, contact Zack Taylor at [zack.taylor@uwo.ca](mailto:zack.taylor@uwo.ca).
