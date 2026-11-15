// The Properties tab's 'N not read' count (web/src/props_count.ts), checked offline on an esbuild bundle of it:
//   node scripts/props-count-check.mjs <bundle.mjs>
// Prints 'ok' or 'FAIL' per check and exits 1 when one failed.
const m = await import(new URL(process.argv[2], `file://${process.cwd()}/`).href);
let failed = 0;
const check = (name, got, want) => { const ok = got === want; if (!ok) failed++; console.log(`${ok ? 'ok  ' : 'FAIL'} ${name}: ${got}${ok ? '' : ' (wanted ' + want + ')'}`); };
check('a row with its value', m.unreadCount([{ value: 'no', note: '' }]), 0);
check("a row 'not read'", m.unreadCount([{ value: null, note: 'not read: xp_instance_regread holds no ForceEncryption value' }]), 1);
check("a row 'not set' (an absent value the setting allows)", m.unreadCount([{ value: null, note: 'not set (strict encryption off unless it is set)' }]), 0);
check('the three together', m.unreadCount([{ value: 'no' }, { value: null, note: 'not read: a' }, { value: null, note: 'not set (strict encryption off unless it is set)' }]), 1);
check('a row with no note and no value', m.unreadCount([{ value: null }]), 1);
process.exit(failed ? 1 : 0);
