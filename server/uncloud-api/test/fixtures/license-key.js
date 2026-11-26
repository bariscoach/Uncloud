// TEST ONLY. This keypair is for unit tests. It is not the production signing key.
// The app verifies with UncloudLicensePublicKey. These tests pass this public key in
// directly and do not read Info.plist.

export const TEST_LICENSE_PRIVATE_KEY = 'MC4CAQAwBQYDK2VwBCIEICgXFrBsA0sKZFo7wqo0ztU/g7ap0AFaVrflcwW99jwD';
export const TEST_LICENSE_PUBLIC_KEY = '9eTHD62q5241M5GcgIzPInNbF+/Jsi9c7emeztduWFQ=';

// Signed with the test key. Payload is the canonical JSON below.
export const TEST_LICENSE_TOKEN = 'UC1.eyJpYXQiOjE3NjQwMDAwMDAsImp0aSI6ImNzX3Rlc3RfdmVjdG9yIiwic2VhdHMiOjEsInRpZXIiOiJwbHVzIiwidiI6MX0.G7-VNyTkGua4Q8s27S-GtBJ_ZsaDKrAh5WK11qN4iHanE6ZdNgJ-JJY_hgD7IrY1lgRQqXW5kzpJmELwDP5GCQ';
export const TEST_LICENSE_JSON = '{"iat":1764000000,"jti":"cs_test_vector","seats":1,"tier":"plus","v":1}';
