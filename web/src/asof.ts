// A remote instance's freshness (docs/remote-collector.md): a remote collector reads it inside a site the hub cannot
// reach and its rows arrive in bundles, so its pages say how fresh they are - 'as of' the newest bundle's window end,
// the collector and the site, the bundle's interval - and judge it by the site's cadence (expected_every), never by
// the hub's clock alone. The live row (GET /api/ack?part=live, q_ack.go) carries as_of, site, collector,
// interval_secs and expected_every_secs for a remote instance and none of them for any other.
import type { Row } from './api';

export interface Remote { asOf: number; loadedAt: number; site: string; collector: string; everySecs: number; expectedSecs: number }

// remoteOf: the live row's remote fields, or null for an instance the hub reads itself
export function remoteOf(r: Row | undefined): Remote | null {
  if (!r || r.as_of == null || r.site == null) return null;
  const asOf = Date.parse(String(r.as_of));
  if (isNaN(asOf)) return null;
  const loaded = Date.parse(String(r.loaded_at ?? ''));
  return { asOf, loadedAt: isNaN(loaded) ? asOf : loaded, site: String(r.site), collector: String(r.collector ?? ''),
    everySecs: Number(r.interval_secs ?? 0) || 0, expectedSecs: Number(r.expected_every_secs ?? 0) || 300 };
}

// PerformanceMonitor's rule: no healthy collection for 30 minutes is offline (for a remote instance: in the 30 minutes
// before its newest bundle)
export const OFFLINE_MIN = 30;
// the site goes quiet at 2 x expected_every (its silence finding's warning)
const QUIET_TIMES = 2, OFFLINE_BEFORE_MIN = OFFLINE_MIN;
// quiet: no bundle LOADED by the hub (its clock, never the site's: review C S4) for 2 x max(expected_every, the bundle
// interval) (review C N4: an hourly bundle on a site that says 5 minutes is not quiet between bundles)
const quiet = (rem: Remote, now: number) => now - rem.loadedAt > QUIET_TIMES * Math.max(rem.expectedSecs, rem.everySecs) * 1000;
// an age in words: Nm ago, Nh ago, Nd ago
function ago(ms: number): string {
  const min = Math.floor(ms / 60000);
  if (min < 60) return `${Math.max(min, 0)}m ago`;
  const hr = Math.floor(min / 60);
  return hr < 24 ? `${hr}h ago` : `${Math.floor(hr / 24)}d ago`;
}

// remoteFreshness: a remote instance's freshness (freshness() below asks it first): offline when its site
// sent no bundle for 2 x expected_every (the site's silence) or its collector collected nothing healthy in the 30
// minutes before its newest bundle; stale when a collection is stale against as_of (the live read's coll_stale);
// else online. null for an instance the hub reads itself.
export function remoteFreshness(r: Row | undefined, now = Date.now()): 'online' | 'stale' | 'offline' | null {
  const rem = remoteOf(r);
  if (!rem) return null;
  if (quiet(rem, now)) return 'offline';
  const last = Date.parse(String(r?.last_collect_at ?? ''));
  if (isNaN(last) || rem.asOf - last > OFFLINE_BEFORE_MIN * 60000) return 'offline';
  return Number(r?.coll_stale ?? 0) > 0 ? 'stale' : 'online';
}

export type Freshness = 'online' | 'stale' | 'offline' | 'awaiting';
// freshness: the instance header's and the Summary's rule (instheader.ts re-exports it) - online, stale (a collection
// past its interval: the footer's rule), offline (no healthy collection for 30 minutes), awaiting (no collection ever);
// a remote instance by its newest bundle and its site's cadence first (remoteFreshness). DOM-free, so its unit test
// runs the header's own rule (review B S7).
export function freshness(r: Row | undefined, now = Date.now()): Freshness {
  if (!r || r.last_collect_at == null) return 'awaiting';
  const rf = remoteFreshness(r, now);
  if (rf) return rf;
  if (now - Date.parse(String(r.last_collect_at)) > OFFLINE_MIN * 60000) return 'offline';
  return Number(r.coll_stale ?? 0) > 0 ? 'stale' : 'online';
}

// asOfLine: 'as of <clock> (remote collector <c> of site <s>, a bundle every <interval>)' - its day too when it is not
// today (review C S5: a daily site's 'as of 09:00' is yesterday's); 'a remote collector of site <s>' while its collector
// is not known yet (no bundle loaded); '' for another instance
export function asOfLine(r: Row | undefined, now = Date.now()): string {
  const rem = remoteOf(r);
  if (!rem) return '';
  const at = new Date(rem.asOf);
  const sameDay = at.toDateString() === new Date(now).toDateString();
  const clock = (sameDay ? '' : at.toLocaleDateString(undefined, { month: 'short', day: 'numeric' }) + ' ')
    + at.toLocaleTimeString(undefined, { hour: '2-digit', minute: '2-digit' });
  const every = rem.everySecs > 0 ? `a bundle every ${Math.round(rem.everySecs / 60)} min` : 'its bundle interval not known yet';
  const from = rem.collector ? `remote collector ${rem.collector} of site ${rem.site}` : `a remote collector of site ${rem.site}`;
  return `as of ${clock} (${from}, ${every})`;
}

// quietLine: the site's silence in the words of its finding, 'site <s> has gone quiet: last bundle <age>', once no
// bundle came for 2 x expected_every; '' otherwise
export function quietLine(r: Row | undefined, now = Date.now()): string {
  const rem = remoteOf(r);
  return rem && quiet(rem, now) ? `site ${rem.site} has gone quiet: last bundle ${ago(now - rem.loadedAt)}` : '';
}
