// Catch-all for unknown /v1 paths, so they get the JSON error envelope instead of the HTML 404 page (review L5).
import { errorResponse } from '../../lib/http.js';

const notFound = () => errorResponse('not_found', 404, 'There is no such endpoint.');
export { notFound as GET, notFound as POST, notFound as PUT, notFound as PATCH, notFound as DELETE };
