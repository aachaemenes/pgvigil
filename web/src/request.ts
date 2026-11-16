// request.ts: a button whose POST the server sent through the request queue (actions.via queue, task CQ) gets 202
// {request_id, via: 'queue'} back; the page then waits on GET /api/requests/<id>?wait=25, which answers the moment
// the request ends (the collector's result, its refusal, 'expired' or 'lost'), and says each state on the way:
// waiting for the collector, then running on <host> since <time>, with the request's id. A Cancel button asks
// POST /api/requests/<id>/cancel. A server that does not answer (a restart, a 5xx) is asked again with a growing pause,
// the Cancel button kept; the wait ends when its status line leaves the page. The result is the asker's alone (another
// user's GET is refused by the server).
// Data: GET /api/requests/{id}?wait=N, POST /api/requests/{id}/cancel (internal/web/q_requests.go).
import { LoginRequired, post } from './api';
import { resultView } from './customreports';
import { asRun, RequestEnd, stateWords } from './requestend';
import { badge, el, fmtNum } from './ui';

export type { RequestEnd } from './requestend';

export interface Queued { request_id: number; expires_at?: string; detail?: string; via?: string }

// isQueued: the POST's answer is an ask of the queue, not the direct run's reply.
export function isQueued(x: unknown): x is Queued {
  return !!x && typeof (x as Queued).request_id === 'number' && (x as Queued).via === 'queue';
}

const ended = (s: string) => s !== 'waiting' && s !== 'running';

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
// button while it waits or runs; it returns the end (its result, for the asker). It stops (an AbortError) when alive
// leaves the page - status itself unless the caller names an element that outlives it (the community page's runs
// grid, so a run whose panel another tool replaced is still followed to its end).
export async function waitRequest(q: Queued, status: HTMLElement, alive: HTMLElement = status): Promise<RequestEnd> {
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
  const leave = window.setInterval(() => { if (!alive.isConnected) ac.abort(); }, 2000);
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

// endView: a queued run's end in the panel. A run that ended done, refused or failed is drawn as the direct reply's
// run (resultView). A cancel, an expiry or a loss is not a failure of the call: its own word on the badge (a loss red:
// it may or may not have run), its words as a note, in the same result section.
export function endView(e: RequestEnd, instance: string, engine: string, title: string): HTMLElement {
  if (e.state !== 'cancelled' && e.state !== 'expired' && e.state !== 'lost') return resultView([asRun(e, instance, engine)], undefined, title);
  return el('section', { class: 'report-result' }, el('h3', {}, `${title}: ${instance}`),
    // a cancel before a collector took it, an expiry and a loss hold no rows or time: none said (never '0 rows in 0 ms')
    el('p', { class: 'meta' }, badge(e.state, e.state === 'lost' ? 'crit' : 'warn'), e.duration_ms == null ? '' : ` ${fmtNum(e.rows ?? 0)} rows in ${fmtNum(e.duration_ms)} ms`),
    el('p', { class: 'meta refused', role: 'note' }, stateWords(e)));
}

// cutWords: the stored result's own cut ('cut at <n> rows: queue mode keeps 8 MB'), or nothing.
export function cutWords(e: RequestEnd): HTMLElement[] {
  return e.result?.cut ? [el('p', { class: 'meta', role: 'note' }, `The result is ${e.result.cut}.`)] : [];
}
