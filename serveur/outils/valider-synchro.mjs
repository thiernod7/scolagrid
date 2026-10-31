// Vérifie les règles de synchronisation avec la bibliothèque du service PowerSync.
// Usage : node valider-synchro.mjs ../powersync/sync-config.yaml
import { SqlSyncRules } from '@powersync/service-sync-rules';
import fs from 'fs';
const r = SqlSyncRules.fromYaml(fs.readFileSync(process.argv[2], 'utf8'), { defaultSchema: 'public', throwOnError: false });
const errs = r.errors ?? [];
for (const e of errs) console.log(e.type ?? '', e.message);
const graves = errs.filter(e => e.type !== 'warning').length;
console.log(graves ? 'ERREURS' : 'OK');
process.exit(graves ? 1 : 0);
