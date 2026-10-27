MigraScope visualizes Canadian immigration and refugee statistics published as open data by **Immigration, Refugees and Citizenship Canada (IRCC)**, the **Immigration and Refugee Board of Canada (IRB)** and **Statistics Canada**. Choose what to show in the sentence at the top of the page, adjust the options below it, and the chart updates immediately.

The app was created by Dr. Zack Taylor, Dept. of Political Science, at the University of Western Ontario out of frustration with making ad hoc plots from these Excel sheets.

#### Themes

- **Permanent Residents** — admissions of new permanent residents. *All admissions* reaches back to 2000, by province/territory, immigration category, age group, gender and country of citizenship: the years before 2015 come from IRCC's [ad hoc research extracts](https://open.canada.ca/data/en/dataset/970ff3c4-50fd-4eeb-b402-f82f9ee22990), which are annual and national only (Monthly and Quarterly views start in 2015) and use the same categories. One category exists only before 2015: sponsored family members admitted on humanitarian and compassionate grounds.
- **International Mobility Program** / **Temporary Foreign Worker Program** — the two temporary work permit programs, shown separately since they're administratively distinct.
- **Study Permit Holders** — international students holding a study permit.
- **TR → PR Transition** — temporary residents who went on to become permanent residents.
- **Asylum Claimants** — persons who made a refugee claim inside Canada.
- **Refugees** — Refugee Protection Division (RPD) decisions (accepted / rejected / other outcome), combining two source tables into one continuous 1997–2026 series.
- **Non-Permanent Resident Population** — Statistics Canada's quarterly estimates of everyone living in Canada on a work or study permit, their family members, and asylum claimants, protected persons and related groups, from July 2021. Unlike the IRCC themes, which count permits and claims, this counts people, each in one type only. Each estimate is a stock, dated by Statistics Canada to the first day of a quarter; it is shown at the end of the quarter before (July 1 as June, January 1 as December of the previous year), so a year's bar is its population on December 31.

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
- The citation under each chart names the original source table(s), when IRCC/IRB last updated them, and when you accessed them.

#### Source

The IRCC and IRB data comes from the [Government of Canada Open Data Portal](https://open.canada.ca/), and the non-permanent resident estimates from [Statistics Canada table 17-10-0121-01](https://www150.statcan.gc.ca/t1/tbl1/en/tv.action?pid=1710012101). It is downloaded periodically, processed, and published with this site as compact data files that your browser reads and charts itself. It is not a live query against IRCC/IRB systems; the date of the latest download is shown at the bottom of this page.

A total of {{N_TABLES}} distinct tables are included.

Where several open data tables contain equivalent information, the one with the least suppressed data is used. This is always the Excel file when both an Excel and a CSV file exist.

#### For more information

For more information, contact Zack Taylor at [zack.taylor@uwo.ca](mailto:zack.taylor@uwo.ca).
