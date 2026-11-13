#!/usr/bin/env python3
"""xlsx-check.py - the grid export's file rules, read from the .xlsx as a zip of XML (no package).

  python3 -I scripts/xlsx-check.py rules FILE.xlsx [FILE.xlsx ...]
      X0-X12 on each workbook: one 'PASS Xn <file>' or 'FAIL Xn <file>: <count> - <first problems>' line per rule, then
      '<file>: PASS' or '<file>: FAIL Xa,Xb'. Exit 1 when any rule fails.
  python3 -I scripts/xlsx-check.py same REFERENCE.xlsx FILE.xlsx
      the reference (DBA Dash's file of a grid) against pgvigil's file of the same grid: one 'SAME <property>' or
      'DIFF <property>: <reference> | <file>' line per property. Exit 0 (a report, not a verdict).

The rules (a 'grid sheet' is every sheet but a LAST sheet named 'About'):
  X0  every cell of a grid sheet is the header style (row 1) or one named pair or plain: no other fill, font colour,
      weight, slant, underline, size, border, alignment or wrap; no row of a custom height (plain = no fill and no
      text colour of its own or black FF000000)
  X1  the workbook opens on a grid: sheet 1 holds one Excel table (a grid; not an Item | Value sheet, not 'About'),
      activeTab 0
  X2  sheet names: 1-31 characters, none of \\ / ? * [ ] :, unique ignoring case, no read time, no numbered repeat ' (n)',
      not 'History'
  X3  a Warning cell (fill FFE49325) has text FF1D1300 or FFFFFFFF
  X4  row 1 of a grid sheet: fill FF0063A3, white bold Calibri 11, nothing else
  X5  one Excel table per grid sheet over the whole grid (an empty grid: header + one empty row), autofilter = its ref,
      no table style name, no sheet autofilter, no _FilterDatabase; Excel's repair rules (names = header texts,
      non-empty, unique ignoring case, as many as the header's cells)
  X6  no pane on any sheet
  X7  each cell's number format is General (id 0 or an empty code), '0', '0.0%', '0.00%' or 'yyyy-MM-dd HH:mm'
  X8  no text cell that reads as a date-time (a date is a number under its format; a column's empty value may be text)
  X9  no text cell whose whole value is true / false
  X10 every column holding a value has a custom width of at most 150 characters (stored 150.71 with the padding); a numeric column at least as wide as its widest
      shown number (a digit one unit, any other character half)
  X11 no hyperlink to a place inside the application ('#/') or a jump inside the workbook; no underlined cell without an
      external hyperlink
  X12 no drawing, chart or picture part
Not checkable from a file (proof-export.sh holds them): the page order of a page's sheets, a grid's own export holding
that grid alone, a chart's series as its sheet, a number being the one the grid shows.
"""
import posixpath
import re
import sys
import zipfile
import xml.etree.ElementTree as ET

M = 'http://schemas.openxmlformats.org/spreadsheetml/2006/main'
R = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships'
PR = 'http://schemas.openxmlformats.org/package/2006/relationships'
NS = {'m': M, 'r': R, 'pr': PR}
RID = '{%s}id' % R

BUILTIN = {0: 'General', 1: '0', 2: '0.00', 3: '#,##0', 4: '#,##0.00', 9: '0%', 10: '0.00%', 11: '0.00E+00', 14: 'mm-dd-yy',
           15: 'd-mmm-yy', 16: 'd-mmm', 17: 'mmm-yy', 18: 'h:mm AM/PM', 19: 'h:mm:ss AM/PM', 20: 'h:mm', 21: 'h:mm:ss',
           22: 'm/d/yy h:mm', 45: 'mm:ss', 46: '[h]:mm:ss', 47: 'mmss.0', 49: '@'}
DATE_FMT = 'yyyy-MM-dd HH:mm'
FORMATS_OK = {'General', '', '0', '0.0%', '0.00%', DATE_FMT}
HEAD = ('FF0063A3', 'FFFFFFFF')
# the named pairs: fill -> the text colours allowed on it
PAIRS = {
    'FF006638': {'FFFFFFFF'},              # OK
    'FFAB1F26': {'FFFFFFFF'},              # Critical
    'FFE49325': {'FF1D1300', 'FFFFFFFF'},  # Warning: pgvigil's dark text, DBA Dash's white
    'FFE0E1E9': {'FF004F83'},              # N/A
    'FF1B6AA3': {'FFFFFFFF'},              # Acknowledged (pgvigil)
    'FF217CBB': {'FFFFFFFF'},              # Acknowledged (DBA Dash)
    'FFF1F1F6': {'FF004F83'},              # a link cell
    '00FFFFFF': {'00000000'},              # DBA Dash's transparent (a date or percent cell without a colour of its own)
}
PLAIN_TEXT = {None, 'FF000000'}
MAX_WIDTH = 150 + 5 / 7 + 1e-6   # 150 characters and Excel's 5 px of padding: DBA Dash's capped column is stored 150.71   # a plain cell: no fill, the default text (no colour of its own, or Excel's automatic black)
RULES = ['X0', 'X1', 'X2', 'X3', 'X4', 'X5', 'X6', 'X7', 'X8', 'X9', 'X10', 'X11', 'X12']
DATE_TEXT = re.compile(r'^\s*\d{4}-\d{2}-\d{2}[ T]\d{1,2}:\d{2}')
READ_TIME = re.compile(r'\d{1,4}[ ./-]\d{1,2}[ ./-]\d{2,4}|\b\d{1,2} \d{2} \d{2}\b|\d{1,2}:\d{2}')


def xml(zf, part):
    try:
        return ET.fromstring(zf.read(part))
    except KeyError:
        return None


def rels(zf, part):
    folder, name = posixpath.split(part)
    root = xml(zf, posixpath.join(folder, '_rels', name + '.rels'))
    out = {}
    for rel in (root.findall('pr:Relationship', NS) if root is not None else []):
        tgt = rel.get('Target', '')
        ext = rel.get('TargetMode') == 'External'
        out[rel.get('Id')] = {'type': rel.get('Type', '').rsplit('/', 1)[-1], 'ext': ext,
                              'target': tgt if ext else posixpath.normpath(posixpath.join(folder, tgt)) if not tgt.startswith('/') else tgt.lstrip('/')}
    return out


def colour(el):
    if el is None:
        return None
    return el.get('rgb').upper() if el.get('rgb') else None   # theme, indexed and auto colours count as no colour of the cell's own


def col_index(ref):
    letters = re.match(r'[A-Z]+', ref).group(0)
    n = 0
    for ch in letters:
        n = n * 26 + ord(ch) - 64
    return n


def row_index(ref):
    return int(re.search(r'\d+', ref).group(0))


def col_letters(n):
    s = ''
    while n:
        n, r = divmod(n - 1, 26)
        s = chr(65 + r) + s
    return s


class Book:
    def __init__(self, path):
        self.path = path
        zf = self.zf = zipfile.ZipFile(path)
        self.parts = zf.namelist()
        st = xml(zf, 'xl/styles.xml')
        fmts = dict(BUILTIN)
        for nf in (st.findall('m:numFmts/m:numFmt', NS) if st is not None else []):
            fmts[int(nf.get('numFmtId'))] = nf.get('formatCode', '')
        fonts = []
        for f in (st.findall('m:fonts/m:font', NS) if st is not None else []):
            u = f.find('m:u', NS)
            sz = f.find('m:sz', NS)
            fonts.append({'colour': colour(f.find('m:color', NS)),
                          'bold': f.find('m:b', NS) is not None and f.find('m:b', NS).get('val', '1') not in ('0', 'false'),
                          'italic': f.find('m:i', NS) is not None and f.find('m:i', NS).get('val', '1') not in ('0', 'false'),
                          'underline': u is not None and u.get('val', 'single') != 'none',
                          'size': float(sz.get('val')) if sz is not None else 11.0,
                          'name': (f.find('m:name', NS).get('val') if f.find('m:name', NS) is not None else None)})
        fills = []
        for f in (st.findall('m:fills/m:fill', NS) if st is not None else []):
            p = f.find('m:patternFill', NS)
            solid = p is not None and p.get('patternType') == 'solid'
            fills.append(colour(p.find('m:fgColor', NS)) if solid else None)
        borders = []
        for b in (st.findall('m:borders/m:border', NS) if st is not None else []):
            borders.append(any(side.get('style') not in (None, 'none') for side in b if side.tag.split('}')[1] in ('left', 'right', 'top', 'bottom', 'diagonal')))
        self.xfs = []
        for x in (st.findall('m:cellXfs/m:xf', NS) if st is not None else []):
            al = x.find('m:alignment', NS)
            fid = int(x.get('numFmtId', 0))
            font = fonts[int(x.get('fontId', 0))] if int(x.get('fontId', 0)) < len(fonts) else {}
            self.xfs.append({'fmt_id': fid, 'fmt': fmts.get(fid, 'id %d' % fid),
                             'fill': fills[int(x.get('fillId', 0))] if int(x.get('fillId', 0)) < len(fills) else None,
                             'font': font, 'border': borders[int(x.get('borderId', 0))] if int(x.get('borderId', 0)) < len(borders) else False,
                             'halign': al.get('horizontal') if al is not None else None,
                             'valign': al.get('vertical') if al is not None else None,
                             'wrap': al is not None and al.get('wrapText') in ('1', 'true')})
        if not self.xfs:
            self.xfs = [{'fmt_id': 0, 'fmt': 'General', 'fill': None, 'font': {}, 'border': False, 'halign': None, 'valign': None, 'wrap': False}]
        sst = xml(zf, 'xl/sharedStrings.xml')
        self.sst = [''.join(t.text or '' for t in si.iter('{%s}t' % M)) for si in (sst.findall('m:si', NS) if sst is not None else [])]
        wb = xml(zf, 'xl/workbook.xml')
        wbr = rels(zf, 'xl/workbook.xml')
        view = wb.find('m:bookViews/m:workbookView', NS) if wb is not None else None
        self.active = int(view.get('activeTab', 0)) if view is not None else 0
        self.filter_names = [dn.get('name') for dn in (wb.findall('m:definedNames/m:definedName', NS) if wb is not None else [])
                             if dn.get('name', '').lower() == '_xlnm._filterdatabase']
        self.sheets = []
        for sh in (wb.findall('m:sheets/m:sheet', NS) if wb is not None else []):
            part = wbr.get(sh.get(RID), {}).get('target')
            self.sheets.append(self.read_sheet(sh.get('name'), part))
        n = len(self.sheets)
        for i, s in enumerate(self.sheets):
            s['about'] = i == n - 1 and n > 1 and s['name'] == 'About'
            s['grid'] = not s['about']

    def text(self, c):
        t = c.get('t', 'n')
        v = c.find('m:v', NS)
        if t == 's' and v is not None:
            return self.sst[int(v.text)]
        if t == 'inlineStr':
            return ''.join(x.text or '' for x in c.iter('{%s}t' % M))
        return v.text if v is not None else None

    def read_sheet(self, name, part):
        root = xml(self.zf, part) if part else None
        s = {'name': name, 'part': part, 'cells': [], 'rows': {}, 'cols': [], 'pane': False, 'autofilter': None,
             'hyperlinks': [], 'tables': [], 'drawing': False}
        if root is None:
            return s
        srels = rels(self.zf, part)
        s['pane'] = root.find('m:sheetViews/m:sheetView/m:pane', NS) is not None
        af = root.find('m:autoFilter', NS)
        s['autofilter'] = af.get('ref') if af is not None else None
        s['drawing'] = root.find('m:drawing', NS) is not None
        for c in root.findall('m:cols/m:col', NS):
            s['cols'].append({'min': int(c.get('min')), 'max': int(c.get('max')), 'width': float(c.get('width', 0)),
                              'custom': c.get('customWidth') in ('1', 'true')})
        for row in root.findall('m:sheetData/m:row', NS):
            rn = int(row.get('r'))
            s['rows'][rn] = {'custom': row.get('customHeight') in ('1', 'true'), 'ht': row.get('ht')}
            for c in row.findall('m:c', NS):
                ref = c.get('r')
                t = c.get('t', 'n')
                val = self.text(c)
                s['cells'].append({'ref': ref, 'row': row_index(ref), 'col': col_index(ref), 't': t, 'v': val,
                                   'xf': self.xfs[int(c.get('s', 0))] if int(c.get('s', 0)) < len(self.xfs) else self.xfs[0]})
        for h in root.findall('m:hyperlinks/m:hyperlink', NS):
            r = srels.get(h.get(RID), {}) if h.get(RID) else {}
            s['hyperlinks'].append({'ref': h.get('ref'), 'location': h.get('location'), 'target': r.get('target'), 'ext': r.get('ext', False)})
        for tp in root.findall('m:tableParts/m:tablePart', NS):
            tpart = srels.get(tp.get(RID), {}).get('target')
            troot = xml(self.zf, tpart) if tpart else None
            if troot is None:
                s['tables'].append({'missing': tpart})
                continue
            tsi = troot.find('m:tableStyleInfo', NS)
            taf = troot.find('m:autoFilter', NS)
            s['tables'].append({'ref': troot.get('ref'), 'autofilter': taf.get('ref') if taf is not None else None,
                                'style': tsi.get('name') if tsi is not None else None,
                                'cols': [tc.get('name') for tc in troot.findall('m:tableColumns/m:tableColumn', NS)]})
        return s


def shown_number(v, fmt):
    """the text Excel draws for a number under its format (the width floor's measure)"""
    try:
        x = float(v)
    except (TypeError, ValueError):
        return str(v)
    if fmt == '0.0%':
        return '%.1f%%' % (x * 100)
    if fmt == '0.00%':
        return '%.2f%%' % (x * 100)
    if fmt == DATE_FMT:
        return '0000-00-00 00:00'
    if fmt == '0':
        return '%d' % round(x)
    if x == int(x) and abs(x) < 1e11:
        return '%d' % x
    for p in range(10, 0, -1):   # General: at most 11 characters
        t = ('%.' + str(p) + 'g') % x
        if len(t) <= 11:
            return t
    return '%.5E' % x


def floor_units(t):
    return sum(1.0 if ch.isdigit() else 0.5 for ch in t)


def check(book):
    out = {r: [] for r in RULES}
    grids = [s for s in book.sheets if s['grid']]
    # X1
    if not book.sheets:
        out['X1'].append('no sheet')
    else:
        first = book.sheets[0]
        head = [c['v'] for c in sorted((c for c in first['cells'] if c['row'] == 1), key=lambda c: c['col'])]
        if first['name'] == 'About' or [str(h or '').strip().lower() for h in head[:2]] == ['item', 'value'] or len(first['tables']) != 1:
            out['X1'].append("sheet 1 '%s' is not a grid (header %s; %d tables)" % (first['name'], ' | '.join(str(h) for h in head[:3]), len(first['tables'])))
        if book.active != 0:
            out['X1'].append('activeTab %d' % book.active)
    for i, s in enumerate(book.sheets):
        if s['name'] == 'About' and not s['about']:
            out['X1'].append("'About' is sheet %d of %d, not the last" % (i + 1, len(book.sheets)))
    # X2
    seen = set()
    for s in book.sheets:
        n = s['name'] or ''
        if not 1 <= len(n) <= 31:
            out['X2'].append("'%s' has %d characters" % (n, len(n)))
        if re.search(r'[\\/?*\[\]:]', n):
            out['X2'].append("'%s' holds a refused character" % n)
        if n.lower() in seen:
            out['X2'].append("'%s' twice" % n)
        seen.add(n.lower())
        if READ_TIME.search(n):
            out['X2'].append("'%s' carries a time" % n)
        if re.search(r' \(\d+\)$', n):
            out['X2'].append("'%s' is a numbered repeat" % n)
        if n.lower() == 'history':
            out['X2'].append("'%s' is reserved" % n)
    for s in book.sheets:
        last_row = max([c['row'] for c in s['cells']] + list(s['rows'].keys()) + [0])
        last_col = max([c['col'] for c in s['cells']] + [0])
        s['last'] = (last_row, last_col)
        if s['pane']:
            out['X6'].append("'%s' has a pane" % s['name'])
        if s['drawing']:
            out['X12'].append("'%s' has a drawing" % s['name'])
        for h in s['hyperlinks']:
            if h['location']:
                out['X11'].append("'%s'!%s jumps to %s" % (s['name'], h['ref'], h['location']))
            elif h['target'] and '#/' in h['target']:
                out['X11'].append("'%s'!%s links into the application (%s)" % (s['name'], h['ref'], h['target'][:60]))
        linked = {h['ref'] for h in s['hyperlinks'] if h['ext'] and h['target'] and re.match(r'https?://', h['target']) and '#/' not in h['target']}
        for c in s['cells']:
            if c['xf']['font'].get('underline') and c['ref'] not in linked:
                out['X11'].append("'%s'!%s underlined without a link" % (s['name'], c['ref']))
    for p in book.parts:
        if p.startswith(('xl/drawings/', 'xl/charts/', 'xl/media/')):
            out['X12'].append(p)
    for s in grids:
        nm = s['name']
        cells_by_ref = {c['ref']: c for c in s['cells']}
        head = sorted((c for c in s['cells'] if c['row'] == 1), key=lambda c: c['col'])
        # X4 the header row
        if not head:
            out['X4'].append("'%s' has no header row" % nm)
        for c in head:
            x, f = c['xf'], c['xf']['font']
            bad = []
            if x['fill'] != HEAD[0]:
                bad.append('fill %s' % x['fill'])
            if f.get('colour') != HEAD[1]:
                bad.append('text %s' % f.get('colour'))
            if not f.get('bold'):
                bad.append('not bold')
            if f.get('italic') or f.get('underline'):
                bad.append('italic or underlined')
            if f.get('size', 11) != 11:
                bad.append('size %s' % f.get('size'))
            if x['border'] or x['wrap'] or x['halign'] not in (None, 'general') or x['valign'] not in (None, 'bottom'):
                bad.append('border / wrap / alignment %s %s' % (x['halign'], x['valign']))
            if bad:
                out['X4'].append("'%s'!%s %s" % (nm, c['ref'], ', '.join(bad)))
        if s['rows'].get(1, {}).get('custom'):
            out['X4'].append("'%s' row 1 has a custom height" % nm)
        # X0 every other cell: plain or a named pair
        for c in s['cells']:
            if c['row'] == 1:
                continue
            x, f = c['xf'], c['xf']['font']
            fill, text = x['fill'], f.get('colour')
            if fill is None:
                ok = text in PLAIN_TEXT
            else:
                ok = text in PAIRS.get(fill, set())
            bad = [] if ok else ['fill %s text %s' % (fill, text)]
            if f.get('bold') or f.get('italic') or f.get('underline'):
                bad.append('bold / italic / underlined')
            if f.get('size', 11) != 11:
                bad.append('size %s' % f.get('size'))
            if x['border'] or x['wrap'] or x['halign'] not in (None, 'general') or x['valign'] not in (None, 'bottom'):
                bad.append('border / wrap / alignment %s %s' % (x['halign'], x['valign']))
            if bad:
                out['X0'].append("'%s'!%s %s" % (nm, c['ref'], ', '.join(bad)))
            # X3
            if fill == 'FFE49325' and text not in PAIRS['FFE49325']:
                out['X3'].append("'%s'!%s Warning with text %s" % (nm, c['ref'], text))
        for rn, r in s['rows'].items():
            if rn > 1 and r['custom']:
                out['X0'].append("'%s' row %d has a custom height %s" % (nm, rn, r['ht']))
        # X5 the table
        last_row, last_col = s['last']
        tabs = s['tables']
        if len(tabs) != 1:
            out['X5'].append("'%s' has %d tables" % (nm, len(tabs)))
        for t in tabs:
            if 'missing' in t:
                out['X5'].append("'%s' table part %s missing" % (nm, t['missing']))
                continue
            want = 'A1:%s%d' % (col_letters(max(last_col, 1)), max(last_row, 2))
            if t['ref'] != want:
                out['X5'].append("'%s' table %s, grid %s" % (nm, t['ref'], want))
            if t['autofilter'] != t['ref']:
                out['X5'].append("'%s' table autofilter %s" % (nm, t['autofilter']))
            if t['style']:
                out['X5'].append("'%s' table style %s" % (nm, t['style']))
            heads = [str(c['v'] if c['v'] is not None else '') for c in head]
            if len(t['cols']) != max(last_col, 1):
                out['X5'].append("'%s' %d table columns, %d header cells" % (nm, len(t['cols']), last_col))
            low = [str(n or '').lower() for n in t['cols']]
            if any(not n for n in low) or len(set(low)) != len(low):
                out['X5'].append("'%s' table column names empty or repeated" % nm)
            if [str(n) for n in t['cols']] != heads[:len(t['cols'])]:
                out['X5'].append("'%s' table column names differ from the header cells" % nm)
        if s['autofilter']:
            out['X5'].append("'%s' has a sheet autofilter %s" % (nm, s['autofilter']))
        # X7 / X8 / X9 / X10 per cell
        widest = {}
        for c in s['cells']:
            if c['row'] == 1 or c['v'] is None:
                continue
            fmt = c['xf']['fmt']
            if fmt not in FORMATS_OK and c['xf']['fmt_id'] != 0:
                out['X7'].append("'%s'!%s format %s" % (nm, c['ref'], fmt))
            text_cell = c['t'] in ('s', 'inlineStr', 'str')
            if text_cell and DATE_TEXT.match(c['v'] or ''):
                out['X8'].append("'%s'!%s date as text '%s'" % (nm, c['ref'], c['v']))
            if text_cell and re.fullmatch(r'\s*(true|false)\s*', c['v'] or '', re.I):
                out['X9'].append("'%s'!%s '%s' as text" % (nm, c['ref'], c['v']))
            if c['t'] in ('n',) and c['v'] not in (None, ''):
                u = floor_units(shown_number(c['v'], fmt))
                widest[c['col']] = max(widest.get(c['col'], 0), u)
        valued = {c['col'] for c in s['cells'] if c['v'] not in (None, '')}
        for j in sorted(valued):
            cw = [w for w in s['cols'] if w['min'] <= j <= w['max']]
            if not cw or not cw[0]['custom']:
                out['X10'].append("'%s' column %s has no fitted width" % (nm, col_letters(j)))
                continue
            w = cw[0]['width']
            if w > MAX_WIDTH:
                out['X10'].append("'%s' column %s width %.2f over 150" % (nm, col_letters(j), w))
            if j in widest and w + 1e-9 < widest[j]:
                out['X10'].append("'%s' column %s width %.2f under its widest number (%.1f)" % (nm, col_letters(j), w, widest[j]))
    for n in book.filter_names:
        out['X5'].append('defined name %s' % n)
    return out


def rules(paths):
    bad = 0
    for p in paths:
        try:
            res = check(Book(p))
        except Exception as e:   # a file the check cannot read fails every rule
            print('FAIL X0 %s: unreadable (%s)' % (p, e))
            bad += 1
            continue
        failed = []
        for r in RULES:
            probs = res[r]
            if probs:
                failed.append(r)
                print('FAIL %s %s: %d - %s' % (r, p, len(probs), '; '.join(probs[:3])))
            else:
                print('PASS %s %s' % (r, p))
        print('%s: %s' % (p, 'FAIL ' + ','.join(failed) if failed else 'PASS'))
        bad += bool(failed)
    return 1 if bad else 0


def profile(book):
    """the properties 'same' compares"""
    grids = [s for s in book.sheets if s['grid']]
    p = {'sheets': '%d: %s' % (len(book.sheets), ' | '.join(s['name'] for s in book.sheets)),
         'opens on': book.sheets[0]['name'] if book.sheets else '-'}
    heads, pairs, cols = set(), {}, {}
    for s in grids:
        for c in s['cells']:
            x, f = c['xf'], c['xf']['font']
            if c['row'] == 1:
                heads.add('fill %s text %s bold %s size %s align %s' % (x['fill'], f.get('colour'), f.get('bold'), f.get('size'), x['halign'] or 'general'))   # no alignment draws as general
                continue
            key = '%s/%s' % (x['fill'], f.get('colour'))
            if x['fill'] or f.get('colour') not in PLAIN_TEXT:   # a plain cell is no pair
                pairs[key] = pairs.get(key, 0) + 1
        hdr = {c['col']: str(c['v'] or '').strip() for c in s['cells'] if c['row'] == 1}
        for c in s['cells']:
            if c['row'] == 1 or c['v'] is None or c['col'] not in hdr:
                continue
            k = hdr[c['col']].lower()
            d = cols.setdefault(k, {'types': set(), 'formats': set(), 'width': None, 'widest': ''})
            d['types'].add({'s': 'text', 'inlineStr': 'text', 'str': 'text', 'b': 'boolean', 'n': 'number'}.get(c['t'], c['t']))
            d['formats'].add(c['xf']['fmt'] or 'General')
            if len(str(c['v'])) > len(d['widest']):
                d['widest'] = str(c['v'])
        for k_col, k in ((j, hdr[j].lower()) for j in hdr):
            w = [x for x in s['cols'] if x['min'] <= k_col <= x['max']]
            if k in cols and w:
                cols[k]['width'] = w[0]['width']
    p['header style'] = ' ; '.join(sorted(heads)) or 'none'
    p['status pairs'] = ', '.join('%s x%d' % kv for kv in sorted(pairs.items())) or 'none'
    p['tables'] = ' ; '.join('%s style %s autofilter %s' % (t.get('ref'), t.get('style'), 'on' if t.get('autofilter') else 'off')
                             for s in grids for t in s['tables']) or 'none'
    p['sheet autofilter'] = ', '.join(s['autofilter'] for s in grids if s['autofilter']) or 'none'
    p['frozen panes'] = ', '.join(s['name'] for s in book.sheets if s['pane']) or 'none'
    p['hyperlinks'] = str(sum(len(s['hyperlinks']) for s in book.sheets))
    p['drawings / charts / pictures'] = str(sum(1 for x in book.parts if x.startswith(('xl/drawings/', 'xl/charts/', 'xl/media/'))))
    return p, cols


def same(ref_path, file_path):
    a, acols = profile(Book(ref_path))
    b, bcols = profile(Book(file_path))
    for k in a:
        print(('SAME %s: %s' % (k, a[k])) if a[k] == b[k] else ('DIFF %s: %s | %s' % (k, a[k], b[k])))
    for k in sorted(set(acols) | set(bcols)):
        if k not in acols or k not in bcols:
            print("DIFF column '%s': %s" % (k, 'reference only' if k in acols else 'file only'))
            continue
        x, y = acols[k], bcols[k]
        for prop in ('types', 'formats'):
            sx, sy = ', '.join(sorted(x[prop])), ', '.join(sorted(y[prop]))
            print(("SAME column '%s' %s: %s" % (k, prop, sx)) if sx == sy else ("DIFF column '%s' %s: %s | %s" % (k, prop, sx, sy)))
        if x['width'] is not None and y['width'] is not None:
            tol = 1.0 if x['widest'] == y['widest'] else 0.15 * x['width']
            ok = abs(x['width'] - y['width']) <= tol
            print(("SAME column '%s' width: %.2f / %.2f" % (k, x['width'], y['width'])) if ok
                  else ("DIFF column '%s' width: %.2f | %.2f" % (k, x['width'], y['width'])))
    return 0


def main():
    if len(sys.argv) >= 3 and sys.argv[1] == 'rules':
        return rules(sys.argv[2:])
    if len(sys.argv) == 4 and sys.argv[1] == 'same':
        return same(sys.argv[2], sys.argv[3])
    print(__doc__.split('\n\n')[0], file=sys.stderr)
    return 2


if __name__ == '__main__':
    sys.exit(main())
