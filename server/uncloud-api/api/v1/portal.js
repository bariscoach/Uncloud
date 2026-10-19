import { route } from '../../lib/http.js';
import { defaultDeps } from '../../lib/deps.js';
import { portal } from '../../lib/handlers.js';

const handler = route('POST', (request) => portal(request, defaultDeps()));
export { handler as GET, handler as POST, handler as PUT, handler as PATCH, handler as DELETE };
