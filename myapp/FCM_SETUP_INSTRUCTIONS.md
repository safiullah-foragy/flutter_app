# FCM Background Notifications Setup

## What I've Updated

### 1. Cloud Functions (functions/index.js)
Enhanced to send proper FCM notifications with sound for both messages and calls:
- Added `sound: 'default'` for Android and iOS
- Added notification payload (title/body) for calls
- Added proper APNS configuration for iOS
- Messages now send with high priority and sound
- Calls now send with max priority and sound

### 2. App Code (lib/main.dart)
Updated background message handler to:
- Initialize NotificationService in background
- Handle both message and call_invite types
- Show proper notifications with sound even when app is closed
- Navigate to correct screen when notification is tapped

### 3. What This Fixes
✅ Messages will now play sound even when app is closed/background
✅ Calls will show full-screen notification with ringtone when app is closed
✅ Notifications work when screen is locked
✅ Proper navigation when tapping notifications

## Deployment Steps

### Step 1: Deploy Cloud Functions
```bash
cd e:\flutter_app\myapp
firebase deploy --only functions
```

### Step 2: Test the App
1. Build and install the app on your device:
```bash
flutter build apk
# or
flutter run --release
```

2. Grant notification permissions when prompted

3. Test scenarios:
   - Close the app completely
   - Send a message from another user → Should hear notification sound
   - Make a call from another user → Should see full-screen call notification with ringtone
   - Lock screen and repeat tests → Should still work

## Important Notes

- **Android 13+**: Users must grant notification permission
- **Battery Optimization**: May need to disable battery optimization for the app on some devices
- **FCM Tokens**: The app automatically saves FCM tokens to Firestore when user logs in
- **Ringtone Volume**: Follows system notification volume settings
- **Call Ringtone**: Loops until answered/declined
- **Message Sound**: Plays once per message

## Troubleshooting

If notifications don't work when app is closed:

1. Check FCM token is saved in Firestore:
   - Open Firebase Console → Firestore
   - Go to users collection → your user document
   - Verify `fcmTokens` array exists with valid token

2. Check notification permissions:
   - Android Settings → Apps → Your App → Notifications → Enabled

3. Check battery optimization:
   - Android Settings → Apps → Your App → Battery → Unrestricted

4. Check Cloud Functions logs:
   - Firebase Console → Functions → Logs
   - Look for "Sent notifications" success messages

5. Test with Firebase Console:
   - Go to Firebase Console → Cloud Messaging
   - Send a test notification to your device token
   - If this works, the issue is in the Cloud Function

## Firebase Console Commands

View function logs:
```bash
firebase functions:log
```

Delete and redeploy if needed:
```bash
firebase functions:delete onMessageCreated
firebase functions:delete onCallSessionCreated
firebase deploy --only functions
```
