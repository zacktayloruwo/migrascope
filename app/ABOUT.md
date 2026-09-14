### About this app

This app visualizes Canadian immigration and refugee statistics published as open data by **Immigration, Refugees and Citizenship Canada (IRCC)** and the **Immigration and Refugee Board of Canada (IRB)**. Pick a theme and a data table in the sidebar, choose how to aggregate and break the data down, and the chart updates automatically.

The app was created by Dr. Zack Taylor, Dept. of Political Science, at the University of Western Ontario out of frustration with making ad hoc plots from these excel sheets.

#### Themes

- **Permanent Residents** — admissions of new permanent residents.
- **International Mobility Program** / **Temporary Foreign Worker Program** — the two temporary work permit programs, shown separately since they’re administratively distinct.
- **Study Permit Holders** — international students holding a valid study permit.
- **TR → PR Transition** — temporary residents who went on to become permanent residents.
- **Asylum Claimants** — persons who made a refugee claim inside Canada.
- **Refugees** — Refugee Protection Division (RPD) decisions (accepted / rejected / other outcome), combining two source tables into one continuous 1997–2026 series.

#### Reading the chart

- **Temporal aggregation** rolls the data up to Monthly, Quarterly, or Annual, limited to what the selected table actually supports.
- **Category breakdown** picks which dimension (e.g. province, gender, country of citizenship) splits the bars into a stacked chart; "Total" shows a single series.
- **Max categories shown** folds every category past the top N (by total value) into "Other" so charts with hundreds of distinct values (e.g. countries, census subdivisions) stay readable.
- Categories are stacked largest at the bottom to smallest at the top, and "Other" is always shown in grey at the very bottom.
- For **stock** tables (point-in-time snapshots, e.g. "with a valid permit on December 31st"), Quarterly/Annual views show the latest available month's value per entity rather than summing months - the chart title flags these explicitly.

#### Data quality notes

- IRCC/IRB suppress ("--") any cell value between 0 and 5 to protect individual privacy. Suppressed cells are excluded from sums, so totals may be slightly understated and likely more so for finely-broken-down tables (e.g., by country) than coarser ones (e.g., by province), since finer tables have many more small cells to suppress. In some cases data suppression decreases the overall total by as much as 13%.
- The citation under each chart names the original source table(s), when they were last updated by IRCC/IRB, and when this app last accessed them.

#### Source

Data is pulled from the [Government of Canada Open Data Portal](https://open.canada.ca/) using the API and loaded into a local database on a periodic refresh cycle. It is not a live query against IRCC/IRB systems. See the citation under each chart for the exact source table and its last-updated date.

A total of {{N_TABLES}} distinct tables are included in the database.

Note that where multiple open data tables contain equivalent information, the one with the least suppressed data was accessed. This is always the Excel file when both an Excel and CSV file exist.

#### For more information

For more information, contact Zack Taylor at [zack.taylor\@uwo.ca](mailto:zack.taylor@uwo.ca){.email}.
