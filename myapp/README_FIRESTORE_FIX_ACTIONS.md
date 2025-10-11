Quick actions to fix the errors seen in your device logs

1) Create composite indexes
- Open the 'create_composite' URL present in the log message. It opens the Firebase console with a prefilled index configuration. Click 'Create Index'.
- Or, import the included `firestore.indexes.json` via Firebase console > Firestore > Indexes > Import indexes.

2) Deploy temporary dev rules
- Open Firebase console > Firestore > Rules. Replace the current rules with the contents of `firestore.rules.dev` and publish.
- After testing, revert rules to a stricter configuration.

3) Test locally
- Ensure a user is signed-in in the app (FirebaseAuth). Many operations require request.auth.uid.
- Run the app and observe logs; listen failures for PERMISSION_DENIED should go away.

4) Production guidance (next steps)
- Replace `firestore.rules.dev` with rules that enforce ownership and least privilege: e.g.,
  - Only allow creating a post if request.auth.uid == request.resource.data.user_id
  - Only allow editing/deleting a comment if request.auth.uid == resource.data.user_id
  - Allow reads as needed.

If you'd like, I can:
- Produce a conservative production ruleset matching your current schemas (posts, comments, likes, conversations, messages, jobs, users).
- Generate the exact indexes from your logs if you paste the full create_composite URL(s) here.

