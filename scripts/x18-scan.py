#!/usr/bin/env python3
"""A status column's other cells, on the screen's side of xlsx-check's X18. A status column is a grid column (a Col
literal `{ key: '...', ... }` in web/src) that draws a warning or critical badge on some rows - in its own text or
through a helper of its file that does. Its other value-holding cells must carry a status too: OK where the column's
check judged the row and found nothing, N/A where it did not judge it. Two ways pass:
  - the column's cls (a 'status ok' / 'status none' class on the cell), or
  - the column is on the REVIEWED list below (read one by one: its other cells are empty, or each is a badge whose
    class is a status), and every badge it draws - in its text and in its helpers - has a status class: never ''
    and never 'info' (a badge with no status class is a plain cell beside coloured ones).
A status column that does neither is a FAIL; a REVIEWED entry that matches no status column is a FAIL too (the list
follows the source).

usage: x18-scan.py <the web/src folder>   prints one line per FAIL, then the counts; exit 1 on any FAIL
"""
import glob
import re
import sys

# (file, key): why the column passes without a cls. 'empty' = its other cells hold no value; 'badges' = every other
# value is a badge of class ok or none (OK / N/A).
REVIEWED = {
}


def close_of(text, i, opener):
    """index just past the bracket closing text[i] (opener '{' or '('), skipping strings, template parts, comments"""
    pair = {'{': '}', '(': ')'}
    stack = [opener]
    j = i + 1
    while j < len(text) and stack:
        c = text[j]
        top = stack[-1]
        if top in ("'", '"'):
            if c == '\\':
                j += 2
                continue
            if c == top:
                stack.pop()
        elif top == '`':
            if c == '\\':
                j += 2
                continue
            if c == '`':
                stack.pop()
            elif c == '$' and text[j + 1:j + 2] == '{':
                stack.append('{')
                j += 2
                continue
        else:
            if c in "'\"`":
                stack.append(c)
            elif c in '{(':
                stack.append(c)
            elif c in '})':
                if pair.get(top) == c:
                    stack.pop()
            elif c == '/' and text[j + 1:j + 2] == '/':
                k = text.find('\n', j)
                j = len(text) if k < 0 else k
                continue
        j += 1
    return j


def top_args(call):
    """the top-level arguments of 'name(a, b, ...)' (string-aware)"""
    i = call.index('(')
    inner = call[i + 1:close_of(call, i, '(') - 1]
    args, depth, q, start, k = [], 0, None, 0, 0
    while k < len(inner):
        c = inner[k]
        if q:
            if c == '\\':
                k += 2
                continue
            if c == q:
                q = None
        elif c in "'\"`":
            q = c
        elif c in '({[':
            depth += 1
        elif c in ')}]':
            depth -= 1
        elif c == ',' and depth == 0:
            args.append(inner[start:k])
            start = k + 1
        k += 1
    args.append(inner[start:])
    return [a.strip() for a in args]


def badges(text):
    """the class argument of every badge(...) call in text"""
    out = []
    for m in re.finditer(r'\bbadge\(', text):
        end = close_of(text, m.end() - 1, '(')
        a = top_args(text[m.start():end])
        out.append(a[1] if len(a) > 1 else '')
    return out


STATUS = re.compile(r"'(warn|crit)'")


def expr_end(text, k):
    """index just past an arrow function's expression body starting at text[k]: its first top-level ';', or a line
    break at depth 0 whose next line does not go on with an operator (? : + . && ||)"""
    stack, j = [], k
    while j < len(text):
        c = text[j]
        if stack and stack[-1] in ("'", '"', '`'):
            if c == '\\':
                j += 2
                continue
            if c == stack[-1]:
                stack.pop()
            elif stack[-1] == '`' and c == '$' and text[j + 1:j + 2] == '{':
                stack.append('{')
                j += 2
                continue
        elif c in "'\"`":
            stack.append(c)
        elif c in '({[':
            stack.append(c)
        elif c in ')}]':
            if not stack:
                return j
            stack.pop()
        elif not stack and c in ';,':
            return j
        elif not stack and c == '\n':
            nxt = text[j + 1:].lstrip(' ')
            if not re.match(r'(\?|:|\+|\.|&&|\|\|)', nxt):
                return j
        j += 1
    return j


def helpers(text):
    """name -> body of each function-shaped helper in the file (an arrow or a function declaration, a name of three
    letters or more) that draws a warning or critical badge"""
    found = {}
    for m in re.finditer(r"(?m)^[ \t]*(?:export\s+)?(?:const\s+(\w{3,})\s*=\s*(?:\([^)]*\)|\w+)\s*(?::\s*[\w |]+)?\s*=>\s*|function\s+(\w{3,})\s*\()", text):
        name = m.group(1) or m.group(2)
        k = m.end()
        if m.group(2):   # a function declaration: its braces
            b = text.index('{', k)
            body = text[k:close_of(text, b, '{')]
        elif text[k:k + 1] == '{':
            body = text[k:close_of(text, k, '{')]
        else:
            body = text[k:expr_end(text, k)]
        if 'badge(' in body and STATUS.search(body):
            found[name] = body
    return found


def main():
    if len(sys.argv) != 2:
        print(__doc__)
        return 2
    src = sys.argv[1].rstrip('/')
    bad, n, seen = 0, 0, set()
    for path in sorted(glob.glob(f'{src}/*.ts')):
        name = path.split('/')[-1]
        if '.test.' in name:
            continue
        text = open(path, encoding='utf-8').read()
        hs = helpers(text)
        for m in re.finditer(r"\{ key: '([^']+)'", text):
            body = text[m.start():close_of(text, m.start(), '{')]
            key = m.group(1)
            used = [h for h in hs if re.search(r'fmt:\s*(?:(?:\([^)]*\)|\w+)\s*=>\s*)?' + h + r'\b', body)]
            if not (('badge(' in body and STATUS.search(body)) or used):
                continue
            n += 1
            line = text.count('\n', 0, m.start()) + 1
            if 'cls:' in body:
                continue
            why = REVIEWED.get((name, key))
            if why is None:
                print(f"FAIL {name}:{line} '{key}': a status column without a cls, not reviewed")
                bad += 1
                continue
            seen.add((name, key))
            plain = [c for c in badges(body + ''.join(hs[h] for h in used)) if c in ("''", "'info'") or re.search(r"[?:]\s*''|[?:]\s*'info'", c)]
            if plain:
                print(f"FAIL {name}:{line} '{key}' ({why}): a badge with no status class ({', '.join(plain)})")
                bad += 1
    for k in sorted(set(REVIEWED) - seen):
        print(f"FAIL REVIEWED {k[0]} '{k[1]}': no status column of that key without a cls (the list follows the source)")
        bad += 1
    print(f'{n - bad} of {n} status columns ok' if bad <= n else f'{bad} FAIL')
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main())
