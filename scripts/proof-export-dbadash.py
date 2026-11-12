#!/usr/bin/env python3
# Proof of parity P03, the part run where DBA Dash's own export is: pgvigil's Test Summary workbook (the fleet Summary
# bar's Export to Excel > Export Test Summary, kept by proof-export.sh under PGVIGIL_EXPORT_OUT) set beside DBA Dash's
# export of its Test Summary grid (summary-1.xlsx), part by part: the header's style, each status's fill, text colour,
# weight and number format, the rule that gives each cell its status (the same rows' states), the number formats, the
# table part, the sheet view and the column widths. Each part is said 'same' or 'DIFF' with what differs; the parts
# P03 makes equal fail the run when they differ, the ones kept on purpose are named (Expected below).
#
#   python3 scripts/proof-export-dbadash.py <pgvigil Test Summary .xlsx> <DBA Dash summary-1.xlsx> [export.ts]
#
# The column widths: pgvigil's rule (export.ts colWidth: Carlito's advance widths, read from export.ts, as ClosedXML
# measures; a header 1.0286 x its bold text + 22.19 px, another cell 1.0738 x its text + 0.52 px, (px - 0.025625) / 7,
# at most 150) is applied to DBA Dash's own cells and compared with the widths DBA Dash stored, column by column, in
# summary-1.xlsx and in every other DBA Dash export beside it (backups-1, jobs-1, summary-2 when present). pgvigil's
# own columns hold other words (its tests and its column names), so their widths are listed, not compared.
#
# Expected (written before the first run):
#   same   the header row: fill FF0063A3, white bold text, General; the status fills ok FF006638, crit FFAB1F26, N/A
#          FFE0E1E9 (and warn FFE49325 when either file shows one) with text white / white / FF004F83, none bold; every
#          count General (numFmt 0); both files follow DBA Dash's Test Summary rule (a count 0 green, above 0 its
#          column's status; the test's name its row's worst of critical and warning, else green); the table: one part,
#          ref = its autoFilter's = the sheet's dimension, no style name, showRowStripes 1, showColumnStripes 0, the
#          header cells shared strings equal to the table's column names; no frozen pane; DBA Dash's widths re-measured
#          by pgvigil's rule within 6 px (under one character) in every column of every DBA Dash export read
#   named  (kept on purpose, said and not failed) the orange's text (pgvigil the screen's dark FF1D1300, DBA Dash white:
#          2.5:1); the sheets (pgvigil a Summary sheet first, task 153, and the grid's sheet named; DBA Dash 'Sheet1');
#          DBA Dash's tableColumn dataDxfId (ClosedXML marks a column whose cells share one style) and its fill 00FFFFFF
#          on a plain cell with a format (none in a Test Summary); pgvigil's own column names and widths
import re, sys, zipfile

def load(path):
    z = zipfile.ZipFile(path)
    def part(n):
        if n not in z.namelist(): return ''
        x = z.read(n).decode('utf-8-sig')
        return re.sub(r'<(/?)x:', r'<\1', x)   # DBA Dash's writer prefixes every element with x:
    wb = part('xl/workbook.xml')
    sheets = re.findall(r'<sheet name="([^"]*)"', wb)
    st = part('xl/styles.xml')
    fmts = {int(i): c for i, c in re.findall(r'<numFmt numFmtId="(\d+)" formatCode="([^"]*)"', st)}
    fills = re.findall(r'<fill>(.*?)</fill>', re.search(r'<fills[^>]*>(.*?)</fills>', st, re.S).group(1), re.S)
    fonts = re.findall(r'<font>(.*?)</font>', re.search(r'<fonts[^>]*>(.*?)</fonts>', st, re.S).group(1), re.S)
    xfs = []
    for a in re.findall(r'<xf ([^>]*?)/?>', re.search(r'<cellXfs[^>]*>(.*?)</cellXfs>', st, re.S).group(1)):
        g = lambda k: int((re.search(k + r'="(\d+)"', a) or [0, '0'])[1])
        f = re.search(r'fgColor rgb="(\w+)"', fills[g('fillId')]) if g('fillId') < len(fills) else None
        fo = fonts[g('fontId')] if g('fontId') < len(fonts) else ''
        c = re.search(r'color rgb="(\w+)"', fo)
        xfs.append({'fmt': g('numFmtId'), 'fill': f.group(1) if f else None, 'font': c.group(1) if c else None, 'bold': bool(re.search(r'<b\s*/>', fo))})
    sst = [re.sub(r'<[^>]+>', '', s) for s in re.findall(r'<si>(.*?)</si>', part('xl/sharedStrings.xml'), re.S)]
    sst = [s.replace('&lt;', '<').replace('&gt;', '>').replace('&quot;', '"').replace('&apos;', "'").replace('&amp;', '&') for s in sst]
    return z, part, sheets, fmts, xfs, sst

def colidx(c):
    n = 0
    for ch in c: n = n * 26 + ord(ch) - 64
    return n - 1

def cells(x, sst):
    out = {}
    for m in re.finditer(r'<c r="([A-Z]+)(\d+)"((?:\s+\w+="[^"]*")*)\s*(?:/>|>(.*?)</c>)', x, re.S):
        attrs = dict(re.findall(r'(\w+)="([^"]*)"', m.group(3))); body = m.group(4) or ''
        v = re.search(r'<v>([^<]*)</v>', body); t = re.search(r'<t[^>]*>([^<]*)</t>', body)
        s = int(attrs.get('s', 0)); ty = attrs.get('t')
        if ty == 's': val, text = None, sst[int(v.group(1))]
        elif ty == 'inlineStr': val, text = None, (t.group(1) if t else '')
        elif ty == 'b': val, text = None, ('TRUE' if v and v.group(1) == '1' else 'FALSE')
        else: val, text = (float(v.group(1)) if v else None), None
        out[(int(m.group(2)), colidx(m.group(1)))] = (s, val, text)
    return out

def sheet_of(z, part, sheets, want):
    # the grid's sheet: DBA Dash's only one; pgvigil's the one after its Summary sheet
    i = sheets.index(want) + 1 if want in sheets else 1
    rels = part('xl/_rels/workbook.xml.rels'); wb = part('xl/workbook.xml')
    rid = re.findall(r'<sheet name="[^"]*" sheetId="\d+" r:id="(\w+)"', wb)[i - 1]
    target = re.search(r'Id="' + rid + r'"[^>]*Target="([^"]+)"', rels) or re.search(r'Target="([^"]+)"[^>]*Id="' + rid + '"', rels)
    path = 'xl/' + target.group(1).lstrip('/').replace('xl/', '')
    x = part(path)
    srels = part(path.replace('worksheets/', 'worksheets/_rels/') + '.rels')
    tt = re.search(r'Target="(?:\.\./|/xl/)tables/(table\d+\.xml)"', srels)   # pgvigil's relative target, DBA Dash's absolute
    return x, part('xl/tables/' + tt.group(1)) if tt else ''

STATES = {'FF006638': 'ok', 'FFE49325': 'warn', 'FFAB1F26': 'crit', 'FFE0E1E9': 'none', 'FF1B6AA3': 'ack'}
COLST = ['ok', 'warn', 'crit', 'none', 'ack']

def grade(name, z, part, sheets, fmts, xfs, sst, want_sheet):
    x, tx = sheet_of(z, part, sheets, want_sheet)
    cs = cells(x, sst)
    rows = sorted({r for r, _ in cs})
    ncol = max(c for _, c in cs) + 1
    info = {'x': x, 'tx': tx, 'cells': cs, 'ncol': ncol, 'rows': len(rows) - 1}
    hs = {cs[(1, j)][0] for j in range(ncol) if (1, j) in cs}
    info['head'] = sorted({(xfs[s]['fill'], xfs[s]['font'], xfs[s]['bold'], xfs[s]['fmt']) for s in hs})
    info['head_shared'] = all(re.search(r'<c r="[A-Z]+1"[^>]*t="s"', x) is not None for _ in [0]) and len(re.findall(r'<c r="[A-Z]+1"[^>]*t="s"', x)) == ncol
    per = {}
    rule = []
    for r in rows[1:]:
        vals = [cs.get((r, j), (0, None, None)) for j in range(ncol)]
        for j, (s, v, t) in enumerate(vals):
            st = STATES.get(xfs[s]['fill'])
            if st: per.setdefault(st, set()).add((xfs[s]['font'], xfs[s]['bold'], xfs[s]['fmt'] if j else None))
        nums = [v for _, v, _ in vals[1:6]]
        for j, v in enumerate(nums):
            want = 'ok' if not v else COLST[j]
            got = STATES.get(xfs[vals[j + 1][0]]['fill'])
            if got != want: rule.append(f'row {r} column {j + 2}: {v} is {got}, the rule says {want}')
        worst = 'crit' if nums[2] else 'warn' if nums[1] else 'ok'
        if STATES.get(xfs[vals[0][0]]['fill']) != worst: rule.append(f'row {r}: the test {vals[0][2]!r} is {STATES.get(xfs[vals[0][0]]["fill"])}, the rule says {worst}')
    info['per'] = {k: sorted(v, key=str) for k, v in per.items()}
    info['rule'] = rule
    info['countfmt'] = sorted({xfs[cs[(r, j)][0]]['fmt'] for r in rows[1:] for j in range(1, 6) if (r, j) in cs and cs[(r, j)][1] is not None})
    info['pane'] = '<pane' in x
    info['tsi'] = dict(re.findall(r'(\w+)="([^"]*)"', (re.search(r'<tableStyleInfo([^>]*)/?>', tx) or [None, ''])[1]))
    info['tref'] = [(re.search(p, s) or [None, None])[1] for p, s in ((r'<table [^>]*\bref="([^"]+)"', tx), (r'<autoFilter ref="([^"]+)"', tx), (r'<dimension ref="([^"]+)"', x))]
    info['tcols'] = re.findall(r'<tableColumn id="\d+" name="([^"]*)"', tx)
    info['dxf'] = len(re.findall(r'dataDxfId=', tx))
    info['hdr'] = [cs.get((1, j), (0, None, None))[2] for j in range(ncol)]
    info['widths'] = {int(a) - 1: float(w) for a, b, w in re.findall(r'<col min="(\d+)" max="(\d+)" width="([\d.]+)"', x) if a == b}
    return info

def rule_px(src):
    adv = [int(v) for v in re.search(r'const ADV = \[([^\]]*)\]', src).group(1).split(',')]
    adv_b = [int(v) for v in re.search(r'const ADV_B = \[([^\]]*)\]', src).group(1).split(',')]
    def tpx(t, bold):
        a = adv_b if bold else adv
        return sum(a[ord(ch) - 32] if 32 <= ord(ch) <= 126 else 2048 if ord(ch) >= 0x2e80 else (1030 if bold else 1013) for ch in t) * 11 * 96 / 72 / 2048
    return lambda t, head: 1.0286 * tpx(t, True) + 22.19 if head else 1.0738 * tpx(t, False) + 0.52

def remeasure(path, px):
    # DBA Dash's own export: every column's cells as Excel shows them, measured by pgvigil's rule, against the stored width
    import datetime
    z, part, sheets, fmts, xfs, sst = load(path)
    x, _ = sheet_of(z, part, sheets, sheets[0])
    cs = cells(x, sst); widths = {}
    for a, b, w in re.findall(r'<col min="(\d+)" max="(\d+)" width="([\d.]+)"', x):
        for k in range(int(a), int(b) + 1): widths[k - 1] = float(w)
    best = {}
    for (r, c), (s, v, t) in cs.items():
        f = fmts.get(xfs[s]['fmt'], '')
        if t is None and v is not None:
            if f == 'yyyy-MM-dd HH:mm': t = (datetime.datetime(1899, 12, 30) + datetime.timedelta(days=v)).strftime('%Y-%m-%d %H:%M')
            elif f in ('0.0%', '0.00%'): t = f"{v * 100:.{1 if f == '0.0%' else 2}f}%"
            else: t = repr(v) if v != int(v) else str(int(v))
        if not t: continue
        best[c] = max(best.get(c, 0), px(t, r == 1))
    out = []
    for c, w in sorted(widths.items()):
        p = round(best.get(c, 0)); want = 8.43 if p <= 0 else min(150, (p - 0.025625) / 7)
        out.append((c, w, want, (want - w) * 7))
    return out

def main():
    if len(sys.argv) < 3:
        print(__doc__ or 'usage: proof-export-dbadash.py <pgvigil Test Summary .xlsx> <DBA Dash summary-1.xlsx> [export.ts]'); sys.exit(2)
    pg_path, dd_path = sys.argv[1], sys.argv[2]
    src = open(sys.argv[3] if len(sys.argv) > 3 else 'web/src/export.ts').read()
    bad = 0
    def same(ok, what, diff=''):
        nonlocal bad
        print(('same ' if ok else 'DIFF ') + what + ('' if ok else ': ' + diff))
        if not ok: bad += 1
    def named(what): print('named ' + what)
    pg = load(pg_path); dd = load(dd_path)
    P = grade('pgvigil', *pg, 'Test Summary'); D = grade('DBA Dash', *dd, dd[2][0])
    print(f"     pgvigil {pg_path}: sheets {pg[2]}, {P['rows']} rows x {P['ncol']} columns; DBA Dash {dd_path}: sheets {dd[2]}, {D['rows']} rows x {D['ncol']} columns")
    same(P['head'] == D['head'] == [('FF0063A3', 'FFFFFFFF', True, 0)], f"the header row: fill, text colour, bold, number format {D['head']}", f"pgvigil {P['head']}, DBA Dash {D['head']}")
    # each status, per kind of cell (a count, or a test's name), where both files show one: its text colour, weight, format
    for k in sorted(set(P['per']) | set(D['per'])):
        for kind, isname in (('count', False), ('test name', True)):
            p = sorted({x for x in P['per'].get(k, []) if (x[2] is None) == isname}, key=str)
            d = sorted({x for x in D['per'].get(k, []) if (x[2] is None) == isname}, key=str)
            if not p or not d:
                if p or d: print(f"     {k} {kind}: only {'pgvigil' if p else 'DBA Dash'} shows one in these rows ({p or d})")
                continue
            if k == 'warn' and {x[0] for x in p} == {'FF1D1300'} and {x[0] for x in d} == {'FFFFFFFF'}:
                named(f"warn {kind}: the orange's text is pgvigil's screen colour FF1D1300 (DBA Dash white, 2.5:1 on the orange)")
                same({x[1:] for x in p} == {x[1:] for x in d}, f"warn {kind}: not bold, the same number format {sorted({x[1:] for x in d}, key=str)}", f"pgvigil {p}, DBA Dash {d}")
                continue
            same(p == d, f"{k} {kind}: text colour, weight and number format {d}", f"pgvigil {p}, DBA Dash {d}")
    same(not P['rule'] and not D['rule'], f"both follow DBA Dash's Test Summary rule (a count 0 green, above 0 its column's status; the test its row's worst) over {P['rows']} and {D['rows']} rows", f"pgvigil {P['rule'][:3]}, DBA Dash {D['rule'][:3]}")
    same(P['countfmt'] == D['countfmt'] == [0], f"every count General (numFmt 0) {D['countfmt']}", f"pgvigil {P['countfmt']}, DBA Dash {D['countfmt']}")
    same(not P['pane'] and not D['pane'], "no frozen pane", f"pgvigil {P['pane']}, DBA Dash {D['pane']}")
    keys = ('showFirstColumn', 'showLastColumn', 'showRowStripes', 'showColumnStripes')
    same(all(P['tsi'].get(k) == D['tsi'].get(k) for k in keys) and 'name' not in P['tsi'] and 'name' not in D['tsi'], f"the table's style info {D['tsi']} (no style name)", f"pgvigil {P['tsi']}, DBA Dash {D['tsi']}")
    same(len(set(P['tref'])) == 1 and P['tref'][0] is not None and len(set(D['tref'])) == 1, f"the table's ref = its autoFilter's = the sheet's dimension (pgvigil {P['tref'][0]}, DBA Dash {D['tref'][0]})", f"pgvigil {P['tref']}, DBA Dash {D['tref']}")
    same(P['tcols'] == P['hdr'] and D['tcols'] == D['hdr'] and P['head_shared'] and D['head_shared'], "the header cells are shared strings equal to the table's column names", f"pgvigil {P['tcols']} / {P['hdr']}, DBA Dash {D['tcols']} / {D['hdr']}")
    if D['dxf']: named(f"DBA Dash's table marks {D['dxf']} column(s) dataDxfId (ClosedXML: a column whose cells share one style); pgvigil writes none ({P['dxf']})")
    named(f"the sheets: pgvigil {pg[2]} (its Summary sheet first, task 153; the grid's sheet named), DBA Dash {dd[2]}")
    named(f"the columns: pgvigil {P['hdr']} (its own words), DBA Dash {D['hdr']}")
    print('     widths, column by column (pgvigil | DBA Dash): ' + '; '.join(f"{(P['hdr'][j] or '')!s}: {P['widths'].get(j)} | {(D['hdr'][j] if j < len(D['hdr']) else '') or ''}: {D['widths'].get(j)}" for j in range(max(P['ncol'], D['ncol']))))
    px = rule_px(src)
    import os
    folder = os.path.dirname(os.path.abspath(dd_path)); worst = 0; n = 0; far = []
    for f in sorted({os.path.abspath(dd_path)} | {os.path.join(folder, x) for x in os.listdir(folder) if x.endswith('.xlsx')}):
        try: res = remeasure(f, px)
        except Exception as e: print(f'     {os.path.basename(f)}: not read ({e})'); continue
        for c, w, want, dpx in res:
            n += 1; worst = max(worst, abs(dpx))
            if abs(dpx) > 6: far.append(f'{os.path.basename(f)} column {c + 1}: DBA Dash {w}, the rule {round(want, 6)} ({dpx:+.1f} px)')
        print(f"     {os.path.basename(f)}: {len(res)} columns re-measured by pgvigil's rule, {sum(1 for r in res if abs(r[3]) <= 0.5)} to the pixel, the furthest {max((abs(r[3]) for r in res), default=0):.1f} px")
    if far: print(f"     {len(far)} column(s) further than 6 px: {far[:4]}")
    same(n > 0 and not far, f"DBA Dash's widths re-measured by pgvigil's rule: {n} columns, every one within 6 px (under one character), the furthest {worst:.1f} px", f"{len(far)} columns further than 6 px")
    print(f"{'OK' if not bad else 'NOT OK'}: pgvigil's Test Summary export beside DBA Dash's summary-1.xlsx ({bad} part(s) differ)")
    sys.exit(1 if bad else 0)

main()
