// metricfam.ts - the Metrics page's Collection family (B6g-4, N30 / N31): DBA Dash's collection counters, hidden from
// the Metrics page until its toolbar's 'Collection Metrics' is ticked (kept per browser), each series one collection -
// the sub-series slot every per-database family uses (the lead's 07:4x SERIES (a)), cut on the page by its own
// address key so a Database cut and a Collection cut never mix. Pure: the Node rows are metricfam.test.mjs.

export const COLLECTION_FAMILY = 'collection';
export const collectionTickKey = 'pgvigil.metricsCollection';

// visibleFamilies: the families the page lists - the Collection family only once ticked
export function visibleFamilies<T extends [string, string]>(fams: T[], ticked: boolean): T[] {
  return fams.filter(([k]) => k !== COLLECTION_FAMILY || ticked);
}

// subSeries: the cut a family's read takes (the API's db=): the Collection family's own collection, any other
// per-database family's database; none = the instance's series (its databases, or collections, summed)
export function subSeries(family: string, mdb?: string, mcol?: string): string | undefined {
  return family === COLLECTION_FAMILY ? mcol : mdb;
}

// subWords: the picker's words for a family's sub-series
export function subWords(family: string): { noun: string; all: string; label: string } {
  return family === COLLECTION_FAMILY
    ? { noun: 'collection', all: 'all collections (summed)', label: 'Collection' }
    : { noun: 'database', all: 'all databases (summed)', label: 'Database' };
}
