import { config } from '../src/lib/config.ts';

/**
 * Checks the provider denylist against what OpenRouter currently reports.
 *
 * The list in config is derived, not guessed — but providers get added, and
 * datacenters move. This re-derives it and exits non-zero if reality has
 * drifted, so the policy fails loudly rather than quietly protecting nothing.
 *
 *   npm run providers:audit
 */

interface Provider {
  name: string;
  slug: string;
  headquarters: string | null;
  datacenters: string[] | null;
}

/** Jurisdictions this product will not send private recordings to. */
const EXCLUDED_REGIONS = ['CN'];

const response = await fetch('https://openrouter.ai/api/v1/providers');
if (!response.ok) {
  console.error(`Could not reach OpenRouter: ${response.status}`);
  process.exit(2);
}

const { data } = (await response.json()) as { data: Provider[] };

const shouldExclude = data.filter((p) => {
  const hq = p.headquarters ?? '';
  const dcs = p.datacenters ?? [];
  return EXCLUDED_REGIONS.includes(hq) || dcs.some((d) => EXCLUDED_REGIONS.includes(d));
});

const configured = new Set(config.openrouter.routing.ignoredProviders);
const expected = new Set(shouldExclude.map((p) => p.slug));

const missing = [...expected].filter((slug) => !configured.has(slug));
const stale = [...configured].filter((slug) => !expected.has(slug));

console.log(`Checked ${data.length} providers against regions: ${EXCLUDED_REGIONS.join(', ')}\n`);

console.log('Excluded by policy:');
for (const p of shouldExclude.sort((a, b) => a.slug.localeCompare(b.slug))) {
  const dcs = (p.datacenters ?? []).join(',') || '-';
  const mark = configured.has(p.slug) ? '✓' : '✗ NOT IN DENYLIST';
  console.log(`  ${p.slug.padEnd(16)} hq=${(p.headquarters ?? '?').padEnd(4)} dc=${dcs.padEnd(12)} ${mark}`);
}

if (stale.length > 0) {
  console.log(`\nIn the denylist but no longer matching policy: ${stale.join(', ')}`);
  console.log('(Harmless, but worth removing so the list stays meaningful.)');
}

if (missing.length > 0) {
  console.error(`\nFAIL: ${missing.length} provider(s) match the exclusion policy but are not denied:`);
  console.error(`  ${missing.join(', ')}`);
  console.error('\nAdd them to OPENROUTER_IGNORED_PROVIDERS, or update the default in src/lib/config.ts.');
  process.exit(1);
}

console.log('\nOK — every provider matching the exclusion policy is denied.');
