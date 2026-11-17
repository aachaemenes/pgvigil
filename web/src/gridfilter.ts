// The grid's filter as one text (DBA Dash's Edit Filter, task PGRID B11): one line per column that has a filter,
// '[<the column's name, a ] in it doubled>] <its filter as the filter row holds it>', in the columns' order; read back
// the same way. The lines are ANDed, as the filter row's fields are. A line's text after the name IS that column's
// filter field - the conditions are never parsed here (ui.ts compileFilter reads the field) - so the text and the
// filter row never say two things. DOM-free; its unit rows: gridfilter.test.mjs.

export interface FilterCol { name: string; filter: string }

const bracket = (name: string) => '[' + name.replace(/]/g, ']]') + ']';

// filterText: the columns' filters as the dialog's text ('' = no filter set)
export function filterText(cols: FilterCol[]): string {
  return cols.filter(c => c.filter.trim() !== '').map(c => `${bracket(c.name)} ${c.filter.trim()}`).join('\n');
}

export type FilterRead = { ok: true; filters: string[] } | { ok: false; why: string };

// readFilterText: the text back as one filter per column (names: the grid's column names, in order; '' where no line
// names it, so an empty text clears every column), or the first line it cannot read, said in words that name the line
export function readFilterText(text: string, names: string[]): FilterRead {
  const filters = names.map(() => '');
  const onLine = new Map<number, number>();
  const lines = text.replace(/\r/g, '').split('\n');
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i].trim(), at = i + 1;
    if (line === '') continue;
    if (!line.startsWith('[')) return { ok: false, why: `Line ${at}: a line starts with its column's name in brackets, as ${bracket(names[0] ?? 'name')} >5.` };
    let name = '', k = 1, closed = false;
    for (; k < line.length; k++) {
      if (line[k] === ']') {
        if (line[k + 1] === ']') { name += ']'; k++; continue; }
        closed = true; k++;
        break;
      }
      name += line[k];
    }
    if (!closed) return { ok: false, why: `Line ${at}: the column's name has no closing ] (a ] inside a name is written twice).` };
    const j = names.indexOf(name);
    if (j < 0) return { ok: false, why: `Line ${at}: this grid has no column '${name}'.` };
    const cond = line.slice(k).trim();
    if (cond === '') return { ok: false, why: `Line ${at}: ${bracket(name)} has no condition after it.` };
    const was = onLine.get(j);
    if (was !== undefined) return { ok: false, why: `Line ${at}: the column '${name}' is on line ${was} too - one line per column, its conditions joined by ' & '.` };
    onLine.set(j, at);
    filters[j] = cond;
  }
  return { ok: true, filters };
}
