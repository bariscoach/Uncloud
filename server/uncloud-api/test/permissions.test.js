// Review M3: the restricted-key permissions documented for the server must cover every Stripe API
// call the code makes. A new call without an entry here fails the test, so the docs get updated with it.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, '..');
const runbook = readFileSync(join(root, '..', 'scripts', 'RUNBOOK.md'), 'utf8');

// Stripe call (SDK path) -> Dashboard restricted-key resource and access it needs.
const PERMISSIONS = {
  'prices.list': [['Prices', 'Read']],
  'customers.create': [['Customers', 'Write']],
  'checkout.sessions.create': [['Checkout Sessions', 'Read and Write']],
  'checkout.sessions.retrieve': [['Checkout Sessions', 'Read and Write']],
  'billingPortal.sessions.create': [['Customer portal', 'Write']],
  'subscriptions.retrieve': [['Subscriptions', 'Read and Write']],
  'subscriptions.update': [['Subscriptions', 'Read and Write']],
  'subscriptions.cancel': [['Subscriptions', 'Read and Write']],
  'invoices.retrieve': [['Invoices', 'Read']],
  'invoicePayments.list': [['Invoice Payments', 'Read']],
  'refunds.list': [['Refunds', 'Read and Write']],
  'refunds.create': [['Refunds', 'Read and Write']],
};
// Calls that make no request to Stripe's API.
const NO_API_CALL = new Set(['webhooks.constructEvent']);

function sourceFiles(dir) {
  return readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
    const path = join(dir, entry.name);
    if (entry.isDirectory()) return sourceFiles(path);
    return entry.name.endsWith('.js') ? [path] : [];
  });
}

function stripeCallsInCode() {
  const calls = new Set();
  for (const file of [...sourceFiles(join(root, 'lib')), ...sourceFiles(join(root, 'api'))]) {
    for (const [, path] of readFileSync(file, 'utf8').matchAll(/\bstripe\.((?:\w+\.)+\w+)\(/g)) {
      if (!NO_API_CALL.has(path)) calls.add(path);
    }
  }
  return [...calls].sort();
}

test('every Stripe API call in the code has a documented permission entry', () => {
  const missing = stripeCallsInCode().filter((path) => !(path in PERMISSIONS));
  assert.deepEqual(missing, [], 'add these calls to PERMISSIONS and to the RUNBOOK permission list');
});

test('no permission entry is left for a call the code no longer makes', () => {
  const used = new Set(stripeCallsInCode());
  const stale = Object.keys(PERMISSIONS).filter((path) => !used.has(path));
  assert.deepEqual(stale, []);
});

test('the RUNBOOK table lists every resource and access the calls need (review M3)', () => {
  const needed = new Set(Object.values(PERMISSIONS).flat().map(([resource, access]) => `| ${resource} | ${access} |`));
  const missing = [...needed].filter((row) => !runbook.includes(row));
  assert.deepEqual(missing, []);
});
