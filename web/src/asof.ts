// A remote instance's freshness (docs/remote-collector.md): a remote collector reads it inside a site the hub cannot
// reach and its rows arrive in bundles, so its pages say how fresh they are - 'as of' the newest bundle's window end,
// the collector and the site, the bundle's interval - and judge it by the site's cadence (expected_every), never by
// the hub's clock alone. The live row (GET /api/ack?part=live, q_ack.go) carries as_of, site, collector,
// interval_secs and expected_every_secs for a remote instance and none of them for any other.
import type { Row } from './api';

export interface Remote { asOf: number; site: string; collector: string; everySecs: number; expectedSecs: number }

// remoteOf: the live row's remote fields, or null for an instance the hub reads itself
export function remoteOf(r: Row | undefined): Remote | null {
  void r;
  return null; // OUTBOX V task 1: the red rows' stub
}

// asOfLine: 'as of <clock> (remote collector <c> of site <s>, a bundle every <interval>)'; '' for another instance
export function asOfLine(r: Row | undefined): string {
  void r;
  return ''; // OUTBOX V task 1: the red rows' stub
}

// quietLine: the site's silence in the words of its finding, 'site <s> has gone quiet: last bundle <age>', once no
// bundle came for 2 x expected_every; '' otherwise
export function quietLine(r: Row | undefined, now = Date.now()): string {
  void r; void now;
  return ''; // OUTBOX V task 1: the red rows' stub
}
