// metricfam.ts - the Metrics page's Collection family (B6g-4, N30 / N31): DBA Dash's collection counters, hidden from
// the Metrics page until its toolbar's 'Collection Metrics' is ticked (kept per browser), each series one collection -
// the sub-series slot every per-database family uses (SERIES (a)), cut on the page by its own
// address key so a Database cut and a Collection cut never mix; with no cut, the worst collection each hour. Pure but
// tickStore's storage: the Node rows are metricfam.test.mjs.

export const COLLECTION_FAMILY = 'collection';
export const collectionTickKey = 'pgvigil.metricsCollection';

// visibleFamilies: the families the page lists - the Collection family once ticked, or when the address names it
// (a shared link opens what it names)
export function visibleFamilies<T extends [string, string]>(fams: T[], ticked: boolean, asked?: string): T[] {
  return fams.filter(([k]) => k !== COLLECTION_FAMILY || ticked || asked === COLLECTION_FAMILY);
}

// tickStore: the tick kept per browser, and for the page's life when storage is off or throws (a tick that
// cleared itself on the re-render left the family unreachable)
export function tickStore(storage: () => Pick<Storage, 'getItem' | 'setItem'>): { get(k: string): string | null; set(k: string, v: string): void } {
  const mem = new Map<string, string>();
  return {
    get(k) { try { return storage().getItem(k) ?? mem.get(k) ?? null; } catch { return mem.get(k) ?? null; } },
    set(k, v) { mem.set(k, v); try { storage().setItem(k, v); } catch { /* off: kept for this page */ } },
  };
}

// subSeries: the cut a family's read takes (the API's db=): the Collection family's own collection, any other
// per-database family's database; none = the instance's series (its databases summed, or its worst collection each hour)
export function subSeries(family: string, mdb?: string, mcol?: string): string | undefined {
  return family === COLLECTION_FAMILY ? mcol : mdb;
}

// subWords: the picker's words for a family's sub-series; none = what the series with no cut is (a rule naming none
// watches it). The Collection family's is the worst collection each hour (#6 (a)).
export function subWords(family: string): { noun: string; all: string; label: string; none: string } {
  return family === COLLECTION_FAMILY
    ? { noun: 'collection', all: 'the worst collection', label: 'Collection', none: 'the worst collection each hour' }
    : { noun: 'database', all: 'all databases (summed)', label: 'Database', none: 'all databases summed' };
}

// subNoun: the word for a rule's sub-series by its metric key (a Collection rule names a collection)
export function subNoun(metricKey: string): string {
  return metricKey.startsWith(COLLECTION_FAMILY + '.') ? 'collection' : 'database';
}
