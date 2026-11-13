# Design tokens

pgvigil's look comes from one set of CSS custom properties at the top of `internal/web/dist/app.css`. Every colour,
size, weight, space, radius, border and shadow a rule uses is one of them; a rule holds no value of its own except a
layout measure (a column's width, a panel's max-width, a breakpoint). The light theme sets them on `:root`; the dark
theme sets the same names under `prefers-color-scheme: dark` and under `[data-theme="dark"]` (the header's Theme
button). `scripts/proof-a11y.sh` checks every page in both themes against WCAG 2.1 AA, contrast included.

## Type

| Token | Value | For |
|---|---|---|
| `--font-sans` | system-ui and its fallbacks | everything but code |
| `--font-mono` | ui-monospace and its fallbacks | statements, plans, code (`pre.sql`, `code`, `.mono`, a grid's wide cell) |
| `--fs-xs` | 11 px | the smallest words: a pill, the range panel's legends, a chart's axis values, a ring's total |
| `--fs-sm` | 12 px | the second line: meta, a chart legend, a chip, code, a tooltip, a grid's header in the quiet style (small and strong, in its own case: a unit keeps it) |
| `--fs-md` | 13 px | the body, a grid's cells, a chart's title |
| `--fs-lg` | 15 px | a section's title (h3), the brand |
| `--fs-xl` | 20 px | a page's title (h2), a tile's figure |
| `--fw-normal` / `--fw-strong` | 400 / 600 | two weights only: a title, a figure, the open tab and a picked item are strong |
| `--lh` / `--lh-tight` | 1.45 / 1.2 | body text / a title or a figure |
| `--caps-tracking` | .05em | the letter spacing of uppercase words: the range panel's legends, a pill |
| `--ul-offset` / `--ul-mix` | .2em / 40 % | a link's underline below its letters / how much of the link's colour it takes at rest |
| `--stale-gray` | .9 | how far a stale part is greyed |
| `--num` | tabular-nums | every figure that lines up with another: grids, tiles, the tooltip, the bars |

## Space, radii, borders

| Token | Value | For |
|---|---|---|
| `--sp-half`, `--sp-1` ... `--sp-5` | 2, 4, 8, 12, 16, 24 px | every padding, margin and gap |
| `--r-xs` / `--r-sm` / `--r-md` / `--r-pill` | 2 / 4 / 6 / 999 px | a swatch or a bar / a control or a tooltip / a panel, a tile, a menu / a pill |
| `--bw` | 1 px | every border and rule line |
| `--stripe` | 3 px | the left edge of a card in its state colour (a blocking chain, a tile) |
| `--focus-w` | 2 px | the open tab's bar, a focus ring, a picked step |

## Surfaces and text

| Token | Light | Dark | For |
|---|---|---|---|
| `--surface-page` | #f3f4f7 | #111317 | the page behind the panels |
| `--surface-panel` | #ffffff | #181b21 | the header, the tree, the tab row, a grid's box, a chart, a tile on the page |
| `--surface-card` | #f6f7f9 | #1f232a | a tile inside a panel, a statement's box, the time strip, an empty or loading box |
| `--surface-raised` | #ffffff | #252a32 | a menu, the range panel, the chart tooltip (with `--shadow-raised` / `--shadow-tip`) |
| `--surface-hover` | #eceef2 | #2c313a | a control, a tree row or a menu item under the pointer (dark: lighter than a menu, so it shows there) |
| `--hover-overlay` | 9 % grey | the same | laid over a grid's row under the pointer |
| `--select-fill` | the accent at 14 % | the accent at 20 % | a drag's brush across a chart |
| `--line` / `--line-strong` | #e0e3e9 / #c8cdd6 | #2a2f38 / #3a404b | a rule between rows, a toolbar control's border / a lone control's border, a tile's stripe when it has no state |
| `--text` | #1b2230 | #e3e6eb | body text, a figure |
| `--text-muted` | #545d6d | #a3abb8 | a label, a header, the second line (5.6:1 or more on every surface) |
| `--text-faint` | #606979 | #969fad | the least text (4.7:1 or more on every surface); no rule reads it yet |
| `--accent` / `--accent-soft` / `--on-accent` | #2259c8 / #e6edfb / #fff | #6fa0ff / #1d2a44 / #14171d | a link, the open tab's bar, a picked item / its fill / text on the accent |

The old names stay as aliases for the code that reads them (chart.ts, gridtools.ts, treemenu.ts, diff.ts, pi.ts,
deadlock_graph.ts, a page's inline style): `--bg` and `--card` are the panel (what a grid's cell or a chart is painted on:
a frozen column, the full-window chart), `--fg` the text, `--muted` the muted text, `--badge-fg` the text on the accent.
New code uses the names above.

## States

| Token | Light | Dark | For |
|---|---|---|---|
| `--ok` `--warn` `--crit` `--na` `--ack` | #237a35 #9a5a00 #c42626 #606979 #1b6aa3 | #57c76c #f0a33a #ff6b6b #969fad #6fb0e6 | a state as text, a dot, a stripe, a bar's fill |
| `--ok-bg` `--warn-bg` `--crit-bg` `--na-bg` `--ack-bg` | tints | tints | the tint behind the state's own text: the quiet status cells, a pill (4.6:1 or more) |
| `--st-ok` `--st-warn` `--st-crit` `--st-none` `--st-ack` `--st-head` | #006638 #e49325 #ab1f26 #e0e1e9 #1b6aa3 #004f83 | the same, N/A #2c323d | DBA Dash's solid fills on the status grids and its header (the default; 'Colours: quiet' turns them off) |
| `--st-on` / `--st-on-warn` / `--st-none-fg` | #fff / #1d1300 / #004f83 | the same / the same / #c3cad6 | the text on those fills (5.7:1 or more) |

## Charts

`--s1` ... `--s8`: one categorical order (blue, orange, aqua, yellow, magenta, green, violet, red) in both themes,
read by chart.ts in that order, assigned in order and never cycled (a ninth series folds into the neutral).
- Light: #2a6fd6 #c4511a #0d8460 #9a6a00 #c03a7a #3d7a12 #6250d6 #d23b3a - the set before task 181 darkened so every
  slot clears 3:1 on every light surface (3.9:1 or more; slots 3-5 were 2.17-2.82 on white).
- Dark: #3987e5 #d95926 #199e70 #c98500 #d55181 #008300 #9085e9 #e66767 - the set before task 181, kept: 3.2:1 or more
  on the page, the panel and a card.
- Both sets checked with the dataviz skill's validator (`validate_palette.js`, neighbouring slots): lightness band,
  chroma, colour-blind separation (worst light 8.3, dark 8.4) and normal-vision separation (worst light 15.9, dark 19.3)
  pass. Slots further apart can be close (light s4 / s6 under protanopia): a chart of more than four series is read
  with its legend, its tooltip and Pick series, never by colour alone.

## The chart kit

Every chart goes through chart.ts (`lineChart`, `donutChart`, `ringChart`, `volumeBars`), which draws with
web/src/chartkit.ts; a page never styles a chart itself.
- The chart a measure takes (`lineChart`'s `measure`, `chartKind`): a rate or a level over time is a line; a share of a
  whole over time is stacked areas (`measure: 'share'`), a share at one moment DBA Dash's pie or ring where Allen ordered
  one; a distribution over time, a count per step, is bars (`measure: 'distribution'`). One value axis: a second measure of another scale is its own chart (`y2` stays only where a
  page already uses it).
- The look (`chartLook`, `axisLook`): axis values in `--fs-xs` and `--text-muted`, grid lines in `--line`, short ticks,
  about five values up a 220 px chart and seven along a 560 px one; the series in `--s1` ... `--s8` order.
- The legend under the plot: a short line in each series' colour and its name; a click hides or shows a series, a
  double-click shows it alone; the time stays in the legend for a screen reader and shows in the readout.
- The readout under the pointer lists every series shown that has a value at that moment, in the caller's format (the
  unit is the format's or the series name's); one cursor runs across the page's charts.
- A drag across a chart sets the page's range (the address); while the page stands on a range a drag led to (a second
  drag included), every line chart's heading, an empty one too, offers 'Reset zoom' back to the range before the first
  drag (`--select-fill` is the drag's brush). Pies, rings and volume bars draw no time and offer none.
- Pies and rings (`donutChart`, `ringChart`, DBA Dash's): the slice under a mouse pops out (the class `pop`; no copied or
  exported picture carries it) and a box beside the pointer lists the slices - each one's square, name, size and share,
  15 rows at most around the hovered one - with its row marked; the legend row marks its slice the same way. The box
  follows the pointer and cannot itself be hovered, as the line charts' readout: the legend table and the picture's
  label are the complete keyboard and screen-reader path (WCAG 1.4.13). A touch shows the box on its first tap and opens
  the slice's page on a second tap of the same slice. A slice that names a thing opens it (Ctrl or the middle button: a
  new tab); 'other (n)' shows every slice for that draw. Each slice carries '<name> <size> (<share>)' where that fits
  its wedge at the drawn size, else the legend's share as a whole number (the legend's 3.5 % reads 4 %), else nothing.
  A pie with a row of its own or beside its grid (DB Space beside its grid, the PostgreSQL Storage's alone in its row)
  is 300-520 px across; a pie in a row of several 150-200 px. A label's dark halo is 0.4 of its font size (WCAG 1.4.3).
- Empty and loading (`chartState`, `chartPlaceholder`): one box in the chart's place, 'No data in this window (<the
  window>).', 'No data in this span.' on a chart of its own span, or the caller's words; loading is a status a screen
  reader announces (`chartPlaceholder` is for a page to draw while its rows load; the screen tasks adopt it).

## The shared parts

ui.ts and tiles.ts hold the parts every page builds from; a page calls them and their look follows the tokens.
- `tile(label, value, kind, { unit, sub, pill })`: a card with a left stripe (`--stripe`) in its state colour (`kind`
  'ok', 'warn', 'crit', or none), a small muted label over a large figure (`--fs-xl`, the text colour: the colour is on
  the stripe, not the figure), the unit beside it, a sub line, and on a warning or a critical tile a WARN or CRIT pill
  (the state in words; none when the label is itself a state's word, 'Critical' or 'Warnings'). `tileRow(label,
  ...tiles)` (tiles.ts): tiles side by side as one named group. Inside a panel a tile sits on `--surface-card`, its
  stripe kept.
- `badge(text, kind)` and `pill(text, kind)`: the state's word on its own tint (`--ok-bg` ... `--na-bg`, `--r-pill`);
  inside a solid status cell a badge takes the fill's text colour and no tint.
- `panel(title, note, ...content)`: a section as a card, its title with the window or the moment beside it ('last 1h',
  'latest snapshot').
- `toolbar(...groups)`: one quiet bar - each control a hairline border (`--line`) on the panel colour, the pressed one
  in the accent's tint with an accent border, groups apart by a hairline; a toggle (`.seg`) keeps its own mark and a
  link-styled button stays a link. The header's bar and every page's `.toolbar` take the same look from app.css.
- Links: a link at rest keeps a faint underline (`--ul-mix` of its colour; WCAG 1.4.1: a link in running text is told
  from its text by more than colour), the full line when pointed at - the task asked for 'underlined on hover only', and
  the faint line is the nearest that keeps 1.4.1; a link that stands alone has none (the tree, a tab's word, a tile's
  figure or label, a panel's title); the open sub-tab and the back tab keep their full underline as the mark of where the
  page is; a grid's links and the crumb keep DBA Dash's full underline.
- States, one shape: `stateNote('empty' | 'loading' | 'stale', words)` - empty and loading a soft box in the muted text
  (the page's own 'Loading...' line too; both carry `.empty`, which the proofs' settle checks wait on), stale a
  warning-tinted line 'Last collected <time>'; `markStale(box, at)` greys every child of a part whose newest read is old
  but that line, which goes under the part's heading. An empty grid stays DBA Dash's header row alone.

## The rule for a new page

1. Build it from the shared parts (ui.ts `grid`, `tile`, `badge`, `props`; chart.ts) before writing CSS; a page's own
   rule is a layout (where things sit), never a colour or a size.
2. A section is a panel: its title (h3) says what it shows and the window it covers.
3. A state is said in words and marked in colour (`--ok` ... `--crit`); colour alone never carries it (WCAG 1.4.1).
4. Figures are right-aligned with their unit; the fleet Summary's test counts stay at the left, as DBA Dash's.
5. A new colour is a new token here, with its contrast against every surface it sits on in both themes.
6. The page passes `scripts/proof-a11y.sh` in both themes before it merges.
