// POST /v1/licenses/verify  { "key": "UC1.plus.1.s.abcdefgh" }
// No account. No signature secret. See lib/licenses.js.
import { route } from '../../../lib/http.js';
import { verifyLicenseRequest } from '../../../lib/licenses.js';

const handler = route('POST', verifyLicenseRequest);
export { handler as GET, handler as POST, handler as PUT, handler as PATCH, handler as DELETE };
