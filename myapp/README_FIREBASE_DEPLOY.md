# Firebase deploy: rules, indexes, and App Check (Windows)

This project includes local Firestore security rules and composite indexes. To fix the current `PERMISSION_DENIED` on notebooks and the missing index error on posts, deploy them to your Firebase project and register an App Check debug token for development.

## 1) Install Firebase CLI (PowerShell)

- Install Node.js if needed: https://nodejs.org/
- Install Firebase CLI:
  - Open Windows PowerShell and run:
    - `npm install -g firebase-tools`
  - Verify:
    - `firebase --version`

## 2) Log in and select your project

- `firebase login`
- From the project root (`myapp/`), set your Firebase project:
  - If you know the Project ID: `firebase use <your-project-id>`
  - Or run `firebase projects:list` then `firebase use <id>`

## 3) Deploy Firestore rules and indexes

- Deploy rules: `firebase deploy --only firestore:rules`
- Deploy indexes: `firebase deploy --only firestore:indexes`

Files used (already present in this repo):
- `firestore.rules`
- `firestore.indexes.json`

Note: Firestore may take 1–10 minutes to build new composite indexes after deploy.

## 4) App Check (development)

App Check is initialized in code using Debug providers for Android/iOS. On first run you’ll see a log line with a token:

- `AppCheck debug token (register this in Firebase Console if enforcement is enabled): <TOKEN>`

If App Check enforcement is enabled in your Firebase Console, add this token:

- Firebase Console → Build → App Check → Your App → Debug tokens → Add token → paste the value from the log

Alternative (CLI):
- Find your Android App ID in `android/app/google-services.json` (field: `mobilesdk_app_id`).
- Generate a debug token with CLI: `firebase appcheck:debug --app <ANDROID_APP_ID>`
- Register the token in Firebase Console → App Check → Debug tokens.

## 5) Validate

- Restart the app and try:
  - Creating a new notebook
  - Viewing the posts feed (the missing index error should disappear after the index finishes building)

If you still see `PERMISSION_DENIED`, double-check:
- You are signed in (user must match rules assumptions)
- Rules/indexes were deployed to the same project the app is using
- App Check debug token is registered if enforcement is ON

## Notes
- For production, switch App Check providers in code to strong providers:
  - Android: `AndroidProvider.playIntegrity`
  - Apple: `AppleProvider.deviceCheck` or `AppleProvider.appAttest`
- If you test on Web, set a reCAPTCHA site key and activate the web provider accordingly.
