// Minimal PostgREST client for Supabase. Every call names its key mode explicitly:
//   { jwt }     the caller's access token with the publishable key (RLS applies)
//   { service } the secret key (server only; bypasses RLS)
// The secret key is never sent together with a user token.

export class DbError extends Error {
  constructor(status, operation) {
    super(`Supabase ${operation} failed with status ${status}`);
    this.name = 'DbError';
    this.status = status;
  }
}

export function createSupabase({ url, publishableKey, secretKey, fetchFn = globalThis.fetch }) {
  const base = url.replace(/\/+$/, '');

  async function send(operation, path, { method = 'GET', body, headers = {}, jwt, service }) {
    if (Boolean(jwt) === Boolean(service)) {
      throw new TypeError('Pass exactly one of { jwt } or { service }');
    }
    const requestHeaders = { accept: 'application/json', ...headers };
    if (service) {
      requestHeaders.apikey = secretKey;
    } else {
      requestHeaders.apikey = publishableKey;
      requestHeaders.authorization = `Bearer ${jwt}`;
    }
    if (body !== undefined) requestHeaders['content-type'] = 'application/json';
    const response = await fetchFn(`${base}${path}`, {
      method,
      headers: requestHeaders,
      body: body === undefined ? undefined : JSON.stringify(body),
    });
    const text = await response.text();
    if (!response.ok) throw new DbError(response.status, operation);
    if (text === '') return null;
    return JSON.parse(text);
  }

  return {
    // filters: { column: value } → column=eq.value. Returns an array of rows.
    async select(table, filters, mode) {
      const params = new URLSearchParams({ select: '*', limit: '50' });
      for (const [column, value] of Object.entries(filters)) params.set(column, `eq.${value}`);
      const rows = await send('select', `/rest/v1/${encodeURIComponent(table)}?${params}`, mode);
      return rows ?? [];
    },

    // ignoreDuplicates: an existing row is left untouched (its created_at too) instead of merged.
    async upsert(table, row, { onConflict, ignoreDuplicates = false }, mode) {
      const params = new URLSearchParams({ on_conflict: onConflict });
      const resolution = ignoreDuplicates ? 'ignore-duplicates' : 'merge-duplicates';
      await send('upsert', `/rest/v1/${encodeURIComponent(table)}?${params}`, {
        ...mode,
        method: 'POST',
        body: row,
        headers: { prefer: `resolution=${resolution},return=minimal` },
      });
    },

    // Deletes the Supabase user (service key). customers and entitlements cascade. A 404 means the user is
    // already gone, so a retry after a partial failure succeeds.
    async deleteUser(userId) {
      try {
        await send('deleteUser', `/auth/v1/admin/users/${encodeURIComponent(userId)}`, {
          method: 'DELETE',
          body: { should_soft_delete: false },
          service: true,
        });
      } catch (error) {
        if (!(error instanceof DbError && error.status === 404)) throw error;
      }
    },

    async rpc(name, args, mode) {
      return send('rpc', `/rest/v1/rpc/${encodeURIComponent(name)}`, {
        ...mode,
        method: 'POST',
        body: args ?? {},
      });
    },
  };
}
