# Reports by e-mail

Any page of the web UI can be mailed: now, from the page itself, or on a schedule. The mail is the page: its
grids as HTML in the colours, numbers and dates the screen shows, under the same header lines as the Excel export
(the instance, the page, the window, the time zone), with the page's own workbook (.xlsx) attached. The mail goes
out through an smtp channel of the `alerts:` block, so it needs no mail setting of its own.

## Send now

Every page's bar has **Mail...** beside **Export .xlsx**. It asks for one or more addresses, the smtp channel and
a subject (the page, the instance and the window by default), and whether to attach the workbook. **Send now**
builds the mail in the browser from the grids on the screen and queues it; the dialog then shows the answer
(`sent` with the rows and the size, or `failed` with the relay's error) as soon as the sender has mailed it,
within a minute while `pgvigil run` is up.

**Schedule this page...** in the same dialog opens the schedule form with the page's address filled in, and keeps
the page's grid choices of this browser with the schedule (the grid tools' hidden, frozen and barred columns), so
the scheduled mail leaves out what your window leaves out. A schedule made with **New schedule...** on the Report
mail page has none: its mail shows every column.

## Schedules

The root page **Report mail** (the tree's Reports folder) lists the schedules with each one's next send and last
send, the mails of the window (who asked, when, to whom, the rows, the size, the answer, the error) and every
attempt to change a schedule. A schedule names:

- **the page**: its address in the UI, as the bar's Mail... takes it (`#/backups?w=24h`, `#/jobs?i=3&w=7d`). A
  preset window (`w=24h`, `w=today`, `w=wtd` ...) follows each send: a daily mail of `w=24h` is always the last
  24 hours. A fixed window (`from` / `to`) mails the same hours every time; the form says so.
- **the addresses** (1 to 50) and **the smtp channel** (a channel of the `alerts:` block of kind smtp).
- **the cadence**: daily at a time, weekly on some days at a time, or a cron line (five fields, pg_cron's
  grammar: `0 7 * * 1-5`; the `@daily` names are taken), in **a time zone** (an IANA name such as
  `America/Los_Angeles`, or `UTC`). A schedule sends at most every 15 minutes: a line that fires more often is
  refused.
- whether the workbook is attached, and whether the schedule is on.

**Send test** on a schedule's row draws its page now, as you, and mails it to its addresses with `[test]` before
the subject: one test of yours at a time, on a browser of its own (a test never holds up a schedule's turn). **Turn off** holds the schedule; **End** ends it for good (its mails stay in the log).

The subject of a scheduled mail is the schedule's name and the page's window, as `Daily backups - last 24h
(2026-11-11 07:00:00 to 2026-11-12 07:00:00, America/Los_Angeles)`.

## How the mail equals the window

There is one renderer. The browser that shows a page is also what builds its mail:

- the HTML is the grid tools' **Copy the rows as HTML with the colours** (each colour in the cell's own style:
  the export's header blue, each status fill with its text colour, a link cell's light fill), one table per grid
  under the heading the screen shows above it; the cells are the export's (`docs/export.md`): the same rows in the
  same sort order, a column hidden with the grid tools left out, a value cell in the colour of the cell that
  judges it;
- the attachment is the workbook **Export .xlsx** saves from the same page.

A scheduled page has no browser of its own, so the server opens one: at each turn the serve process starts a
headless Chromium-family browser (`chromium`, Chrome or Edge, found on the PATH or at the usual install places;
`PGVIGIL_BROWSER` names one) in a profile folder of its own (readable by the server's account only), signs it in
**as the schedule's owner** with a session made for that render alone (revoked when the render ends), loads the
schedule's grid choices, and opens the page on a listener of its own on `127.0.0.1` that lives for the render, in
the schedule's time zone and in English. The render's key is handed to the browser through a file in its profile
folder, never on its command line (where another account of the host could read it), and it opens once only.
The browser and every process it starts are killed when the page has answered or after 90 seconds. The page draws itself as it does for a person, builds the same mail with the
same code and hands it back. The workbook of a scheduled mail is therefore rendered headless too (the reader's
choice of the two ways the task allowed: the same code as the window, no second writer of the workbook on the
server). A server without such a browser cannot render a schedule: the page says so, each turn is a failed mail
(alerted, below), and Send now works from any browser.

An owner who can no longer sign in (disabled, removed) renders nothing: the turn fails with that reason. A mail
sees what its owner's session sees: no more.

## What a mail carries

- a `multipart/alternative` of a short plain-text part and the HTML part (base64), and the workbook as an
  attachment (`multipart/mixed`) when it is asked for;
- tables and inline styles only. The body is checked against what the page builder writes - an allowlist, not a
  blocklist: the tags `html head meta title body h2 h3 p table thead tbody tr th td`, the attributes `style`,
  `data-status`, `lang`, `charset`, `name`, `content` and `role`, no URL, no entity inside a tag, no `url()` or
  `expression()` in a style. Anything else is refused, by the server before it queues the mail and again by the
  sender before it mails it;
- at most 4 MB of HTML and 8 MB of workbook (a page past that is refused with its size: narrow the window or
  filter the grid);
- the headers `X-Pgvigil-Report: <mail id>` and `Auto-Submitted: auto-generated`.

## Who sends, and failures

The serve process never holds a channel's secret. A mail asked from the UI, and a schedule's turn the server drew,
wait in the repository (`pgvigil.report_mail_sends`) until **the alert sender** (`pgvigil run`, or one pass of
`pgvigil alerts`) mails them through the channel each names: the channel's relay, TLS, login and from address.
The sender takes each mail before it sends it (a mail taken is never sent again, even when its answer cannot be
written), reads one mail's body at a time, records the answer (sent or failed with the relay's error, the size of
the message) and clears the body from the repository; the log line stays: who, when, to whom, the rows, the sizes.
A mail no sender took within an hour, or took and never answered within 15 minutes, is answered `failed` with that
reason (is `pgvigil run` up, and does its configuration name the channel?).

Two servers on one repository (two `pgvigil serve`) share the schedules safely: each due turn is claimed by one of
them with a lease and a token, one at a time just before its page is drawn, and queued only with that token; a
turn whose schedule was changed, turned off or claimed again while its page was drawn is refused and mails nothing
(the turn is mailed once, by the claim's holder).

A failed mail, a scheduled page that could not be drawn (any sender answers it: it needs no relay) and a mail no
sender answered are **alerted**: the sender sends a `report mail failed` warning at once on every channel of its
configuration (the failed one too: when only a recipient was refused, its relay takes the notice to the channel's
own addresses), naming the report, the mail and the error; on a PagerDuty or Opsgenie channel the notice is
resolved at once, as a Send test is, so it opens no incident that stays open. The schedule moves on to its next
turn either way: a broken page never mails in a loop.

## Rights

Report mail is behind the UI login and written through the actions door's audit login (the configuration's
repository dsn), like alert rules: `pgvigil serve -no-login` shows the page read only. The repository side
(migration 0107):

| Login | May |
|-------|-----|
| the audit login (IN ROLE `pgvigil_collector`) | `import_report_mail` (a schedule's add, edit, end, on, off), `import_report_mail_send` (a mail queued), `import_report_mail_claim` (the due turns, leased so two servers never mail one turn twice) |
| the sender (IN ROLE `pgvigil_alerter`) | `report_mail_due` and `report_mail_record`: read the mails owed and write their answers |
| a reader (IN ROLE `pgvigil_reader`) | read the schedules, the mails' log and the attempts |

A Send now or Send test is capped at 30 mails an hour per user (each reaches real addresses).
`report_mail_sends` is purged with the repository's purge window; the schedules and the attempts
(`report_mail_log`) are an audit and are not purged.

## Proof

`scripts/proof-reportmail.sh` (a demo fleet, a loopback SMTP sink, a headless Chromium, two serves): three pages
mailed with Send now and four on a schedule drawn by the servers (one in America/Los_Angeles, one with a column its
owner hid, one whose claim the proof takes over mid-render) and a Send test reach the sink, each schedule's turn
once, and each mail's every cell equals the page's screen (its words and its colours); every workbook opens with
openpyxl; a bad relay and an owner disabled before the turn are both failed and alerted; the role contract and
the write door are checked. `internal/reportmail` has the unit tests of the cron lines, the addresses, the body's
allowlist, the message and the render keys (`TestRendersDoor`, `TestRendersRace`); `TestLiveSMTP` mails one report
through a real relay when its three variables are set.
