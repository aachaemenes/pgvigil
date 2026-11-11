# Export to Excel and CSV

Every tab of the web UI can be saved as an Excel workbook (.xlsx) or as CSV, from the two buttons in the bar
beside Refresh: **Export .xlsx** and **Export CSV**. The export is built in the browser from the page on the
screen, so the file holds what the screen shows: the same rows in the same sort order, the same columns, the
same colours. The pgvigil server is not involved, nothing is written on any server, and nothing leaves the
browser but the file you save. The browser window opened by `pgvigil -open` and the Windows app download the
same way as any browser.

## The workbook

- **Summary** is the first sheet: the instance (or `fleet`, or the tag), the tab, the time window (its label,
  its start and its end), the export time, the time zone the times in the file are written in (the browser's, as
  `America/Los_Angeles (UTC-08:00 at export)`; each time carries its own date's offset, so a window across a
  daylight-saving change holds two), and one line per data sheet with its row count and, when the page said
  it shows only the newest N of M rows (the Running queries samples), that note.
- **One sheet per grid** on the tab, named by the heading (h2, h3 or h4) above the grid on the screen (Excel's
  31-character limit applies, a trailing space cut; a name that repeats gets ` (2)`, and so do `Summary` and
  Excel's reserved `History`; the characters `\ / ? * [ ] :` become spaces).
  Property cards (two-column label / value panels) export too, as `item` / `value` sheets.
- **The header row is frozen** and the **filter is on** over every data sheet; the column widths follow the
  content (8 to 60 characters).
- **Status colours** are the screen's solid fills (DBA Dash's colours; the orange carries dark text, white on
  it is 2.5:1) under a blue header row (`#0063A3`, white bold), whatever the theme or status style on screen:

  | Screen            | Fill      | Text      |
  |-------------------|-----------|-----------|
  | ok                | `#006638` | `#FFFFFF` |
  | warning           | `#E49325` | `#1D1300` |
  | critical          | `#AB1F26` | `#FFFFFF` |
  | no sample (muted) | `#E0E1E9` | `#004F83` |
  | acknowledged      | `#1B6AA3` | `#FFFFFF` |

  A cell is coloured when the screen colours it: a status cell (the Summary grid), or a cell that holds a
  coloured badge or dot (a severity, a check, a run status).
- **Numbers are numbers**, with formats, whenever the screen's text is pgvigil's rendering of the raw value:

  | Screen shows            | Cell value                          | Number format         |
  |-------------------------|-------------------------------------|-----------------------|
  | a size (`117.7 MB`)     | the bytes                           | `#,##0" B"`           |
  | a duration (`1h 1m`)    | the duration as an Excel time       | `[h]:mm:ss`           |
  | a millisecond time (`0.3 ms`, `2,500 ms`, `3.72 s`, `1.08 min`) | the milliseconds | `#,##0.###" ms"` |
  | a negative duration     | the seconds                         | `#,##0" s"`           |
  | a share (`12.5 %`, a growth `+3 %`, a rounded `12 %`) | the percent figure (12.5) | `#,##0.00" %"` |
  | a count (`1,000`)       | the number                          | `#,##0` / `#,##0.00`  |
  | a time                  | an Excel date in the browser's time, whole seconds | `yyyy-mm-dd hh:mm:ss` |

  The comparison is the same in every browser language (a locale that groups thousands with a space, fr-FR
  among them, gives numbers too). A cell a formatter replaced with words (`never`, `no access`, `server start`)
  keeps the words; an integer past 2^53 (Excel's exact range) stays text so no digit is lost; a value that only
  looks like a number (a role named `0042`) stays the text it is. A grid built without the raw values (the Slow
  queries tab's Per day table) is read from its text: its numeric columns still export as numbers.
- **Long text is the screen's text.** A statement or query is exported as the page shows it: cut at 400 or 600
  characters with `...` and on one line, not the whole statement (the Statements tab's own page holds that). A
  cell past Excel's 32,767-character limit is cut and says so.

## CSV

The same rows: one grid gives one `.csv`; a tab with several grids gives a `.csv.zip` with one CSV per grid,
numbered in page order and named by the sheet names above. RFC 4180, UTF-8 with a byte-order mark (Excel reads
the encoding from it), CRLF line ends. Numbers are plain values (bytes, seconds for a `1h 1m` duration, milliseconds for a millisecond time, the percent
figure); times are
`yyyy-mm-dd hh:mm:ss` in the browser's time. A text cell that a spreadsheet program would run as a formula
(it starts with `=`, `+`, `-`, `@`, a tab or a carriage return: query text, an application name or any other
value read from a monitored server) is written with a leading apostrophe, the OWASP guard against CSV
injection. The workbook needs no guard: its text cells are stored as text, never as formulas.

## File names

`<instance>_<tab>_<from>_<to>.xlsx` (and `.csv` / `.csv.zip`), the window's start and end in the browser's
time as `yyyymmdd-hhmm`; the instance is `fleet` on the root tabs and `tag-<tag>` in a tag folder. Characters
outside `A-Z a-z 0-9 . _ -` become `-`.

## How it is built

`web/src/export.ts` writes the SpreadsheetML parts and the zip container itself (deflate through the browser's
`CompressionStream` when it has one, stored entries when not); no spreadsheet library is in the bundle, so no
third-party code or licence is added for the export and the bundle grows by about 13 KB. The grid helper in
`web/src/ui.ts` keeps each rendered grid's columns and its rows in the shown order beside the table, so the
export writes raw values, not the formatted text.

## Proof

`scripts/proof-export.sh` seeds the demo, serves it, and has a headless Chromium press both buttons on the fleet
Summary, an instance's Tables tab (one grid sorted on screen first), its Roles tab, its Running queries tab over seven
days (the newest-500 note) and the fleet's Slow queries tab (the hand-built Per day table), in en-US and in fr-FR; it
reads each file back (the frozen pane and the filter in the sheet XML, the status fills in `styles.xml` against
the colours on the screen, numeric cells with their number formats, the sorted grid's order and its numbers, the
sheet names against the screen's headings, the CSV row counts against the grids') and, when LibreOffice is
installed, opens each workbook with it. Not proven here: Microsoft Excel itself (not on the proof machine) and
Firefox (the proof drives Chromium; Firefox 113+ has the one browser-specific call, `CompressionStream`, and an
older one gets stored zip entries).
