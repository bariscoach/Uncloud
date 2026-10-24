// Account deletion (plan §4.2). Deletes the Supabase user; its rows cascade with it. Safe to repeat.

import { logEvent } from './http.js';

export async function deleteAccountFor(deps, userId) {
  await deps.db.deleteUser(userId);
  logEvent({ evt: 'account_delete', user: userId, result: 'deleted' });
}
