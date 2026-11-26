import { route } from '../../../lib/http.js';
import { defaultDeps } from '../../../lib/deps.js';
import { verifyAuthCode } from '../../../lib/handlers.js';

const handler = route('POST', (request) => verifyAuthCode(request, defaultDeps()));
export { handler as GET, handler as POST, handler as PUT, handler as PATCH, handler as DELETE };
