import { route } from '../../../lib/http.js';
import { defaultDeps } from '../../../lib/deps.js';
import { checkoutSync } from '../../../lib/handlers.js';

const handler = route('POST', (request) => checkoutSync(request, defaultDeps()));
export { handler as GET, handler as POST, handler as PUT, handler as PATCH, handler as DELETE };
