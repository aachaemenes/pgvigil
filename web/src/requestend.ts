// requestend.ts: a queued request's end as words and as the direct reply's run - the pure part of request.ts, in a
// module of its own so its unit tests (requestend.test.mjs) bundle it without the page (request.ts draws; this one only
// answers). Data: GET /api/requests/{id} (internal/web/q_requests.go).
import type { InstanceRun, ResultSet } from './customreports';
import { fmtTime } from './ui';

export interface RequestEnd {
  request_id: number; kind?: string; instance?: string; state: string;
  asked_at?: string; expires_at?: string; taken_host?: string; taken_at?: string; done_at?: string;
  outcome?: string; refusal?: string; rows?: number; duration_ms?: number; cleared?: boolean;
  // cut: the stored result was cut to queue mode's 8 MB, in the collector's words
  result?: { sets?: ResultSet[]; declined?: boolean; error?: string; duration_ms?: number; params?: unknown; help?: Record<string, string>; cut?: string } | null;
}

// sentence: an end's words closed with a stop, so ' Request <n>.' after them starts a sentence of its own (the
// collector's words carry none: 'cancelled by its asker while it ran').
const sentence = (s: string) => /[.!?]$/.test(s.trim()) ? s.trim() : s.trim() + '.';

// stateWords: what the page says while a request waits or runs, and when it ended without a result. The fallbacks are
// by ||, never ??: a row written before CQ-LIVEMASK holds '' for words its state does not have (NULL since).
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
