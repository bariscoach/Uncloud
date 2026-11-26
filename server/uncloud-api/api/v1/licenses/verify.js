// POST /v1/licenses/verify  { "key": "UC1...." }
// No account. Checks the Ed25519 signature and the revocation list.
import { route } from '../../../lib/http.js';
import { verifyLicenseRequest } from '../../../lib/licenses.js';
import { publicKeyFromPrivate, loadPrivateKey } from '../../../lib/licenses.js';
import { supabaseLicenseLedger } from '../../../lib/license-ledger.js';

function depsFromEnv() {
  const raw = process.env.LICENSE_SIGNING_PRIVATE_KEY;
  if (!raw) return {};
  const privateKey = loadPrivateKey(raw);
  return {
    publicKey: publicKeyFromPrivate(privateKey),
    isRevoked: (jti) => supabaseLicenseLedger().isRevoked(jti),
  };
}

const handler = route('POST', (request) => verifyLicenseRequest(request, depsFromEnv()));
export { handler as GET, handler as POST, handler as PUT, handler as PATCH, handler as DELETE };
