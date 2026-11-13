#!/usr/bin/env python3
"""xlsx-check.test.py - the file rules of scripts/xlsx-check.py on built workbooks (no package, no network).

  python3 -I scripts/xlsx-check.test.py [path/to/xlsx-check.py]

A built workbook (two grid sheets, each one Excel table, and a last 'About') passes every rule. Each probe changes one
thing in a copy and names the rule that must FAIL, or must still PASS. One 'ok' or 'FAIL' line per probe; exit 1 on any
FAIL. The probes are the shapes a writer can get wrong in a way Excel draws or repairs: colours given by theme or index,
patterns and gradients, a column's or a row's own style, a style index past its list, table names and ids, a merge in a
table, dates and booleans stored as text, a time in a sheet name.
"""
import importlib.util
import os
import subprocess
import sys
import tempfile
import zipfile
from xml.sax.saxutils import escape

HERE = os.path.dirname(os.path.abspath(__file__))
CHECK = os.path.abspath(sys.argv[1]) if len(sys.argv) > 1 else os.path.join(HERE, 'xlsx-check.py')
sys.dont_write_bytecode = True   # no __pycache__ beside the check
spec = importlib.util.spec_from_file_location('xlsx_check', CHECK)
xc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(xc)

M = 'http://schemas.openxmlformats.org/spreadsheetml/2006/main'
R = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships'
PR = 'http://schemas.openxmlformats.org/package/2006/relationships'
SHEETS = [('Grid', ['name', 'size (GB)'], [['erp', 1.5], ['erp_audit', 0.25]]),
          ('Other', ['item', 'count'], [['sessions', 12], ['locks', 3]])]
ABOUT = [['Item', 'Value'], ['Exported', '2026-11-13 21:18'], ['Grid', '2 rows']]


def cell(ref, v, s=None):
    st = '' if s is None else ' s="%d"' % s
    if isinstance(v, bool):
        return '<c r="%s" t="b"%s><v>%d</v></c>' % (ref, st, v)
    if isinstance(v, (int, float)):
        return '<c r="%s"%s><v>%s</v></c>' % (ref, st, repr(v))
    return '<c r="%s" t="inlineStr"%s><is><t>%s</t></is></c>' % (ref, st, escape(str(v)))


def sheet_xml(head, rows, table):
    cols = ''.join('<col min="%d" max="%d" width="16.71" customWidth="1"/>' % (j, j) for j in range(1, len(head) + 1))
    data = '<row r="1">%s</row>' % ''.join(cell('%s1' % xc.col_letters(j + 1), h, 1) for j, h in enumerate(head))
    for i, r in enumerate(rows, start=2):
        data += '<row r="%d">%s</row>' % (i, ''.join(cell('%s%d' % (xc.col_letters(j + 1), i), v) for j, v in enumerate(r)))
    parts = '<tableParts count="1"><tablePart r:id="rId1"/></tableParts>' if table else ''
    return ('<worksheet xmlns="%s" xmlns:r="%s"><sheetViews><sheetView workbookViewId="0"/></sheetViews><cols>%s</cols>'
            '<sheetData>%s</sheetData><!--MERGE-->%s</worksheet>' % (M, R, cols, data, parts))


def table_xml(n, head, rows):
    ref = 'A1:%s%d' % (xc.col_letters(len(head)), max(len(rows) + 1, 2))
    tcs = ''.join('<tableColumn id="%d" name="%s"/>' % (j + 1, escape(h)) for j, h in enumerate(head))
    return ('<table xmlns="%s" id="%d" name="Table%d" displayName="Table%d" ref="%s"><autoFilter ref="%s"/>'
            '<tableColumns count="%d">%s</tableColumns></table>' % (M, n, n, n, ref, ref, len(head), tcs))


STYLES = ('<styleSheet xmlns="%s"><numFmts count="2"><numFmt numFmtId="164" formatCode="yyyy-MM-dd HH:mm"/>'
          '<numFmt numFmtId="165" formatCode="yyyy-MM-dd"/></numFmts>'
          '<fonts count="2"><font><sz val="11"/><name val="Calibri"/></font>'
          '<font><b/><sz val="11"/><color rgb="FFFFFFFF"/><name val="Calibri"/></font><!--FONTS--></fonts>'
          '<fills count="3"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill>'
          '<fill><patternFill patternType="solid"><fgColor rgb="FF0063A3"/></patternFill></fill><!--FILLS--></fills>'
          '<borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>'
          '<cellXfs count="3"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/>'
          '<xf numFmtId="0" fontId="1" fillId="2" borderId="0" applyFont="1" applyFill="1"/>'
          '<xf numFmtId="164" fontId="0" fillId="0" borderId="0" applyNumberFormat="1"/><!--XFS--></cellXfs></styleSheet>' % M)


def base(sheets=SHEETS, about=True):
    parts = {'[Content_Types].xml': '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"/>',
             '_rels/.rels': '<Relationships xmlns="%s"><Relationship Id="rId1" Type="%s/officeDocument" Target="xl/workbook.xml"/>'
                            '</Relationships>' % (PR, R),
             'xl/styles.xml': STYLES}
    names = [s[0] for s in sheets] + (['About'] if about else [])
    wsheets = ''.join('<sheet name="%s" sheetId="%d" r:id="rId%d"/>' % (escape(n), i + 1, i + 1) for i, n in enumerate(names))
    parts['xl/workbook.xml'] = ('<workbook xmlns="%s" xmlns:r="%s"><bookViews><workbookView activeTab="0"/></bookViews>'
                                '<sheets>%s</sheets></workbook>' % (M, R, wsheets))
    rel = ''.join('<Relationship Id="rId%d" Type="%s/worksheet" Target="worksheets/sheet%d.xml"/>' % (i + 1, R, i + 1)
                  for i in range(len(names)))
    parts['xl/_rels/workbook.xml.rels'] = '<Relationships xmlns="%s">%s</Relationships>' % (PR, rel)
    for i, (name, head, rows) in enumerate(sheets, start=1):
        parts['xl/worksheets/sheet%d.xml' % i] = sheet_xml(head, rows, True)
        parts['xl/worksheets/_rels/sheet%d.xml.rels' % i] = ('<Relationships xmlns="%s"><Relationship Id="rId1" Type="%s/table" '
                                                             'Target="../tables/table%d.xml"/></Relationships>' % (PR, R, i))
        parts['xl/tables/table%d.xml' % i] = table_xml(i, head, rows)
    if about:
        parts['xl/worksheets/sheet%d.xml' % len(names)] = sheet_xml(ABOUT[0], ABOUT[1:], False)
    return parts


def write(parts, path):
    with zipfile.ZipFile(path, 'w') as zf:
        for k, v in parts.items():
            zf.writestr(k, v)
    return path


def sub(parts, part, old, new):
    assert old in parts[part], 'probe text %r not in %s' % (old, part)
    parts[part] = parts[part].replace(old, new, 1)
    return parts


def add_style(parts, fill=None, font=None, xf_attrs=''):
    """a new cellXfs entry (index 3, 4, ...) with an optional new fill and font; returns its index"""
    st = parts['xl/styles.xml']
    fid = fl = 0
    if font is not None:
        fid = st.count('<font>') + st.count('<font ')
        st = st.replace('<!--FONTS-->', font + '<!--FONTS-->')
    if fill is not None:
        fl = st.count('<fill>') + st.count('<fill ')
        st = st.replace('<!--FILLS-->', fill + '<!--FILLS-->')
    n = st.count('<xf ')
    attrs = xf_attrs or 'numFmtId="0" fontId="%d" fillId="%d" borderId="0"' % (fid, fl)
    parts['xl/styles.xml'] = st.replace('<!--XFS-->', '<xf %s/><!--XFS-->' % attrs)
    return n


def set_b2(parts, v, s=None):
    old = cell('B2', SHEETS[0][2][0][1])
    return sub(parts, 'xl/worksheets/sheet1.xml', old, cell('B2', v, s))


def styled_b2(fill=None, font=None, xf_attrs=''):
    p = base()
    s = add_style(p, fill, font, xf_attrs)
    return set_b2(p, 1.5, s)


def rename(parts, i, name):
    return sub(parts, 'xl/workbook.xml', '<sheet name="%s"' % SHEETS[i][0], '<sheet name="%s"' % escape(name))


def red_fill(): return '<fill><patternFill patternType="solid"><fgColor rgb="FFFF0000"/></patternFill></fill>'


def date_fmt_cell(fmt_id):
    p = base()
    s = add_style(p, xf_attrs='numFmtId="%d" fontId="0" fillId="0" borderId="0" applyNumberFormat="1"' % fmt_id)
    return set_b2(p, 46339.5, s)


PROBES = [
    # (what, rule, 'FAIL' or 'PASS', build)
    ('the built workbook', 'ALL', 'PASS', base),
    # X8: a date-time stored as text, ISO and the page's locale forms; a date alone (a day column); not a version
    ('X8 ISO date-time as text', 'X8', 'FAIL', lambda: set_b2(base(), '2026-11-12 16:15')),
    ('X8 en-US date-time as text', 'X8', 'FAIL', lambda: set_b2(base(), '10/3/2026, 21:05:00')),
    ('X8 fr-FR date-time as text', 'X8', 'FAIL', lambda: set_b2(base(), '13/11/2026 21:05:35')),
    ('X8 day-first date-time as text', 'X8', 'FAIL', lambda: set_b2(base(), '03/10/2026 21:05:00')),
    ('X8 ISO day as text', 'X8', 'FAIL', lambda: set_b2(base(), '2026-11-11')),
    ('X8 ISO date-time with seconds and a zone', 'X8', 'FAIL', lambda: set_b2(base(), '2026-11-12T16:15:00Z')),
    ('X8 a 12-hour date-time', 'X8', 'FAIL', lambda: set_b2(base(), '11/13/2026, 2:10:00 PM')),
    ('X8 a message that starts with a time', 'X8', 'PASS', lambda: set_b2(base(), '11/13/2026, 02:10:00 step 2 merge into orders: failed')),
    ('X8 a range of two times', 'X8', 'PASS', lambda: set_b2(base(), '11/12/2026, 16:15:13 to 11/12/2026, 17:15:13')),
    ('X8 a version string', 'X8', 'PASS', lambda: set_b2(base(), '16.0.4325.4')),
    ('X8 a duration in days', 'X8', 'PASS', lambda: set_b2(base(), '233.3 days')),
    # X9: a boolean stored as text
    ('X9 true as text', 'X9', 'FAIL', lambda: set_b2(base(), 'true')),
    ('X9 yes as text', 'X9', 'FAIL', lambda: set_b2(base(), 'yes')),
    ('X9 No as text', 'X9', 'FAIL', lambda: set_b2(base(), 'No')),
    ('X9 a setting value on', 'X9', 'PASS', lambda: set_b2(base(), 'on')),
    ('X9 a boolean cell', 'X9', 'PASS', lambda: set_b2(base(), True)),
    # X0: fills and text colours given another way than an RGB value
    ('X0 solid fill by theme', 'X0', 'FAIL', lambda: styled_b2(fill='<fill><patternFill patternType="solid"><fgColor theme="5"/></patternFill></fill>')),
    ('X0 solid fill by index', 'X0', 'FAIL', lambda: styled_b2(fill='<fill><patternFill patternType="solid"><fgColor indexed="10"/></patternFill></fill>')),
    ('X0 a pattern fill', 'X0', 'FAIL', lambda: styled_b2(fill='<fill><patternFill patternType="darkGray"><fgColor rgb="FFFF0000"/></patternFill></fill>')),
    ('X0 a gradient fill', 'X0', 'FAIL', lambda: styled_b2(fill='<fill><gradientFill degree="90"><stop position="0"><color rgb="FFFF0000"/></stop>'
                                                                 '<stop position="1"><color rgb="FF0000FF"/></stop></gradientFill></fill>')),
    ('X0 the gray125 fill', 'X0', 'FAIL', lambda: styled_b2(xf_attrs='numFmtId="0" fontId="0" fillId="1" borderId="0"')),
    ('X0 text colour by theme 5', 'X0', 'FAIL', lambda: styled_b2(font='<font><sz val="11"/><color theme="5"/><name val="Calibri"/></font>')),
    ('X0 text colour by index 10', 'X0', 'FAIL', lambda: styled_b2(font='<font><sz val="11"/><color indexed="10"/><name val="Calibri"/></font>')),
    ('X0 text colour theme 1 (Text 1)', 'X0', 'PASS', lambda: styled_b2(font='<font><sz val="11"/><color theme="1"/><name val="Calibri"/></font>')),
    ('X0 text colour index 8 (black)', 'X0', 'PASS', lambda: styled_b2(font='<font><sz val="11"/><color indexed="8"/><name val="Calibri"/></font>')),
    ('X0 text colour index 64 (system)', 'X0', 'PASS', lambda: styled_b2(font='<font><sz val="11"/><color indexed="64"/><name val="Calibri"/></font>')),
    ('X0 text colour automatic', 'X0', 'PASS', lambda: styled_b2(font='<font><sz val="11"/><color auto="1"/><name val="Calibri"/></font>')),
    ('X0 a pattern fill none', 'X0', 'PASS', lambda: styled_b2(fill='<fill><patternFill patternType="none"/></fill>')),
    # X0: a style index past its list
    ('X0 a cell style past cellXfs', 'X0', 'FAIL', lambda: set_b2(base(), 1.5, 99)),
    ('X0 a font index past fonts', 'X0', 'FAIL', lambda: styled_b2(xf_attrs='numFmtId="0" fontId="77" fillId="0" borderId="0"')),
    ('X0 a fill index past fills', 'X0', 'FAIL', lambda: styled_b2(xf_attrs='numFmtId="0" fontId="0" fillId="77" borderId="0"')),
    # X0: a column's or a row's own style draws on its empty cells
    ('X0 a column style with a fill', 'X0', 'FAIL',
     lambda: (lambda p, s: sub(p, 'xl/worksheets/sheet1.xml', '<col min="2" max="2" width="16.71" customWidth="1"/>',
                               '<col min="2" max="2" width="16.71" customWidth="1" style="%d"/>' % s))(*(lambda p: (p, add_style(p, red_fill())))(base()))),
    ('X0 a column style plain', 'X0', 'PASS',
     lambda: sub(base(), 'xl/worksheets/sheet1.xml', '<col min="2" max="2" width="16.71" customWidth="1"/>',
                 '<col min="2" max="2" width="16.71" customWidth="1" style="0"/>')),
    ('X0 a row style with a fill', 'X0', 'FAIL',
     lambda: (lambda p, s: sub(p, 'xl/worksheets/sheet1.xml', '<row r="2">', '<row r="2" s="%d" customFormat="1">' % s))(*(lambda p: (p, add_style(p, red_fill())))(base()))),
    ('X0 a row style without customFormat', 'X0', 'PASS',
     lambda: (lambda p, s: sub(p, 'xl/worksheets/sheet1.xml', '<row r="2">', '<row r="2" s="%d">' % s))(*(lambda p: (p, add_style(p, red_fill())))(base()))),
    # X4: the header's font
    ('X4 header font Arial', 'X4', 'FAIL', lambda: sub(base(), 'xl/styles.xml', '<color rgb="FFFFFFFF"/><name val="Calibri"/>', '<color rgb="FFFFFFFF"/><name val="Arial"/>')),
    # X5: what Excel repairs in a table
    ('X5 two tables with id 1', 'X5', 'FAIL', lambda: sub(base(), 'xl/tables/table2.xml', 'id="2" name="Table2"', 'id="1" name="Table2"')),
    ('X5 two tables named Table1', 'X5', 'FAIL', lambda: sub(base(), 'xl/tables/table2.xml', 'name="Table2" displayName="Table2"', 'name="Table1" displayName="Table1"')),
    ('X5 table names equal ignoring case', 'X5', 'FAIL', lambda: sub(base(), 'xl/tables/table2.xml', 'name="Table2" displayName="Table2"', 'name="TABLE1" displayName="TABLE1"')),
    ('X5 a table named like a cell', 'X5', 'FAIL', lambda: sub(base(), 'xl/tables/table2.xml', 'name="Table2" displayName="Table2"', 'name="A1" displayName="A1"')),
    ('X5 a table name with a space', 'X5', 'FAIL', lambda: sub(base(), 'xl/tables/table2.xml', 'name="Table2" displayName="Table2"', 'name="Table 2" displayName="Table 2"')),
    ('X5 two table columns with id 1', 'X5', 'FAIL', lambda: sub(base(), 'xl/tables/table1.xml', '<tableColumn id="2"', '<tableColumn id="1"')),
    ('X5 a merged range in a table', 'X5', 'FAIL', lambda: sub(base(), 'xl/worksheets/sheet1.xml', '<!--MERGE-->', '<mergeCells count="1"><mergeCell ref="A2:B3"/></mergeCells>')),
    # X2: a time in a sheet name, not an address
    ('X2 a compact stamp in a name', 'X2', 'FAIL', lambda: rename(base(), 0, 'Findings 20261112-1615')),
    ('X2 a clock in a name', 'X2', 'FAIL', lambda: rename(base(), 0, 'Sessions 16 15 00')),
    ('X2 a day and a clock in a name', 'X2', 'FAIL', lambda: rename(base(), 0, 'Backups 2026-11-12 16 15')),
    ('X2 a locale day and a clock in a name', 'X2', 'FAIL', lambda: rename(base(), 0, 'Jobs 11 13 2026, 05 25 00')),
    ('X2 a day alone in a name (a job of its own words)', 'X2', 'PASS', lambda: rename(base(), 0, 'Purge 2026-01-01')),
    ('X2 a numbered repeat', 'X2', 'FAIL', lambda: rename(base(), 1, 'Grid (2)')),
    ('X2 a host address in a name', 'X2', 'PASS', lambda: rename(base(), 0, 'Host 10.1.2.30')),
    ('X2 a version in a name', 'X2', 'PASS', lambda: rename(base(), 0, 'Release 1.2.3 notes')),
    # X7: the formats a date may take
    ('X7 a date-time cell yyyy-MM-dd HH:mm', 'X7', 'PASS', lambda: date_fmt_cell(164)),
    ('X7 a day cell yyyy-MM-dd', 'X7', 'PASS', lambda: date_fmt_cell(165)),
    ('X7 a built-in date format', 'X7', 'FAIL', lambda: date_fmt_cell(14)),
]


def verdicts(path):
    return {r: bool(p) for r, p in xc.check(xc.Book(path)).items()}


def run():
    bad = 0
    tmp = tempfile.mkdtemp(prefix='xlsx-check-test-')
    try:
        for i, (what, rule, want, build) in enumerate(PROBES):
            path = write(build(), os.path.join(tmp, 'p%02d.xlsx' % i))
            try:
                v = verdicts(path)
            except Exception as e:
                print('FAIL %s: the check raised %s: %s' % (what, type(e).__name__, e))
                bad += 1
                continue
            if rule == 'ALL':
                got = 'FAIL' if any(v.values()) else 'PASS'
                note = ','.join(r for r in v if v[r])
            else:
                got = 'FAIL' if v[rule] else 'PASS'
                note = ''
            if got == want:
                print('ok %s: %s %s' % (what, rule, want))
            else:
                print('FAIL %s: %s %s, expected %s %s' % (what, rule, got, want, note))
                bad += 1
        bad += unreadable(tmp)
        bad += same_pairs(tmp)
    finally:
        for f in os.listdir(tmp):
            os.remove(os.path.join(tmp, f))
        os.rmdir(tmp)
    print('xlsx-check.test: %d probes, %s' % (len(PROBES) + 3, 'every one ok' if not bad else '%d FAIL' % bad))
    return 1 if bad else 0


def unreadable(tmp):
    """a file the check cannot read fails every rule, with its summary line; 'same' says so in one line"""
    bad = 0
    p = os.path.join(tmp, 'not-a-zip.xlsx')
    with open(p, 'w') as f:
        f.write('not a workbook')
    r = subprocess.run([sys.executable, '-I', CHECK, 'rules', p], capture_output=True, text=True)
    fails = [ln for ln in r.stdout.splitlines() if ln.startswith('FAIL X')]
    summary = '%s: FAIL %s' % (p, ','.join(xc.RULES))
    if r.returncode == 1 and len(fails) == len(xc.RULES) and summary in r.stdout.splitlines() and 'Traceback' not in r.stderr:
        print('ok an unreadable file: FAIL on every rule and its summary line')
    else:
        print('FAIL an unreadable file: rc %d, %d FAIL lines, summary %s' % (r.returncode, len(fails), summary in r.stdout))
        bad += 1
    good = write(base(), os.path.join(tmp, 'good.xlsx'))
    r = subprocess.run([sys.executable, '-I', CHECK, 'same', p, good], capture_output=True, text=True)
    if r.returncode == 2 and 'Traceback' not in r.stderr and 'unreadable' in (r.stdout + r.stderr).lower():
        print("ok 'same' on an unreadable file: one line, exit 2")
    else:
        print("FAIL 'same' on an unreadable file: rc %d, traceback %s" % (r.returncode, 'Traceback' in r.stderr))
        bad += 1
    return bad


def same_pairs(tmp):
    """'same' pairs the sheets first, then the columns by header with the units spelled alike, and counts the match"""
    ref = write(base([('DB Space', ['name', 'total wait (ms/sec)', 'max duration (sec)'], [['erp', 1.5, 2]]),
                      ('DB Space (allocated)', ['name', 'allocated'], [['erp', 3]])], about=False), os.path.join(tmp, 'ref.xlsx'))
    mine = write(base([('DB Space', ['name', 'total wait (ms/s)', 'max duration (s)'], [['erp', 1.5, 2]]),
                       ('DB Space (allocated)', ['name', 'allocated (GB)'], [['erp', 3]])]), os.path.join(tmp, 'mine.xlsx'))
    r = subprocess.run([sys.executable, '-I', CHECK, 'same', ref, mine], capture_output=True, text=True)
    out = r.stdout
    want = ["PAIR 'DB Space' = 'DB Space'", "PAIR 'DB Space (allocated)' = 'DB Space (allocated)'",
            "SAME 'DB Space' column 'total wait (ms/s)' types: number", "MATCHED 'DB Space': 3 of 3 columns",
            "MATCHED 'DB Space (allocated)': 1 of 2 columns"]
    miss = [w for w in want if w not in out.splitlines()]
    if r.returncode == 0 and not miss:
        print("ok 'same' pairs sheets and columns (units spelled alike)")
        return 0
    print("FAIL 'same' pairs sheets and columns: rc %d, missing %s" % (r.returncode, miss))
    return 1


if __name__ == '__main__':
    sys.exit(run())
