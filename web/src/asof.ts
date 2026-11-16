// A remote instance's freshness (docs/remote-collector.md): a remote collector reads it inside a site the hub cannot
// reach and its rows arrive in bundles, so its pages say how fresh they are - 'as of' the newest bundle's window end,
// the collector and the site, the bundle's interval - and judge it by the site's cadence (expected_every), never by
// the hub's clock alone. The live row (GET /api/ack?part=live, q_ack.go) carries as_of, site, collector,
// interval_secs and expected_every_secs for a remote instance and none of them for any other.
import type { Row } from './api';

export interface Remote { asOf: number; site: string; collector: string; everySecs: number; expectedSecs: number }

// remoteOf: the live row's remote fields, or null for an instance the hub reads itself
export function remoteOf(r: Row | undefined): Remote | null {
  if (!r || r.as_of == null || r.site == null) return null;
  const asOf = Date.parse(String(r.as_of));
  if (isNaN(asOf)) return null;
  return { asOf, site: String(r.site), collector: String(r.collector ?? ''), everySecs: Number(r.interval_secs ?? 0) || 0,
    expectedSecs: Number(r.expected_every_secs ?? 0) || 300 };
}

// the site goes quiet at 2 x expected_every (its silence finding's warning); a collector with no healthy collection
// for 30 minutes before its newest bundle is offline as PerformanceMonitor's rule says (instheader.ts OFFLINE_MIN)
const QUIET_TIMES = 2, OFFLINE_BEFORE_MIN = 30;
const quiet = (rem: Remote, now: number) => now - rem.asOf > QUIET_TIMES * rem.expectedSecs * 1000;
// an age in words: Nm ago, Nh ago, Nd ago
function ago(ms: number): string {
  const min = Math.floor(ms / 60000);
  if (min < 60) return `${Math.max(min, 0)}m ago`;
  const hr = Math.floor(min / 60);
  return hr < 24 ? `${hr}h ago` : `${Math.floor(hr / 24)}d ago`;
}

// remoteFreshness: a remote instance's freshness (instheader.ts freshness() asks it first): offline when its site
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

// asOfLine: 'as of <clock> (remote collector <c> of site <s>, a bundle every <interval>)'; '' for another instance
export function asOfLine(r: Row | undefined): string {
  const rem = remoteOf(r);
  if (!rem) return '';
  const clock = new Date(rem.asOf).toLocaleTimeString(undefined, { hour: '2-digit', minute: '2-digit' });
  const every = rem.everySecs > 0 ? `a bundle every ${Math.round(rem.everySecs / 60)} min` : 'its bundle interval not known yet';
  return `as of ${clock} (remote collector ${rem.collector} of site ${rem.site}, ${every})`;
}

// quietLine: the site's silence in the words of its finding, 'site <s> has gone quiet: last bundle <age>', once no
// bundle came for 2 x expected_every; '' otherwise
export function quietLine(r: Row | undefined, now = Date.now()): string {
  const rem = remoteOf(r);
  return rem && quiet(rem, now) ? `site ${rem.site} has gone quiet: last bundle ${ago(now - rem.asOf)}` : '';
}
