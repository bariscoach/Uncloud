// POST /v1/webhooks/payments
// Accepts a Lemon Squeezy-style or Paddle-style JSON body. Does not verify a signature
// and does not mint a license. See lib/licenses.js.
import { route } from '../../../lib/http.js';
import { paymentWebhookRequest } from '../../../lib/licenses.js';

const handler = route('POST', paymentWebhookRequest);
export { handler as GET, handler as POST, handler as PUT, handler as PATCH, handler as DELETE };
