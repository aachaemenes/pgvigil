// request.ts: a button whose POST the server sent through the request queue (actions.via queue, task CQ) gets 202
// {request_id, via: 'queue'} back; the page then waits on GET /api/requests/<id>?wait=25, which answers the moment
// the request ends (the collector's result, its refusal, 'expired' or 'lost'), and says each state on the way:
// waiting for the collector, then running on <host> since <time>. A Cancel button asks POST /api/requests/<id>/cancel.
// The result is the asker's alone (another user's GET is refused by the server).
// Data: GET /api/requests/{id}?wait=N, POST /api/requests/{id}/cancel (internal/web/q_requests.go).
import { get, post } from './api';
import { InstanceRun, ResultSet } from './customreports';
import { el, fmtTime } from './ui';

export interface Queued { request_id: number; expires_at?: string; detail?: string; via?: string }

export interface RequestEnd {
  request_id: number; kind?: string; instance?: string; state: string;
  asked_at?: string; expires_at?: string; taken_host?: string; taken_at?: string; done_at?: string;
  outcome?: string; refusal?: string; rows?: number; duration_ms?: number; cleared?: boolean;
  result?: { sets?: ResultSet[]; declined?: boolean; error?: string; duration_ms?: number; params?: unknown; help?: Record<string, string> } | null;
}

// isQueued: the POST's answer is an ask of the queue, not the direct run's reply.
export function isQueued(x: unknown): x is Queued {
  return !!x && typeof (x as Queued).request_id === 'number' && (x as Queued).via === 'queue';
}

const ended = (s: string) => s !== 'waiting' && s !== 'running';

// stateWords: what the page says while a request waits or runs, and when it ended without a result.
export function stateWords(e: RequestEnd): string {
  switch (e.state) {
    case 'waiting': return 'Waiting for the collector to take it' + (e.asked_at ? ` (asked ${fmtTime(e.asked_at)})` : '') + '.';
    case 'running': return `Running on ${e.taken_host ?? 'the collector'}` + (e.taken_at ? ` since ${fmtTime(e.taken_at)}` : '') + '.';
    case 'done': return `Ran on ${e.taken_host ?? 'the collector'}` + (e.done_at ? ` at ${fmtTime(e.done_at)}` : '') + '.';
    case 'refused': return e.refusal ?? 'Refused.';
    case 'expired': return e.outcome ?? 'No collector took it before it expired: it was never run.';
    case 'lost': return e.outcome ?? 'The collector stopped while running it: it may or may not have run.';
    case 'cancelled': return e.outcome ?? 'Cancelled.';
    default: return e.outcome ?? e.state;
  }
}

// waitRequest waits for a queued request to end, saying each state in status, with a Cancel button in status
// while it waits or runs; it returns the end (its result, for the asker).
export async function waitRequest(q: Queued, status: HTMLElement): Promise<RequestEnd> {
  const cancel = el('button', { type: 'button', class: 'link' }, 'Cancel');
  const words = el('span', {}, 'Waiting for the collector to take it.');
  status.replaceChildren(words, ' ', cancel);
  cancel.addEventListener('click', async () => {
    cancel.setAttribute('disabled', '');
    try {
      const r = await post<{ detail?: string }>(`requests/${q.request_id}/cancel`, {});
      words.textContent = r.detail ?? 'Cancel asked.';
    } catch (e) { words.textContent = String((e as Error).message ?? e); }
  });
  for (;;) {
    const e = await get<RequestEnd>(`requests/${q.request_id}`, { wait: 25 });
    if (ended(e.state)) {
      status.replaceChildren(stateWords(e));
      return e;
    }
    words.textContent = stateWords(e);
  }
}

// asRun: a queued community run's end as the direct reply's one run, so resultView draws it the same way.
export function asRun(e: RequestEnd, instance: string, engine: string): InstanceRun {
  const r = e.result ?? {};
  const outcome = e.state === 'done' ? 'done' : e.state === 'refused' ? 'refused' : 'failed';
  return {
    instance, engine, outcome, rows: e.rows ?? 0, duration_ms: e.duration_ms ?? r.duration_ms ?? 0, sets: r.sets ?? [],
    declined: r.declined, error: e.state === 'done' ? (r.error || undefined) : (e.refusal ?? e.outcome ?? r.error),
  };
}
