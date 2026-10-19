import { route } from '../../lib/http.js';
import { health } from '../../lib/handlers.js';

const handler = route('GET', () => health());
export { handler as GET, handler as POST, handler as PUT, handler as PATCH, handler as DELETE };
