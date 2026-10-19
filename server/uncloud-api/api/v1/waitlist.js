// POST /v1/waitlist from the landing page. Public, so it never touches Stripe or the signing key:
// defaultDeps() only builds lazy getters. Origin rules live in lib/cors.js.
import { route } from '../../lib/http.js';
import { defaultDeps } from '../../lib/deps.js';
import { waitlist } from '../../lib/handlers.js';
import { withCors } from '../../lib/cors.js';
import { loadConfig } from '../../lib/config.js';

const handler = withCors(route('POST', (request) => waitlist(request, defaultDeps())), {
  origins: () => loadConfig().waitlistOrigins,
});
export {
  handler as GET, handler as POST, handler as PUT, handler as PATCH, handler as DELETE, handler as OPTIONS,
};
