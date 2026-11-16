// request.ts: a button whose POST the server sent through the request queue (actions.via queue, task CQ) gets 202
// {request_id, via: 'queue'} back; the page then waits on GET /api/requests/<id>?wait=25, which answers the moment
// the request ends (the collector's result, its refusal, 'expired' or 'lost'), and says each state on the way:
// waiting for the collector, then running on <host> since <time>, with the request's id. A Cancel button asks
// POST /api/requests/<id>/cancel. A server that does not answer (a restart, a 5xx) is asked again with a growing pause,
// the Cancel button kept; the wait ends when its status line leaves the page. The result is the asker's alone (another
// user's GET is refused by the server).
// Data: GET /api/requests/{id}?wait=N, POST /api/requests/{id}/cancel (internal/web/q_requests.go).
import { LoginRequired, post } from './api';
import { InstanceRun, ResultSet, resultView } from './customreports';
import { badge, el, fmtNum, fmtTime } from './ui';

export interface Queued { request_id: number; expires_at?: string; detail?: string; via?: string }

export interface RequestEnd {
  request_id: number; kind?: string; instance?: string; state: string;
  asked_at?: string; expires_at?: string; taken_host?: string; taken_at?: string; done_at?: string;
  outcome?: string; refusal?: string; rows?: number; duration_ms?: number; cleared?: boolean;
  // cut: the stored result was cut to queue mode's 8 MB, in the collector's words
  result?: { sets?: ResultSet[]; declined?: boolean; error?: string; duration_ms?: number; params?: unknown; help?: Record<string, string>; cut?: string } | null;
}

// isQueued: the POST's answer is an ask of the queue, not the direct run's reply.
export function isQueued(x: unknown): x is Queued {
  return !!x && typeof (x as Queued).request_id === 'number' && (x as Queued).via === 'queue';
}

const ended = (s: string) => s !== 'waiting' && s !== 'running';

// sentence: an end's words closed with a stop, so ' Request <n>.' after them starts a sentence of its own (the
// collector's words carry none: 'cancelled by its asker while it ran').
const sentence = (s: string) => /[.!?]$/.test(s.trim()) ? s.trim() : s.trim() + '.';

// stateWords: what the page says while a request waits or runs, and when it ended without a result. The repository
// stores '' for words a state does not have (a done run's refusal), so the fallbacks are by ||, never ??.
export function stateWords(e: RequestEnd): string {
  switch (e.state) {
    case 'waiting': return 'Waiting for the collector to take it' + (e.asked_at ? ` (asked ${fmtTime(e.asked_at)})` : '') + '.';
    case 'running': return `Running on ${e.taken_host ?? 'the collector'}` + (e.taken_at ? ` since ${fmtTime(e.taken_at)}` : '') + '.';
    case 'done': return `Ran on ${e.taken_host ?? 'the collector'}` + (e.done_at ? ` at ${fmtTime(e.done_at)}` : '') + '.';
    case 'refused': return sentence(e.refusal || 'Refused.');
    case 'expired': return sentence(e.outcome || 'No collector took it before it expired: it was never run.');
    case 'lost': return sentence(e.outcome || 'The collector stopped while running it: it may or may not have run.');
    case 'cancelled': return sentence(e.outcome || 'Cancelled.');
    default: return sentence(e.outcome || e.state);
  }
}

// Unanswered: the server did not answer the wait (a network error or a 5xx): asked again.
class Unanswered extends Error {}

// readEnd is one wait: the request's state, a 4xx's words as an Error (another user, no such request), a 401 as
// LoginRequired, and Unanswered for what is worth asking again.
async function readEnd(id: number, signal: AbortSignal): Promise<RequestEnd> {
  let res: Response;
  try {
    res = await fetch(`/api/requests/${id}?wait=25`, { headers: { Accept: 'application/json' }, credentials: 'same-origin', signal });
  } catch (e) {
    if (signal.aborted) throw e;
    throw new Unanswered(String((e as Error).message ?? e));
  }
  if (res.status === 401) throw new LoginRequired();
  const b = await res.json().catch(() => ({ error: res.statusText })) as RequestEnd & { error?: string };
  if (res.status >= 500) throw new Unanswered(b.error ?? res.statusText);
  if (!res.ok) throw new Error(b.error ?? res.statusText);
  return b;
}

const pause = (ms: number, signal: AbortSignal) => new Promise<void>((done, fail) => {
  const t = window.setTimeout(done, ms);
  signal.addEventListener('abort', () => { window.clearTimeout(t); fail(new DOMException('the view was left', 'AbortError')); }, { once: true });
});

// waitRequest waits for a queued request to end, saying each state and the request's id in status, with a Cancel
// button while it waits or runs; it returns the end (its result, for the asker). It stops (an AbortError) when status
// leaves the page.
export async function waitRequest(q: Queued, status: HTMLElement): Promise<RequestEnd> {
  const cancel = el('button', { type: 'button', class: 'link' }, 'Cancel');
  const words = el('span', {}, 'Waiting for the collector to take it.');
  const said = el('span', { class: 'meta' }, ` Request ${q.request_id}.`);
  status.replaceChildren(words, said, ' ', cancel);
  cancel.addEventListener('click', async () => {
    cancel.setAttribute('disabled', '');
    try {
      const r = await post<{ detail?: string }>(`requests/${q.request_id}/cancel`, {});
      words.textContent = r.detail ?? 'Cancel asked.';
    } catch (e) {
      words.textContent = String((e as Error).message ?? e);
      cancel.removeAttribute('disabled');   // the cancel did not go in: it can be asked again
    }
  });
  const ac = new AbortController();
  const leave = window.setInterval(() => { if (!status.isConnected) ac.abort(); }, 2000);
  let back = 1000;
  try {
    for (;;) {
      let e: RequestEnd;
      try {
        e = await readEnd(q.request_id, ac.signal);
        back = 1000;
      } catch (err) {
        if (!(err instanceof Unanswered)) throw err;
        words.textContent = `The server did not answer (${err.message}); asking again in ${back / 1000} s.`;
        await pause(back, ac.signal);
        back = Math.min(back * 2, 15000);
        continue;
      }
      if (ended(e.state)) {
        status.replaceChildren(stateWords(e), ` Request ${q.request_id}.`);
        return e;
      }
      words.textContent = stateWords(e);
    }
  } finally {
    window.clearInterval(leave);
  }
}

// asRun: a queued community run's end as the direct reply's one run, so resultView draws it the same way. A cut set's
// truncated mark is dropped when the whole result says its own cut (cutWords draws it above the sets): the direct
// run's words ('the run's 24 MB') are not queue mode's.
export function asRun(e: RequestEnd, instance: string, engine: string): InstanceRun {
  const r = e.result ?? {};
  const outcome = e.state === 'done' ? 'done' : e.state === 'refused' ? 'refused' : 'failed';
  const sets = (r.sets ?? []).map(s => r.cut ? { ...s, truncated: false } : s);
  return {
    instance, engine, outcome, rows: e.rows ?? 0, duration_ms: e.duration_ms ?? r.duration_ms ?? 0, sets,
    declined: r.declined, error: e.state === 'done' ? (r.error || undefined) : (e.refusal || e.outcome || r.error || undefined),
  };
}

// endView: a queued run's end in the panel. A run that ended done, refused or failed is drawn as the direct reply's
// run (resultView). A cancel, an expiry or a loss is not a failure of the call: its own word on the badge (a loss red:
// it may or may not have run), its words as a note, in the same result section.
export function endView(e: RequestEnd, instance: string, engine: string, title: string): HTMLElement {
  if (e.state !== 'cancelled' && e.state !== 'expired' && e.state !== 'lost') return resultView([asRun(e, instance, engine)], undefined, title);
  return el('section', { class: 'report-result' }, el('h3', {}, `${title}: ${instance}`),
    el('p', { class: 'meta' }, badge(e.state, e.state === 'lost' ? 'crit' : 'warn'), ` ${fmtNum(e.rows ?? 0)} rows in ${fmtNum(e.duration_ms ?? 0)} ms`),
    el('p', { class: 'meta refused', role: 'note' }, stateWords(e)));
}

// cutWords: the stored result's own cut ('cut at <n> rows: queue mode keeps 8 MB'), or nothing.
export function cutWords(e: RequestEnd): HTMLElement[] {
  return e.result?.cut ? [el('p', { class: 'meta', role: 'note' }, `The result is ${e.result.cut}.`)] : [];
}
