// A SQL Server deadlock drawn as a graph (task 120, in the shape of SSMS's and Darling's): each session a box with
// its login, its lock wait and the first line of its statement, the victim boxed in the critical colour and
// labelled VICTIM; each locked resource a box below with its kind, object and index; an edge from a resource to the
// session that holds it ('holds X') and from a waiting session to the resource it wants ('waits for U', dashed).
// The graph comes from the deadlock XML SQL Server wrote (graphFromXml) or, where the XML is not kept (a query-text
// policy other than full), from the processes and resources the collector took out of it (graphFromRows).
// Everything is set as text (textContent), never parsed as markup.
import { Row } from './api';

export interface DlRef { process: string; spid: number | null; mode: string | null }
export interface DlProcess {
  process: string; spid: number | null; victim: boolean; login: string | null; host: string | null; program: string | null;
  database: string | null; waits_on: string | null; waits_mode: string | null; wait_ms: number | null; wait_resource: string | null;
  trancount: number | null; log_used: number | null; isolation: string | null; statement: string | null; proc: string | null;
}
export interface DlResource { type: string; object: string | null; index: string | null; mode: string | null; owners: DlRef[]; waiters: DlRef[] }
export interface DlGraph { processes: DlProcess[]; resources: DlResource[] }

const str = (v: unknown): string | null => v == null || String(v).trim() === '' ? null : String(v);
const num = (v: unknown): number | null => v == null || v === '' || isNaN(Number(v)) ? null : Number(v);

// graphFromRows: the collector's processes and resources (mssql_deadlocks.processes / .resources).
export function graphFromRows(processes: unknown, resources: unknown): DlGraph | null {
  if (!Array.isArray(processes) || processes.length === 0) return null;
  // an owner or waiter names its process by id; one that carries only a session id is matched by it
  const bySpid = new Map((processes as Row[]).map(p => [num(p.spid), String(p.process ?? '')]));
  const refs = (v: unknown): DlRef[] => Array.isArray(v)
    ? v.map(x => { const r = x as Row, spid = num(r.spid); return { process: str(r.process) ?? bySpid.get(spid) ?? '', spid, mode: str(r.mode) }; }) : [];
  return {
    processes: (processes as Row[]).map(p => ({
      process: String(p.process ?? ''), spid: num(p.spid), victim: p.victim === true, login: str(p.login), host: str(p.host),
      program: str(p.program), database: str(p.database), waits_on: str(p.waits_on), waits_mode: str(p.waits_mode),
      wait_ms: num(p.wait_ms), wait_resource: str(p.wait_resource), trancount: num(p.trancount), log_used: num(p.log_used),
      isolation: str(p.isolation), statement: str(p.statement), proc: str(p.proc),
    })),
    resources: Array.isArray(resources) ? (resources as Row[]).map(r => ({
      type: String(r.type ?? ''), object: str(r.object), index: str(r.index), mode: str(r.mode), owners: refs(r.owners), waiters: refs(r.waiters),
    })) : [],
  };
}

// graphFromXml: the deadlock XML as SQL Server wrote it (<deadlock> with victim-list, process-list, resource-list).
// The same reading as the collector's (internal/mssql/xe_shred.go): the statement is the input buffer, else the first
// frame of the stack with text. null when the text is not a deadlock graph.
export function graphFromXml(xml: string): DlGraph | null {
  let doc: Document;
  try { doc = new DOMParser().parseFromString(xml, 'application/xml'); } catch { return null; }
  if (doc.getElementsByTagName('parsererror').length) return null;
  const root = doc.getElementsByTagName('deadlock')[0];
  if (!root) return null;
  const kids = (e: Element | undefined, name?: string) => e ? [...e.children].filter(c => !name || c.localName === name) : [];
  const first = (e: Element, name: string) => kids(e, name)[0];
  const victims = new Set(kids(first(root, 'victim-list'), 'victimProcess').map(v => v.getAttribute('id') ?? ''));
  const procEls = kids(first(root, 'process-list'), 'process');
  const spidOf = new Map(procEls.map(p => [p.getAttribute('id') ?? '', num(p.getAttribute('spid'))]));
  const ref = (e: Element): DlRef => { const id = e.getAttribute('id') ?? ''; return { process: id, spid: spidOf.get(id) ?? null, mode: str(e.getAttribute('mode')) }; };
  const resources: DlResource[] = kids(first(root, 'resource-list')).map(r => ({
    type: r.localName, object: str(r.getAttribute('objectname')), index: str(r.getAttribute('indexname')), mode: str(r.getAttribute('mode')),
    owners: kids(first(r, 'owner-list'), 'owner').map(ref), waiters: kids(first(r, 'waiter-list'), 'waiter').map(ref),
  }));
  const waits = new Map<string, { object: string | null; mode: string | null }>();
  for (const r of resources) for (const w of r.waiters) if (!waits.has(w.process)) waits.set(w.process, { object: r.object, mode: w.mode });
  const processes: DlProcess[] = procEls.map(p => {
    const a = (n: string) => str(p.getAttribute(n));
    const frames = kids(first(p, 'executionStack'), 'frame');
    const input = str(first(p, 'inputbuf')?.textContent?.trim());
    const frameText = frames.map(f => (f.textContent ?? '').trim()).find(t => t !== '' && t !== 'unknown') ?? null;
    const proc = frames.map(f => f.getAttribute('procname') ?? '').find(n => n !== '' && n !== 'adhoc' && n !== 'unknown') ?? null;
    const id = p.getAttribute('id') ?? '';
    return {
      process: id, spid: num(a('spid')), victim: victims.has(id), login: a('loginname'), host: a('hostname'), program: a('clientapp'),
      database: a('currentdbname'), waits_on: waits.get(id)?.object ?? null, waits_mode: waits.get(id)?.mode ?? null,
      wait_ms: num(a('waittime')), wait_resource: a('waitresource'), trancount: num(a('trancount')), log_used: num(a('logused')),
      isolation: a('isolationlevel'), statement: input ?? frameText, proc,
    };
  });
  return processes.length ? { processes, resources } : null;
}

// ---- drawing

const NS = 'http://www.w3.org/2000/svg';
function s<K extends keyof SVGElementTagNameMap>(tag: K, attrs: Record<string, string | number> = {}, text?: string): SVGElementTagNameMap[K] {
  const e = document.createElementNS(NS, tag);
  for (const [k, v] of Object.entries(attrs)) e.setAttribute(k, String(v));
  if (text !== undefined) e.textContent = text;
  return e;
}
const clip = (t: string, n: number) => t.length > n ? t.slice(0, n - 1) + '…' : t;
const firstLine = (t: string | null) => (t ?? '').split(/\r?\n/).map(l => l.trim()).find(l => l !== '') ?? '';
// keylock -> KEY lock; exchangeEvent -> exchangeEvent (a parallel exchange), threadpool, resourceWait as they are
export const resourceKind = (type: string) => /lock$/i.test(type) ? type.replace(/lock$/i, '').toUpperCase() + ' lock' : type;
export const sessionName = (p: DlProcess) => p.spid == null ? p.process : `Session ${p.spid}`;

const PW = 250, PH = 104, RW = 250, RH = 70, GAP = 40, TOP = 16, MID = 120;

// deadlockSvg draws the graph. The picture has a text alternative in its label and the grids beside it.
export function deadlockSvg(g: DlGraph): SVGSVGElement {
  // a resource sits under the first process that holds it, so a hold is a short vertical edge and a wait crosses
  const order: DlResource[] = [];
  for (const p of g.processes) for (const r of g.resources) if (!order.includes(r) && r.owners.some(o => o.process === p.process)) order.push(r);
  for (const r of g.resources) if (!order.includes(r)) order.push(r);
  const cols = Math.max(g.processes.length, order.length, 1);
  const width = cols * (PW + GAP) + GAP;
  const height = TOP + PH + MID + RH + TOP;
  const rowX = (n: number, i: number, w: number) => (width - (n * (w + GAP) - GAP)) / 2 + i * (w + GAP);
  const pos = new Map<string, number>();
  g.processes.forEach((p, i) => pos.set(p.process, rowX(g.processes.length, i, PW)));
  const ry = TOP + PH + MID;

  const victims = g.processes.filter(p => p.victim).map(sessionName);
  const label = `Deadlock graph: ${g.processes.map(p => sessionName(p) + (p.victim ? ' (victim)' : '')).join(', ')}; `
    + order.map(r => `${resourceKind(r.type)} ${r.object ?? ''} held by ${r.owners.map(o => o.spid ?? o.process).join(', ') || 'none'}, wanted by ${r.waiters.map(w => w.spid ?? w.process).join(', ') || 'none'}`).join('; ')
    + (victims.length ? `. Victim: ${victims.join(', ')}.` : '.');
  const svg = s('svg', { viewBox: `0 0 ${width} ${height}`, width, height, role: 'img', 'aria-label': label, class: 'deadlock-graph' });
  svg.style.maxWidth = '100%';
  svg.style.height = 'auto';
  svg.append(s('title', {}, label));
  const defs = s('defs');
  for (const [id, colour] of [['dl-arrow', 'var(--fg)'], ['dl-arrow-wait', 'var(--warn)']] as const) {
    const m = s('marker', { id, viewBox: '0 0 10 10', refX: 9, refY: 5, markerWidth: 7, markerHeight: 7, orient: 'auto-start-reverse' });
    const path = s('path', { d: 'M 0 0 L 10 5 L 0 10 z' });
    path.style.fill = colour;
    m.append(path);
    defs.append(m);
  }
  svg.append(defs);

  // edges first, so the boxes sit on top of their ends. Each box spreads its edges along its side in the order of
  // the boxes at their other ends, left to right, so a hold under its owner runs straight and edges do not cross there
  type Link = { proc: string; ri: number; mode: string; wait: boolean };
  const links: Link[] = [];
  order.forEach((r, ri) => {
    for (const o of r.owners) if (pos.has(o.process)) links.push({ proc: o.process, ri, mode: o.mode ?? r.mode ?? '?', wait: false });
    for (const w of r.waiters) if (pos.has(w.process)) links.push({ proc: w.process, ri, mode: w.mode ?? '?', wait: true });
  });
  const rxOf = (ri: number) => rowX(order.length, ri, RW);
  const slot = (mine: Link[], self: Link, otherX: (l: Link) => number, w: number) => {
    const sorted = [...mine].sort((a, b) => otherX(a) - otherX(b) || Number(a.wait) - Number(b.wait));
    return (sorted.indexOf(self) + 1) * w / (sorted.length + 1);
  };
  const labels: SVGGElement[] = [];
  for (const l of links) {
    const pl = links.filter(x => x.proc === l.proc), rl = links.filter(x => x.ri === l.ri);
    const pPt: [number, number] = [pos.get(l.proc)! + slot(pl, l, x => rxOf(x.ri), PW), TOP + PH];
    const rPt: [number, number] = [rxOf(l.ri) + slot(rl, l, x => pos.get(x.proc)!, RW), ry];
    const [from, to] = l.wait ? [pPt, rPt] : [rPt, pPt];
    const text = l.wait ? `waits for ${l.mode}` : `holds ${l.mode}`;
    const line = s('line', { x1: from[0], y1: from[1], x2: to[0], y2: to[1], 'stroke-width': 1.6, 'marker-end': `url(#${l.wait ? 'dl-arrow-wait' : 'dl-arrow'})` });
    line.style.stroke = l.wait ? 'var(--warn)' : 'var(--fg)';
    if (l.wait) line.setAttribute('stroke-dasharray', '6 4');
    svg.append(line);
    // a hold's label in the middle of its line, a wait's near the waiting session: two crossing waits keep apart
    const t = l.wait ? 0.22 : 0.5;
    const x = from[0] + (to[0] - from[0]) * t, y = from[1] + (to[1] - from[1]) * t;
    const gl = s('g', { class: 'dl-edge-label' });
    const w = text.length * 6.6 + 10;
    const bg = s('rect', { x: x - w / 2, y: y - 10, width: w, height: 18, rx: 3 });
    bg.style.fill = 'var(--card)';
    bg.style.stroke = l.wait ? 'var(--warn)' : 'var(--line)';
    const tx = s('text', { x, y: y + 3, 'text-anchor': 'middle', 'font-size': 11 }, text);
    tx.style.fill = 'var(--fg)';
    gl.append(bg, tx);
    labels.push(gl);
  }

  g.processes.forEach(p => {
    const x = pos.get(p.process)!;
    const box = s('g', { class: p.victim ? 'dl-process dl-victim' : 'dl-process' });
    const rect = s('rect', { x, y: TOP, width: PW, height: PH, rx: 6, 'stroke-width': p.victim ? 3 : 1.2 });
    rect.style.fill = 'var(--card)';
    rect.style.stroke = p.victim ? 'var(--crit)' : 'var(--line)';
    box.append(s('title', {}, `${sessionName(p)}${p.victim ? ' (the victim)' : ''}\n${p.statement ?? ''}`), rect);
    const line = (y: number, text: string, o: { bold?: boolean; mono?: boolean } = {}) => {
      const t = s('text', { x: x + 10, y, 'font-size': o.mono ? 11 : 12, 'font-weight': o.bold ? 700 : 400 }, text);
      t.style.fill = 'var(--fg)';
      if (o.mono) t.style.fontFamily = 'ui-monospace, SFMono-Regular, Menlo, Consolas, monospace';
      box.append(t);
    };
    line(TOP + 20, sessionName(p), { bold: true });
    if (p.victim) {
      const bw = 52, bx = x + PW - bw - 8;
      const b = s('rect', { x: bx, y: TOP + 7, width: bw, height: 18, rx: 3 });
      b.style.fill = 'var(--crit)';
      const bt = s('text', { x: bx + bw / 2, y: TOP + 20, 'text-anchor': 'middle', 'font-size': 11, 'font-weight': 700 }, 'VICTIM');
      bt.style.fill = 'var(--badge-fg)';
      box.append(b, bt);
    }
    line(TOP + 40, clip([p.login, p.host].filter(Boolean).join(' @ ') || (p.program ?? ''), 38));
    line(TOP + 60, clip([p.database, p.waits_mode ? `wants ${p.waits_mode}` : null, p.wait_ms != null ? `waited ${p.wait_ms} ms` : null].filter(Boolean).join(' · '), 38));
    line(TOP + 82, clip(firstLine(p.proc ? `${p.proc}: ${p.statement ?? ''}` : p.statement), 36), { mono: true });
    svg.append(box);
  });

  order.forEach((r, ri) => {
    const x = rowX(order.length, ri, RW);
    const box = s('g', { class: 'dl-resource' });
    const rect = s('rect', { x, y: ry, width: RW, height: RH, rx: 2, 'stroke-width': 1.2 });
    rect.style.fill = 'var(--bg)';
    rect.style.stroke = 'var(--muted)';
    box.append(s('title', {}, `${resourceKind(r.type)} ${r.object ?? ''}${r.index ? ' (' + r.index + ')' : ''}`), rect);
    const line = (y: number, text: string, bold = false) => {
      const t = s('text', { x: x + 10, y, 'font-size': 12, 'font-weight': bold ? 700 : 400 }, text);
      t.style.fill = 'var(--fg)';
      box.append(t);
    };
    line(ry + 20, resourceKind(r.type) + (r.mode ? ` (granted ${r.mode})` : ''), true);
    line(ry + 40, clip(r.object ?? '', 38));
    if (r.index) line(ry + 58, clip('index ' + r.index, 38));
    svg.append(box);
  });
  svg.append(...labels);
  return svg;
}
