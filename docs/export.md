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

- **The grid sheets come first**, in page order, so the file opens on the page's first grid: a sheet per grid
  on the tab, a heading's tiles (`Backups tiles`: Item | Value | Status), the fleet Summary's Needs attention lines,
  property cards (two-column label / value panels) as Item | Value | Status sheets, and each chart's series as its
  own Export Excel writes them (a time per row, a series per column, in the chart's axis unit).
- **About** is the last sheet, Item | Value: the instance (or `fleet`, or the tag), the tab, the time window (its
  label, its start and its end; and, when parts of the page read only the newest part of a long window - each part
  reads its own reach of it, 31 days and an hour unless it reads further - a 'Read' row with what they read), the
  export time, the time zone the times in the file are written in (the display time zone: the browser's unless the
  range panel names another, as `America/Los_Angeles (UTC-08:00 at export)`; each time carries its own date's
  offset, so a window across a daylight-saving change holds two), the source, and one row per grid sheet
  (`Sheet <name>`) with its row count and its note: what the list read when its part was cut to its reach ('This
  list reads the newest 31 days of this window: <from> to <to>.', also the first line of its CSV), when the page
  said it shows only the newest N of M rows (the Running queries samples) that note, a stored sample's mark (a demo
  instance's community tool), or, for a grid with no row, the page's own empty message.
- **Each sheet is named by the heading** (h2, h3 or h4) above its grid on the screen, cut to Excel's 31
  characters; the characters `\ / ? * [ ] :` become spaces and a run of spaces is one space (a rate's `/ s` reads
  `per s`). A time the heading carries and a bare count in brackets are left out (About holds the window and the
  rows); a cut that would end inside a bracket leaves that bracket out. A sheet is never numbered: two headings
  equal after the cut keep their start and the words where they part (`DatabaseBackup - USER_DAT… FULL`); a heading
  equal to a name already taken (Excel's reserved `History`, `About`, or the same heading twice) is named with the
  heading above it (`Trace flags History`). Only two headings equal in full under one heading get ` (2)` so that
  the file still opens, and the file rules (`scripts/xlsx-check.py`) fail such a file.
- **Every grid with rows is an Excel table** (Insert > Table: sortable, filterable, a name per sheet, `Table1`
  on), with no table style, so the cells keep their own colours. Its column names are the header cells: a
  heading that repeats gets ` (2)`, an empty one is `Column n` (Excel wants each column named once). A grid
  without rows (one a filter left empty, or one with no row at all) is a table too: its header row and one empty
  row (a table needs a data row), as DBA Dash exports an empty grid. A grid with no row at all leaves out a column
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
- **Numbers are numbers**, whenever the screen's text is pgvigil's rendering of the raw value. A column with a
  unit holds plain numbers in ONE unit, named in its header (`allocated (GB)`, `took (s)`), as DBA Dash writes
  one; the value stays exact and the cell shows the decimals its column shows on the page, so `1.6 GB` reads
  `1.6` in the cell and `1.6328125` in the formula bar (DBA Dash stores the value rounded instead):

  | Screen shows            | Cell value                          | Number format         |
  |-------------------------|-------------------------------------|-----------------------|
  | a size (`117.7 MB`), a size per day (`381.5 MB / day`) | the size in the column's unit, the one its largest figure uses (a rate: the unit its figures use most) | the column's decimals on the page (`0.0`) |
  | a duration (`0.3 ms`, `3.72 s`, `1.08 min`) | the duration in the unit of the column's largest figure; a column of `12.2 s` beside whole minutes and seconds (`1m 5s`): seconds | the column's decimals (`0.00`); a column of whole units only (`1m 5s`) General: the page cuts the seconds it does not show, a format would round them |
  | a count of days (`233.3 days`) | the days                    | the column's decimals |
  | a share (`12.5 %`, a growth `+3 %`, a rounded `12 %`) | the share (0.125), Excel's own percent | `0.0%`; `0.00%` where the page shows two decimals; `0%` where the column shows whole percents |
  | a count (`1,000`)       | the number                          | General (a count of 12 digits or more `0`: General would show it as `9.87654E+11`) |
  | a decimal the page rounds (`17.35`) | the number as the server sent it (17.346153) | the column's decimals (`0.00`) |
  | a time                  | an Excel date in the browser's time, whole seconds (the CSV keeps them) | `yyyy-MM-dd HH:mm` |
  | a day alone (`2026-11-11`) | an Excel date                    | `yyyy-MM-dd`          |

  A column of days or of a rate leaves a cell the page shows with no number (`never`, `-`) empty. The column's
  decimals are the most any of its figures shows on the page; a figure in a smaller unit than the column's shows
  that many decimals of the column's unit (`16.4 MB` in a GB column reads `0.0`, as DBA Dash's does).

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
font, counts General, dates `yyyy-MM-dd HH:mm` and percents `0.0%` (`0.00%` or `0%` as the page shows them), sizes
and durations in one unit named in the header, no frozen pane, and DBA Dash's column widths.
`scripts/proof-export-dbadash.py` sets the Test Summary export beside DBA Dash's own (`summary-1.xlsx`) part by part.
Kept on purpose and named there: an 'About' sheet last (what was exported, from when, in which time zone; DBA
Dash writes `Sheet1` alone), each sheet named by its grid's heading, the orange's dark text (the screen's), and a
decimal kept exact under the decimals its page shows where DBA Dash stores the rounded value (its Performance
Summary's `Avg CPU` is the one DBA Dash column that keeps more decimals than its grid draws: 17.346153 under
General for `17.3%`). Not copied: ClosedXML's artefacts (a `dataDxfId` on a table column whose cells share one style; a white
`00FFFFFF` fill on a plain date, which hides the grid lines). Where the screen leaves a cell uncoloured, the workbook
does too: a colour in the file is always one the page's own rule gave that cell, or the cell that judges it in the
same row.

## CSV

The same rows and the same columns: one grid gives one `.csv`; a tab with several grids gives a `.csv.zip` with one CSV per grid,
numbered in page order and named by the sheet names above. RFC 4180, UTF-8 with a byte-order mark (Excel reads
the encoding from it), CRLF line ends. The header row is the first line, except in the CSV of a list that read only the
newest part of a long window: there one quoted sentence comes first ('This list reads the newest 31 days of this window:
<from> to <to>.') and the header row is the second line - a reader that takes line 1 as the header skips that line
first (pandas: `skiprows=1`). Numbers are plain values (bytes, seconds for a `1h 1m` duration, milliseconds for a millisecond time, the percent
figure); times are
`yyyy-mm-dd hh:mm:ss` in the browser's time. A text cell that a spreadsheet program would run as a formula
(it starts with `=`, `+`, `-`, `@`, a tab or a carriage return: query text, an application name or any other
value read from a monitored server) is written with a leading apostrophe, the OWASP guard against CSV
injection. The workbook needs no guard: its text cells are stored as text, never as formulas.

## File names

`<instance>_<tab>_<from>_<to>.xlsx` (and `.csv` / `.csv.zip`); one grid's or one chart's workbook, and every Export file
form of one grid, `<instance>_<tab>_<sheet>_<from>_<to>.<ext>` (the sheet: the grid's heading, `Instance Summary` / `Test Summary`
from the Summary's drop-down, the chart's title); the window's start and end in the browser's
time as `yyyymmdd-hhmm`; the instance is `fleet` on the root tabs and `tag-<tag>` in a tag folder. Characters
outside `A-Z a-z 0-9 . _ -` become `-`.

## The grid menu

Every grid of both engines has DBA Dash's grid menu: a right-click on a cell, on a header cell (that column's items
and the grid's) or on the grid; from the keyboard the menu key or Shift+F10 on the grid's current cell. The same menu
is on a page's own tables (the slow statements' histograms), on a grouping's panel and on a grid with no rows (its
copies off, `No data to copy`; Export Excel writes its header). An item that cannot act says why in words in the item
(`Clear filters` with no filter: `no filter is set`). In a dialog's grid (the file viewers) the menu opens in that
dialog. In DBA Dash's order:

- **Copy** > **Grid** (the header and the rows, tab-separated), **Column** (a value a line), **Cell**, **Row** (the
  header and the row), **Selected** (the selected cells, tab-separated, with an HTML table in the colours beside them
  for a mail or a document), **As Markdown** > Standard / Prettified (every column padded to its widest), **As JSON**
  > Compact / Prettified (an array of objects keyed by the header, a repeated header numbered `name_1`).
- **Export Excel**: this grid's workbook (its own sheet, then 'About').
- **Export file** > **CSV**, **JSON**, **Markdown**, **HTML** (a page of its own: the header blue, each cell's colour
  through one class per look), **SQL (INSERT) for PostgreSQL** and **for SQL Server**: a temp table `pgvigil_grid`
  and its rows as INSERT batches of 1,000, DBA Dash's script shape for each engine. PostgreSQL's script writes every
  string as an escape string `E'...'` with each backslash doubled, so it reads the same with
  `standard_conforming_strings` on or off and in every client (pgAdmin's F5 or `psql -c` send the file as one query,
  read before any `SET` in it runs); it sets `standard_conforming_strings` on and `client_encoding` UTF8, drops and creates `pg_temp.pgvigil_grid`, and ends with its SELECT and a commented DROP;
  SQL Server's starts with a UTF-8 byte-order mark (SSMS reads the encoding from it), drops `#pgvigil_grid` if it is
  there, writes every string `N'...'` with its line breaks, except a break after a backslash (T-SQL's line
  continuation) or before a line sqlcmd or SSMS would act on (`GO`, a `:command`, `!!`, `EXIT`, `QUIT`, `RESET`,
  `ED`): that break is written as `NCHAR(13)` / `NCHAR(10)` outside the literal, the parts joined with `+`, the first
  `NVARCHAR(MAX)`; it asks in its header for `sqlcmd -x`
  (a value may hold what sqlcmd reads as a variable), and ends the same way. In both a string doubles its `'`, a column name its `"`
  or `]`; an empty header is `column_<n>`, a repeated one `_1`, `_2` (the next number no other column holds;
  on SQL Server names that differ only in case count as repeated), a name past the engine's length (SQL Server 128
  characters, PostgreSQL 63 bytes) cut with a suffix; a NUL character is dropped (neither engine stores one in text) and
  the header says how many. A column is a number type only when every non-empty cell is a number (whole numbers:
  `bigint`; else `numeric` on PostgreSQL and `DECIMAL(38,10)` on SQL Server, which rounds past 10 decimals); a time is `timestamptz` / `DATETIMEOFFSET`, written with its offset, the zone named in the header; anything
  else text. Every file is named as the grid's workbook (below) with its own extension (`.pg.sql` and `.mssql.sql` for the two
  SQL forms). JSON objects list a header that is a whole number (`2026`) first: JavaScript orders such keys so.
- **Save Table** > **From Data Table**, **From Grid**, **Script Data Table**, **Script Grid** (DBA Dash's four). Script
  Grid opens the code viewer with what Export file's SQL writes (the rows the filters leave, the shown columns); Script
  Data Table with every row the page gave the grid, whatever its filters, and every column the chooser offers, as the
  values the page read. Each is in the page's engine's dialect (a fleet page: PostgreSQL's). From Data Table and From Grid
  write a table on an instance through its actions door, an administrator's opt-in: until `doors: save_table: on` is set
  in pgvigil.yaml they are off with the words 'off: an administrator turns on doors: save_table in pgvigil.yaml; the door
  login needs CREATE in the database'.
- **Transpose** > **This row**, **Selected rows**, **Grid**: the rows as columns in a dialog, with Copy; the grid form
  shows its first 50 rows and says so, its Copy takes every row.
- **Select** > **Row**, **Column**, **All**; **Clear the selection**.
- **Columns...** (the chooser below), **Row Headers** > **Hide**, **Show**, **Show with Row Numbers** (a header before
  each row, with its number in the third; never copied or exported; a browser that kept 'Row numbers' on opens with the
  numbers), **Hide column**, **Freeze Column** (this column and every shown one before it; ticked while it is frozen, a
  click then unfreezes it and the ones after it), **Unfreeze Column**, **Group By...** (DBA Dash's dialog: the columns to
  group by; for the others Count Distinct, Min and Max, and on a number column Sum, Sum % and Avg; Include Count and
  Count % of Total - the groups above the grid, under DBA Dash's names such as `failed | Sum`, following its filters; a
  group's row filters the grid to that group, Clear filters undoes it), **Ungroup**, **Data bar** > **Behind
  value**, **Under value**, **Traffic light (higher is worse)**, **Traffic light (higher is better)**, **Options...**
  (Style; Minimum and Maximum - empty, the smaller of 0 and the column's lowest value and its highest; a traffic light's
  Warning at and Critical at, 20 and 50 % of that scale as DBA Dash sets them, or with Thresholds are values the values
  themselves), **Copy to All Numeric Columns** (the style and its thresholds on every shown number column, each on its
  own scale), **Remove**, **Remove All Data Bars**. DBA Dash's two colour pickers are not offered: the bars keep the
  theme's colours, which hold their contrast in the light and the dark theme (Section 508 / WCAG 1.4.11); a picked
  colour could fail one of them.
- **Filter by value** and **Exclude value** (the clicked value, exactly), **Filter by these values** / **Exclude these
  values** (cells selected in one column), **All filters** > Like / Not like (a text column), `=` `<>` `>` `<` `>=` `<=`
  (a prompt with the clicked value), **Edit Filter** (DBA Dash's: the filter row as one text, a line per column - its
  name in brackets, a `]` in it doubled, then its conditions exactly as its field holds them, such as `[name] like "a%"`
  or `[sessions] >5 & <>"12"`; Apply writes each line into its column's field and empties the others, the text applied
  unchanged changes nothing, and a text it cannot read is refused in words naming the line), **Clear filters**. A menu's
  filter is added to what the column's filter holds: every condition must hold. `<>` keeps an empty cell, on a number
  column too (DBA Dash keeps a NULL row).
- `Rows: n | Cols: n` and the statistics: the selection's (count, numeric count, sum, average, min, max) or the clicked
  column's over every row the filters leave; a click copies the line.

**The filter box's words.** A typed filter with no double quote means what it always meant: words the cell holds
(`R & D` is those words), `!x` words it does not hold, `<>5` a number other than 5, `>5`, `<10m`, `>500 MB` a number as shown. The menu writes
every condition quoted, joined by ` & `: `"x"` holds x, `!"x"` does not, `="x"` `<>"x"` `>"x"` ... (a number column
compares the number shown), `like "a%"` / `not like "a%"` (`%` any run, `_` one character, `\%` `\_` `\\` themselves),
`in:"a","b"` / `!in:"a","b"`; a quote inside a value is doubled. A typed filter in that form works the same. Every filter
compares the words as the screen shows them: a line break or a run of spaces is one space.

**The values each form writes.** One value per cell for the CSV, JSON and SQL forms (export.ts `rawValue`); the
workbook writes Excel's own forms; Markdown, HTML and the copies write the words on the screen:

| a cell shows | CSV | JSON, SQL | the workbook |
| --- | --- | --- | --- |
| nothing | an empty field | `null` / `NULL` | an empty cell |
| a duration (`1m 5s`) | the seconds, `65` (a millisecond column: the milliseconds) | the same | a time under `[h]:mm:ss` (a fraction of a day) |
| a percent (`12.5 %`) | `12.5` | `12.5` | `0.125` under `0.0%` |
| a size (`1.5 MB`) | the bytes | the bytes | the bytes under a size format |
| a time | `2026-11-14 17:00:00` on the display zone's clock | `2026-11-14T17:00:00-08:00` (its offset) | an Excel date on the display zone's clock |
| text with a line break or a tab | the words as shown (one space) | the value with its line breaks and tabs | the words as shown |
| yes / no | the word | the word (`"yes"`; SQL: a text column) | the word |
| a time in the hour a fall-back repeats | as shown | one of that hour's two offsets for both (the screen's clock cannot tell them apart) | as shown |

**The keyboard.** A grid is one tab stop: its current cell. The arrows, Home / End (with Ctrl: the first / last row)
and PageUp / PageDown move it (PageDown past the drawn rows reaches `Show more`); Enter or F2 reaches a cell's own link
or button and Escape comes back; on a header cell Enter sorts and F2 opens the filter row; the menu key or Shift+F10
opens the menu at the cell, Escape gives the focus back to it.

**What the tools keep, and what they are not.** Hidden columns, frozen columns, data bars with their style and options,
the row headers, and the undrawn data columns ticked in the chooser are kept in this browser per grid (localStorage: the
tab, the heading above the grid and the page's own column names), not on the server and not per user; a grouping and an
open chooser hold while the page is loaded. Data bars and traffic
lights are a screen aid in their own colours: no file carries them, and the export never reads a traffic light as a
status. A statement's masked text (the text policy) is masked when it is collected, so every copy and file carries the
masked text.

- **Columns...**: the chooser (DBA Dash's Columns dialog), with every column's tick - the page's columns, then the keys
  its rows carry that it does not draw ('not drawn by this page': ticked, one is drawn at the grid's end, in every copy
  and file; `Reset this grid` removes it) -, **All** (every column of the page), **None** (all but the grid's first: a
  grid keeps one column) and **Toggle selected** (ticks or unticks each picked name). Names are picked by a click,
  Ctrl+click and Shift+click, or from the keyboard: the list is one tab stop, the arrows move, Space picks, Shift with
  an arrow picks a range, Ctrl+A picks every name. A key starting with `_` (a page's own working value) is never
  offered, nor a key a page holds back on purpose: the Summary's Instances grid holds back its `g_` and `m_` sort values
  (the columns it hides itself). The chooser also holds the number of frozen columns, data bars per number column, a
  quick group-by (the column, its row count and the sum of every other number column) and `Reset this grid`.
- **Group By...** (the dialog above): a panel over the grid with one line per group, the largest first, each number in
  its unit (a size stays a size, a duration a duration); it follows the grid's filters, the grid itself stays as it is.
- **The Summary's toolbar Copy**: **Copy Summary** and **Copy Test Summary** copy the Instances grid and the Test
  Summary grid as their own Copy > Grid does (the words and the HTML with the fills); the Test Summary also while View
  hides it; the toolbar says what was copied.
- **Selection statistics**: Ctrl+click (Cmd on a Mac) picks cells, Shift+click a rectangle, and the chooser's
  `Sum the cells of` picks a whole column from the keyboard; the line above the grid says their count, sum, average,
  min and max. A plain click clears it.

## How it is built

`web/src/export.ts` writes the SpreadsheetML parts (the sheets, the styles, a table part per grid, the shared
strings of the tables' header cells) and the zip
container itself (deflate through the browser's `CompressionStream` when it has one, stored entries when not);
no spreadsheet library is in the bundle, so no third-party code or licence is added. The export, the Excel tables and the grid tools (`web/src/gridtools.ts`) are part
of the bundle. The grid helper in
`web/src/ui.ts` keeps each rendered grid's columns and its rows in the shown order beside the table, so the
export writes raw values, not the formatted text, and knows each column by its key (the carried colours go by
it). The grid tools read the page as the export does and change only how a grid is drawn; the grid sends the
`pgvigil:gridmenu` event on a right-click and the grid tools build its menu from it. A page adds its own lines to
the end of that menu by pushing `[label, action]` pairs into the event's `extra` from a listener on an element
around its grid (the Backup history grid's 'Verify this backup...').

## Proof

`scripts/proof-export.sh` seeds the demo, serves it, and has a headless Chromium press both buttons on the fleet
Summary, Backups, Jobs and Storage, an instance's Table Size tab (one grid sorted on screen first; once more with a
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
