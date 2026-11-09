// The global time range, top right: presets that follow now, or a custom from / to (history).
import { Ctx, href, presets, rangeLabel } from './router';
import { el } from './ui';

function toLocalInput(iso: string): string {
  const d = new Date(iso);
  return new Date(d.getTime() - d.getTimezoneOffset() * 60000).toISOString().slice(0, 16);
}

export function rangePicker(ctx: Ctx): HTMLElement {
  const sel = el('select', { 'aria-label': 'time range', title: 'Time range for every tab' },
    ...Object.keys(presets).map(p => { const o = el('option', { value: p }, 'Last ' + p); if (p === ctx.range.preset) o.selected = true; return o; }),
    (() => { const o = el('option', { value: 'custom' }, 'Custom...'); if (!ctx.range.preset) o.selected = true; return o; })());
  const now = new Date().toISOString();
  const from = el('input', { type: 'datetime-local', 'aria-label': 'from' });
  const to = el('input', { type: 'datetime-local', 'aria-label': 'to' });
  from.value = toLocalInput(ctx.range.from ?? new Date(Date.now() - 3600e3).toISOString());
  to.value = toLocalInput(ctx.range.to ?? now);
  const apply = el('button', { type: 'button' }, 'Apply');
  const err = el('span', { class: 'error' });
  const custom = el('span', { class: 'custom' }, from, ' to ', to, ' ', apply, err);
  custom.hidden = !!ctx.range.preset;
  sel.addEventListener('change', () => {
    if (sel.value === 'custom') { custom.hidden = false; return; }
    location.hash = href(ctx, { tab: ctx.tab, range: { preset: sel.value }, at: undefined });
  });
  apply.addEventListener('click', () => {
    const f = new Date(from.value), t = new Date(to.value);
    if (isNaN(f.getTime()) || isNaN(t.getTime()) || f >= t) { err.textContent = ' from must be before to'; return; }
    if (t.getTime() - f.getTime() > 31 * 86400e3) { err.textContent = ' 31 days at most'; return; }
    location.hash = href(ctx, { tab: ctx.tab, range: { from: f.toISOString(), to: t.toISOString() }, at: undefined });
  });
  return el('div', { class: 'range', title: rangeLabel(ctx) }, sel, custom);
}
