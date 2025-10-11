Firestore issues found in logs

Symptoms seen in device logs:
- FAILED_PRECONDITION: The query requires an index. Log includes a console URL to create composite index(s).
- PERMISSION_DENIED: Missing or insufficient permissions when listening to or writing to collections (e.g., `jobs`, `posts`, `posts/{postId}/likes`).

Steps to resolve

1) Create required composite indexes
- The logs include URLs to create the exact composite index. Open the URL printed in the logs, or use the following indexes JSON to create indexes in the Firebase console.

2) Deploy a temporary development Firestore ruleset
- For local/dev testing you can use permissive rules that allow authenticated users to read/write. DO NOT use this in production. See the `firestore.rules.dev` file included.

3) How to apply
- Create indexes: follow the console URLs in the logs (best) or use the indexes JSON below.
- Deploy rules: in the Firebase console > Firestore > Rules, paste the contents of `firestore.rules.dev` and publish.

Important security note
- The provided rules are permissive and intended for development only. For production, tighten rules to validate user IDs, ownership, and other invariants.

If you want, I can:
- Generate the exact indexes JSON using the index URLs from your logs (copy-paste the URLs into a message) and add them to this repo.
- Provide a stricter ruleset that enforces ownership on writes (e.g., only allow a user to create a post with user_id == request.auth.uid).

Example index entries (create via console if logs provided the create_composite URL):
- For queries like `collection('posts').where('is_private', isEqualTo: false).orderBy('timestamp', descending: true)` create a composite index on (is_private ASC, timestamp DESC)
- For queries like `collection('posts').where('user_id', isEqualTo: <uid>).orderBy('timestamp', descending: true)` create a composite index on (user_id ASC, timestamp DESC)

Files added:
- firestore.indexes.json (example template)
- firestore.rules.dev (temporary dev rules)

-----
