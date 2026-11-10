// The statement viewer both engines' pages share: a grid cell shows a statement's first characters on one line and
// opens the whole text in a dialog (DBA Dash's code viewer). The dialog is the native dialog element opened modal:
// the browser keeps the focus inside it, Escape closes it and the focus goes back to the cell that opened it. A
// Copy button puts the whole text on the clipboard. The same dialog shows a page's 'what is this' notes.
import { el } from './ui';

// firstChars: a text on one line (every run of white space one blank), cut at n characters.
export function firstChars(v: unknown, n = 80): string {
  const s = v == null ? '' : String(v).replace(/\s+/g, ' ').trim();
  return s.length > n ? s.slice(0, n) + '...' : s;
}

let seq = 0;

async function copyText(text: string, from: HTMLElement): Promise<boolean> {
  try {
    if (navigator.clipboard) { await navigator.clipboard.writeText(text); return true; }
  } catch { /* no permission, or a page not served over https: the selection route below */ }
  try {
    const sel = getSelection();
    if (!sel) return false;
    const range = document.createRange();
    range.selectNodeContents(from);
    sel.removeAllRanges(); sel.addRange(range);
    return document.execCommand('copy');
  } catch { return false; }
}

// openViewer shows a whole text: monospace and wrapped for a statement (code), the page's own font for a note.
export function openViewer(heading: string, text: string, code = true): void {
  document.querySelector('dialog.sqlview')?.remove();   // one viewer at a time
  const back = document.activeElement instanceof HTMLElement ? document.activeElement : null;   // the focus goes back there on close
  const id = 'sqlview-h' + (++seq);
  const pre = el('pre', { class: 'sql', tabindex: '0', role: 'region', 'aria-labelledby': id,
    style: 'white-space:pre-wrap;word-break:break-word;overflow:auto;max-height:65vh;margin:.6rem 0;padding:.6rem;'
      + (code ? '' : 'font-family:inherit;font-size:inherit;') }, text);
  const copy = el('button', { type: 'button', class: 'sqlview-copy' }, 'Copy');
  const close = el('button', { type: 'button', class: 'sqlview-close' }, 'Close');
  const said = el('span', { class: 'meta', role: 'status', 'aria-live': 'polite' });
  const dlg = el('dialog', { class: 'sqlview', 'aria-labelledby': id,
    style: 'width:min(64rem,92vw);max-height:90vh;background:var(--card);color:var(--fg);border:1px solid var(--line);padding:0' },
    // the padding is the inner box's: a click in it is inside the content, never taken for the backdrop below
    el('div', { style: 'padding:1rem' }, el('h3', { id, style: 'margin:0' }, heading), pre, el('div', {}, copy, ' ', close, ' ', said)));
  copy.addEventListener('click', () => {
    void copyText(text, pre).then(ok => { said.textContent = ok ? `Copied (${text.length.toLocaleString()} characters).` : 'Not copied: select the text and copy it.'; });
  });
  close.addEventListener('click', () => dlg.close());
  // a click on the backdrop (the dialog element itself, outside its content box) closes it
  dlg.addEventListener('click', ev => { if (ev.target === dlg) dlg.close(); });
  dlg.addEventListener('close', () => { dlg.remove(); if (back?.isConnected) back.focus(); });
  document.body.append(dlg);
  dlg.showModal();
  copy.focus();
}

// sqlCell is a grid's statement cell: the first n characters on one line; a click (or Enter) opens the whole text.
// It is the ONLY content of its cell: the export writes the cell as its data-full (export.ts text()).
// title says what the text is where that is not plain (the last statement of an idle session).
export function sqlCell(v: unknown, o: { heading?: string; title?: string; n?: number } = {}): HTMLElement | string {
  if (v == null || v === '') return '';
  const text = String(v);
  // data-full: the export writes the whole statement, not the 80 characters on screen
  const b = el('button', { type: 'button', class: 'link sqlcell', 'data-full': text, title: o.title ?? 'Show the whole statement',
    style: 'font-family:ui-monospace,monospace;font-size:12px;text-align:left;white-space:nowrap' }, firstChars(text, o.n ?? 80));
  b.addEventListener('click', ev => { ev.stopPropagation(); openViewer(o.heading ?? 'Statement', text); });
  return b;
}

// whatIsThis is the small link a removed paragraph became: the sentence is its title, and a click shows it.
export function whatIsThis(text: string, heading = 'What is this'): HTMLElement {
  const b = el('button', { type: 'button', class: 'link whatis', title: text, 'aria-label': 'what is this: ' + heading, style: 'font-size:12px;font-weight:400' }, 'what is this');
  b.addEventListener('click', () => openViewer(heading, text, false));
  return b;
}
