// A label that reads as a number (task PGRID, P-opengrid's fault on the base). A string the server sends for a column
// the page draws as text - a version '17.10', a code '1.0' - is a number only when that number writes back the same
// text. '17.10' is not 17.1: PostgreSQL 17.10 and 17.1 are two versions, and the JSON and SQL forms write the cell's
// value, so the file said 17.1 and Open Grid drew another version. No DOM: export_text.test.mjs runs it in Node.

// labelText: true = keep the text (the number's own text is another text: a trailing zero, an exponent, '-0')
export function labelText(raw: string): boolean {
  const n = Number(raw);
  return !Number.isFinite(n) || String(n) !== raw;
}
