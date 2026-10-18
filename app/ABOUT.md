MigraScope visualizes Canadian immigration and refugee statistics published as open data by **Immigration, Refugees and Citizenship Canada (IRCC)** and the **Immigration and Refugee Board of Canada (IRB)**. Choose what to show in the sentence at the top of the page, adjust the options below it, and the chart updates immediately.

The app was created by Dr. Zack Taylor, Dept. of Political Science, at the University of Western Ontario out of frustration with making ad hoc plots from these Excel sheets.

#### Themes

- **Permanent Residents** — admissions of new permanent residents.
- **International Mobility Program** / **Temporary Foreign Worker Program** — the two temporary work permit programs, shown separately since they're administratively distinct.
- **Study Permit Holders** — international students holding a study permit.
- **TR → PR Transition** — temporary residents who went on to become permanent residents.
- **Asylum Claimants** — persons who made a refugee claim inside Canada.
- **Refugees** — Refugee Protection Division (RPD) decisions (accepted / rejected / other outcome), combining two source tables into one continuous 1997–2026 series.

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
- The citation under each chart names the original source table(s), when IRCC/IRB last updated them, and when you accessed them.

#### Source

The data comes from the [Government of Canada Open Data Portal](https://open.canada.ca/). It is downloaded periodically, processed, and published with this site as compact data files that your browser reads and charts itself. It is not a live query against IRCC/IRB systems; the date of the latest download is shown at the bottom of this page.

A total of {{N_TABLES}} distinct tables are included.

Where several open data tables contain equivalent information, the one with the least suppressed data is used. This is always the Excel file when both an Excel and a CSV file exist.

#### For more information

For more information, contact Zack Taylor at [zack.taylor@uwo.ca](mailto:zack.taylor@uwo.ca).
