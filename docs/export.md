# Export to Excel and CSV

Every tab of the web UI can be saved as an Excel workbook (.xlsx) or as CSV, from the two buttons in the bar
beside Refresh: **Export .xlsx** and **Export CSV**. One grid alone: **Export Excel** on the grid's own menu
(right-click, the menu key or Shift+F10), right after its copy lines, as DBA Dash's grid menu has it. On the fleet
Summary the bar also has **Export to Excel**, a drop-down with **Export Summary** (the instance grid) and **Export
Test Summary** (the grid of tests), as DBA Dash's Summary toolbar. A chart's numbers: **Export Excel** on the
chart's menu (its button in the chart's heading, or a right-click on the chart), beside Copy image and Copy data. The export is built in the browser from the page on the
screen, so the file holds what the screen shows: the same rows in the same sort order, the same columns, the
same colours. The pgvigil server is asked only for an instance's name (on an instance's tab), nothing is written on any server, and nothing leaves the
browser but the file you save. Not proven (no proof saves a file from either): that the browser window opened by `pgvigil -open` and the Windows app download the
same way as any browser.

## The workbook

- **Summary** is the first sheet: the instance (or `fleet`, or the tag), the tab, the time window (its label,
  its start and its end), the export time, the time zone the times in the file are written in (the display time zone: the browser's unless the range panel names another, as
  `America/Los_Angeles (UTC-08:00 at export)`; each time carries its own date's offset, so a window across a
  daylight-saving change holds two), and one line per data sheet with its row count and, when the page said
  it shows only the newest N of M rows (the Running queries samples), that note, or, for a grid with no row, the
  page's own empty message. Its header row and the
  heading of its list of sheets carry the same blue as every data sheet's header.
- **One sheet per grid** on the tab, named by the heading (h2, h3 or h4) above the grid on the screen (Excel's
  31-character limit applies, a trailing space cut; a name that repeats gets ` (2)`, and so do `Summary` and
  Excel's reserved `History`; the characters `\ / ? * [ ] :` become spaces, and a run of spaces is one space).
  Property cards (two-column label / value panels) export too, as `item` / `value` sheets.
- **Every grid with rows is an Excel table** (Insert > Table: sortable, filterable, a name per sheet, `Table1`
  on), with no table style, so the cells keep their own colours. Its column names are the header cells: a
  heading that repeats gets ` (2)`, an empty one is `Column n` (Excel wants each column named once). A grid
  without rows (one a filter left empty, or one with no row at all) is a plain sheet of its header row with the
  filter on; DBA Dash also exports an empty grid as its header row. A grid with no row at all leaves out a column
  the grid tools hid while it had rows, as DBA Dash writes only the visible columns (the tools' choice is read from
  this browser's storage; a choice a private window keeps only in memory is not seen there).
- **No frozen pane**, as DBA Dash's: scrolled down, Excel shows a table's column names in place of the column
  letters. **Each column is as wide as its widest cell** the way DBA Dash's writer measures it (ClosedXML's
  AdjustToContents: the text in Calibri 11, by Carlito's widths, its metric twin; a header cell bold with its
  filter button), at most 150 characters. The rule was fitted on DBA Dash's own exports: re-measured by it, each of
  DBA Dash's 111 columns comes within 5 pixels (under one character) of the width DBA Dash stored (the comparison
  fails past 6).
- **A column hidden on the screen is left out.** The grid tools (below) hide columns; the workbook and the CSV
  hold the columns the screen shows.
- **A link cell is drawn as DBA Dash's link column**: a cell the screen draws as a link (an instance name that
  opens its page) has a light fill (`#F1F1F6`) and the link blue as its text colour (`#004F83`). No other cell
  is filled: a cell has the colour the screen gives it, and the rows are not banded.
- **Status colours** are the screen's solid fills (DBA Dash's colours; the orange carries the screen's dark text,
  where DBA Dash writes white at 2.5:1), in a plain font as DBA Dash writes them (not bold), under a blue header
  row (`#0063A3`, white bold), whatever the theme or status style on screen:

  | Screen            | Fill      | Text      |
  |-------------------|-----------|-----------|
  | ok                | `#006638` | `#FFFFFF` |
  | warning           | `#E49325` | `#1D1300` |
  | critical          | `#AB1F26` | `#FFFFFF` |
  | no sample (muted) | `#E0E1E9` | `#004F83` |
  | acknowledged      | `#1B6AA3` | `#FFFFFF` |

  A cell is coloured when the screen colours it, by the screen's own rule: a status cell (the Summary grid), a
  cell that holds a coloured badge or dot (a severity, a check, a run status, a free share under 10 %, a test's
  worst state), a data bar's fill (Performance summary's CPU), a word the page marks warning or critical, a value
  whose text the page paints in the status colour (a failed count), or a cell the page's own rule marked (a late
  backup, a suspended replica, a ratio over its threshold); with several marks in one cell, the worst. A picture in a
  cell (the CPU histogram's bars) colours none.

  **A value takes the colour of the cell that judges it.** The screen puts the colour on the word (`failing`,
  `late`, `failed`, `4 %`); DBA Dash's own export colours the value beside it too (the date of the late backup,
  the time of the failed run), and so does this one, in the same row:

  | Grid                               | The cell that judges     | The value that takes its colour      |
  |------------------------------------|--------------------------|--------------------------------------|
  | Backups (fleet)                    | archiver                 | last archived                        |
  | Backups (SQL Server)               | full, differential, log  | last full and full age, last differential, last log and log age |
  | Jobs (an instance's jobs, steps)   | outcome, last outcome    | last run                             |
  | Jobs (fleet), Job report           | last run                 | last start                           |
  | Storage, Disk report, drives       | free                     | free size                            |
  | Findings and checks                | severity, check          | value                                |

  A cell with a colour of its own keeps it; an empty cell takes none; an acknowledged cell stays blue.
- **Numbers are numbers**, in DBA Dash's formats where it has one (a count or a decimal General, a share `0.0%`, a
  time `yyyy-MM-dd HH:mm`) and pgvigil's unit formats where the screen shows a unit, whenever the screen's text is
  pgvigil's rendering of the raw value:

  | Screen shows            | Cell value                          | Number format         |
  |-------------------------|-------------------------------------|-----------------------|
  | a size (`117.7 MB`)     | the bytes                           | `#,##0" B"`           |
  | a duration (`1h 1m`)    | the duration as an Excel time       | `[h]:mm:ss`           |
  | a millisecond time (`0.3 ms`, `2,500 ms`, `3.72 s`, `1.08 min`) | the milliseconds | `#,##0.###" ms"` |
  | a negative duration     | the seconds                         | `#,##0" s"`           |
  | a share (`12.5 %`, a growth `+3 %`, a rounded `12 %`) | the share (0.125), Excel's own percent | `0.0%` |
  | a count (`1,000`), a decimal | the number                     | General (a count of 12 digits or more `0`: General would show it as `9.87654E+11`) |
  | a time                  | an Excel date in the browser's time, whole seconds (the CSV keeps them) | `yyyy-MM-dd HH:mm` |

  The comparison is the same in every browser language (a locale that groups thousands with a space, fr-FR
  among them, gives numbers too). A cell a formatter replaced with words (`never`, `no access`, `server start`)
  keeps the words; an integer past 2^53 (Excel's exact range) stays text so no digit is lost; a value that only
  looks like a number (a role named `0042`) stays the text it is. A grid built without the raw values (the Slow
  queries tab's Per day table) is read from its text: its numeric columns still export as numbers.
- **Long text.** A statement the page cuts is exported as the page shows it: cut at 400 or 600
  characters with `...` and on one line; a statement cell that opens the whole statement on a click exports the whole statement (`web/src/sqlview.ts`). Not proven: no proof part grades a long statement. A
  cell past Excel's 32,767-character limit is cut and says so.

## Beside DBA Dash's own export

The workbook writes one sheet per grid as an Excel table without a style (DBA Dash's style info: row stripes on, no
style named, so none drawn), a blue header row in white bold, every cell in the colour its grid gives it in a plain
font, counts General, dates `yyyy-MM-dd HH:mm` and percents `0.0%`, no frozen pane, and DBA Dash's column widths.
`scripts/proof-export-dbadash.py` sets the Test Summary export beside DBA Dash's own (`summary-1.xlsx`) part by part.
Kept on purpose and named there: the Summary sheet first (what was exported, from when, in which time zone; DBA
Dash writes `Sheet1` alone), each sheet named by its grid's heading, the orange's dark text (the screen's), the unit
formats of a size or a duration (DBA Dash has no such cell), and a value cell carried in the colour of the cell that
judges it. Not copied: ClosedXML's artefacts (a `dataDxfId` on a table column whose cells share one style; a white
`00FFFFFF` fill on a plain date, which hides the grid lines). Where the screen leaves a cell uncoloured, the workbook
does too: a colour in the file is always one the page's own rule gave that cell, or the cell that judges it in the
same row.

## CSV

The same rows and the same columns: one grid gives one `.csv`; a tab with several grids gives a `.csv.zip` with one CSV per grid,
numbered in page order and named by the sheet names above. RFC 4180, UTF-8 with a byte-order mark (Excel reads
the encoding from it), CRLF line ends. Numbers are plain values (bytes, seconds for a `1h 1m` duration, milliseconds for a millisecond time, the percent
figure); times are
`yyyy-mm-dd hh:mm:ss` in the browser's time. A text cell that a spreadsheet program would run as a formula
(it starts with `=`, `+`, `-`, `@`, a tab or a carriage return: query text, an application name or any other
value read from a monitored server) is written with a leading apostrophe, the OWASP guard against CSV
injection. The workbook needs no guard: its text cells are stored as text, never as formulas.

## File names

`<instance>_<tab>_<from>_<to>.xlsx` (and `.csv` / `.csv.zip`); one grid's or one chart's workbook
`<instance>_<tab>_<sheet>_<from>_<to>.xlsx` (the sheet: the grid's heading, `Instance Summary` / `Test Summary`
from the Summary's drop-down, the chart's title); the window's start and end in the browser's
time as `yyyymmdd-hhmm`; the instance is `fleet` on the root tabs and `tag-<tag>` in a tag folder. Characters
outside `A-Z a-z 0-9 . _ -` become `-`.

## The grid tools

Every grid's menu (right-click, the menu key or Shift+F10) carries **Export Excel** after the copy lines (that grid's
workbook: the Summary sheet and its own; the grid's line says the file's name), and, under them:

- **Copy the rows as Markdown** and **as HTML with the colours**: the rows the filter leaves and the columns
  shown, as a pipe table, or as an HTML table whose cells carry the workbook's colours in their own style (the
  header blue, each status fill and its text colour, a link cell's fill and blue), so a mail, a document or
  a spreadsheet it is pasted into shows them; the tab-separated words ride beside the HTML for a plain paste.
  With cells selected, both copy the selection.
- **Hide column**, **Freeze the columns up to** this one (they stay while the rest scrolls sideways) and
  **Columns...**: the chooser, with every column's tick, the number of frozen columns, data bars per number
  column, the group-by and `Reset this grid`. What is hidden, frozen and barred is kept in this browser
  (localStorage, one entry per grid: the tab, the heading above the grid and its column names), not on the
  server and not per user.
- **Group by** a column: a panel above the grid with one line per value, its row count and one aggregate of
  every number column (sum, average, min or max; a size stays a size, a duration a duration), the largest
  group first. It follows the grid's filters; the grid itself stays as it is.
- **Data bars** on a number column: a bar behind each number above zero, its length the value's share of the
  largest one drawn; a cell the page colours keeps its colour and gets no bar. A screen aid: the export writes
  the number.
- **Selection statistics**: Ctrl+click (Cmd on a Mac) picks cells, Shift+click a rectangle, and the chooser's
  `Sum the cells of` picks a whole column from the keyboard; the line above the grid says their count, sum,
  average, min and max. A plain click clears it.

A grouping and an open chooser hold while the page is loaded, also over a live tab's 30-second refresh; a
selection does not (the cells are drawn again).

## How it is built

`web/src/export.ts` writes the SpreadsheetML parts (the sheets, the styles, a table part per grid, the shared
strings of the tables' header cells) and the zip
container itself (deflate through the browser's `CompressionStream` when it has one, stored entries when not);
no spreadsheet library is in the bundle, so no third-party code or licence is added. The export, the Excel tables and the grid tools (`web/src/gridtools.ts`) are part
of the bundle. The grid helper in
`web/src/ui.ts` keeps each rendered grid's columns and its rows in the shown order beside the table, so the
export writes raw values, not the formatted text, and knows each column by its key (the carried colours go by
it). The grid tools read the page as the export does and change only how a grid is drawn; their lines come
into the grid's menu on the `pgvigil:gridmenu` event the grid sends before it shows the menu.

## Proof

`scripts/proof-export.sh` seeds the demo, serves it, and has a headless Chromium press both buttons on the fleet
Summary, Backups, Jobs and Storage, an instance's Tables tab (one grid sorted on screen first; once more with a
grid filtered to nothing), its Roles tab, its Running queries tab over seven days (the newest-500 note), the
fleet's Slow queries tab (the hand-built Per day table) and a database's page, in en-US and in fr-FR. It reads
each file back and grades it against the page it came from:

- every cell of every row the page draws (a long grid draws its first 200) against the screen: the status fill
  and text colour of a cell the screen colours, a carried colour only in a value column of the table above and
  only where the judging cell of its row shows it, a link cell's fill and blue, no fill on any other cell;
- every grid with rows as an Excel table: the table part named by the sheet, its range the sheet's, its
  column names unique and equal to the header cells (shared strings, as Excel itself stores a table's
  header); a grid without rows as a plain filtered sheet;
- no frozen pane, every column's width by the rule above within a pixel, the status cells not bold, the numeric
  cells with their number formats (a percent as a share under `0.0%`, the CSV with the percent figure; a time
  `yyyy-MM-dd HH:mm`; a count General), the sorted grid's order and its numbers, the sheet names against the
  screen's headings, the CSV row counts against the grids';
- each new menu item clicked and its download read (P03): a grid's Export Excel (placed right after the copies),
  the Summary's Export to Excel > Export Summary and > Export Test Summary (the Test Summary by DBA Dash's rule: a
  count 0 green, above 0 its column's status, a test's name its row's worst), a line chart's and a ring's Export
  Excel (a time as a time, a share as `0.0%`), and an empty grid's sheet without the column the grid tools hid;
- with `PGVIGIL_EXPORT_OUT` set, the downloads kept; `scripts/proof-export-dbadash.py <Test Summary .xlsx>
  <DBA Dash's summary-1.xlsx>` then compares the header, each status's fill, text colour, weight and format, the
  rule, the table part, the pane and the widths, and names each difference kept on purpose;
- each workbook opened with a spreadsheet library (python's openpyxl) when the machine has it, and with
  LibreOffice when that is installed;
- the grid tools through the grid's own menu: the HTML copy's colours cell by cell, the Markdown copy, the
  selection's sum, the groups, the data bars, the frozen and the hidden column (kept over a reload, left out
  of the workbook exported then) and the chooser's reset. The proof fails when the menu does not carry the
  tools (`PGVIGIL_EXPORT_NEED` names what must be graded; `tools` is its default).

Not proven here: Microsoft Excel itself (not on the proof machine; the table parts follow the rules Excel
repairs a file for: one name per column, the header cells equal to the names, no sheet filter beside a table)
and Firefox (the proof drives Chromium; Firefox 113+ has the one browser-specific call, `CompressionStream`,
and an older one gets stored zip entries).
