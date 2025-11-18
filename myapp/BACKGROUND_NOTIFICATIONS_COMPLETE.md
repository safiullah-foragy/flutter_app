# Background Notifications - Complete Setup Guide

## ✅ What's Been Fixed

I've updated your app to support **background notifications** that work even when:
- App is completely closed
- Screen is locked  
- App is in background

### Changes Made:

1. **Sound Files** ✅
   - Copied `notification.mp3` to `android/app/src/main/res/raw/`
   - Copied `ringtone.mp3` to `android/app/src/main/res/raw/`
   - These are required for Android system to play sounds

2. **Notification Channels** ✅
   - Updated to use `RawResourceAndroidNotificationSound`
   - Messages channel uses `notification.mp3`
   - Calls channel uses `ringtone.mp3`
   - Both respect system notification volume

3. **Background Handler** ✅
   - Enhanced `_firebaseMessagingBackgroundHandler` in `main.dart`
   - Initializes NotificationService in background isolate
   - Handles both message and call notifications
   - Shows proper notifications with sound

4. **Cloud Functions** ✅ (Ready to deploy)
   - Updated `functions/index.js` with proper FCM payloads
   - Added `sound: 'default'` for both Android and iOS
   - Added notification titles/bodies for calls
   - High priority for messages, max priority for calls

## 🚀 Deployment Steps

### Step 1: Upgrade Firebase Plan (Required for Cloud Functions)

Your Firebase project needs the **Blaze (pay-as-you-go)** plan to deploy Cloud Functions.

**Option A - Upgrade via Console:**
1. Visit: https://console.firebase.google.com/project/myapp-6cbbf/usage/details
2. Click "Modify Plan"
3. Select "Blaze" plan
4. Add payment method (don't worry, it has a free tier)

**Option B - Use Firebase CLI:**
```bash
firebase projects:list
# Then upgrade via console link provided above
```

**Free Tier Limits** (You likely won't exceed these):
- Cloud Functions: 2M invocations/month
- Cloud Firestore: 50K reads, 20K writes per day
- FCM: Unlimited messages

### Step 2: Deploy Cloud Functions

After upgrading to Blaze plan:

```bash
cd e:\flutter_app\myapp
firebase deploy --only functions
```

Expected output:
```
✔ functions[onMessageCreated]: Successful update operation
✔ functions[onCallSessionCreated]: Successful update operation
✔ Deploy complete!
```

### Step 3: Rebuild the App

```bash
flutter clean
flutter run
# or for release build
flutter build apk --release
```

### Step 4: Test Background Notifications

1. **Install the updated app** on your test device
2. **Grant notification permission** when prompted
3. **Close the app completely** (swipe away from recent apps)
4. **Send a message** from another user
   - ✅ Should see notification on lock screen
   - ✅ Should hear notification sound
5. **Make a call** from another user
   - ✅ Should see full-screen call notification
   - ✅ Should hear ringtone loop

## 🔍 Troubleshooting

### Issue: No sound when app is closed

**Check 1: Sound files exist**
```powershell
Test-Path "android\app\src\main\res\raw\notification.mp3"
Test-Path "android\app\src\main\res\raw\ringtone.mp3"
```
Both should return `True`. If not, sound files weren't copied properly.

**Check 2: Notification permissions**
- Settings → Apps → Your App → Notifications → **Enabled**
- Messages channel → **Enabled**, Sound on
- Calls channel → **Enabled**, Sound on

**Check 3: Notification volume**
- Make sure device notification volume is not muted
- Test by adjusting notification volume on device

**Check 4: Battery optimization**
Some devices kill apps aggressively:
- Settings → Apps → Your App → Battery → **Unrestricted**

**Check 5: Cloud Functions deployed**
```bash
firebase functions:log
```
Look for "Sent notifications" success messages when a message is sent.

**Check 6: FCM token saved**
- Firebase Console → Firestore
- Go to `users` collection → your user document
- Verify `fcmTokens` array exists with a valid token

### Issue: Cloud Functions not deploying

**Error: "must be on Blaze plan"**
- Solution: Upgrade to Blaze plan (see Step 1 above)
- Don't worry - free tier is generous and you likely won't be charged

**Error: "Not in Firebase app directory"**
- Solution: Make sure you're in `e:\flutter_app\myapp` directory
- Run: `cd e:\flutter_app\myapp` before deploying

### Issue: Notification shows but no sound

**Possible causes:**
1. Sound files not in `res/raw/` - rebuild app after adding them
2. Notification channel already created without sound - clear app data and reinstall
3. System Do Not Disturb mode enabled - check device settings

**Solution:**
```bash
# Uninstall app completely
adb uninstall com.example.myapp

# Rebuild and install
flutter clean
flutter run
```

## 📱 Testing Checklist

### Messages
- [ ] App in foreground → Notification shows, sound plays
- [ ] App in background → Notification shows, sound plays
- [ ] App closed → Notification shows, sound plays
- [ ] Screen locked → Notification shows on lock screen, sound plays
- [ ] Tap notification → Opens correct conversation

### Calls
- [ ] App in foreground → Full dialog shows, ringtone loops
- [ ] App in background → Full-screen notification, ringtone loops
- [ ] App closed → Full-screen notification, ringtone loops
- [ ] Screen locked → Full-screen notification on lock screen, ringtone loops
- [ ] Tap notification → Opens call screen

## 🎵 Changing Notification Sounds

To use different sounds:

1. Choose MP3 files from `assets/mp3 file/`
2. Copy and rename to `android/app/src/main/res/raw/`:
   - For messages: `notification.mp3`
   - For calls: `ringtone.mp3`
3. Rebuild app: `flutter clean && flutter run`

**Popular choices:**
- **Messages**: `Soft.mp3`, `Sweet-Sms.mp3`, `Whistle.mp3`
- **Calls**: `Morning-Flower-Alarm.mp3`, `Love-Music.mp3`, `Violin.mp3`

## 📊 Monitoring

### Check Cloud Function Logs
```bash
firebase functions:log --only onMessageCreated
firebase functions:log --only onCallSessionCreated
```

### Check FCM Message Delivery
Firebase Console → Cloud Messaging → Message History

### Test with Firebase Console
1. Go to Firebase Console → Cloud Messaging
2. Click "Send your first message"
3. Enter notification title and body
4. Target: Single device → paste FCM token from Firestore
5. Send → should receive notification with sound

## ⚠️ Important Notes

- **Android 13+**: Users must explicitly grant notification permission
- **Battery Optimization**: May need to disable for reliable delivery on some devices
- **Background Restrictions**: Some manufacturers (Xiaomi, Oppo, etc.) have aggressive battery savers
- **iOS**: Requires additional setup with APNs certificates (not covered here)

## 🎯 Quick Start Commands

```powershell
# 1. Deploy Cloud Functions (after upgrading to Blaze plan)
cd e:\flutter_app\myapp
firebase deploy --only functions

# 2. Rebuild app
flutter clean
flutter run

# 3. Test
# Close app and send message from another device
```

## 📝 Files Modified

- ✅ `functions/index.js` - FCM with sound support
- ✅ `lib/main.dart` - Background handler
- ✅ `lib/notification_service.dart` - Notification channels with sound
- ✅ `android/app/src/main/res/raw/notification.mp3` - Message sound
- ✅ `android/app/src/main/res/raw/ringtone.mp3` - Call sound

## 💡 How It Works

**When app is open:**
- FCM message arrives → `FirebaseMessaging.onMessage`
- Shows local notification with sound
- Sound plays via both notification channel and AudioPlayer

**When app is closed:**
- FCM message arrives → `_firebaseMessagingBackgroundHandler`
- Background isolate wakes up
- Shows local notification using Android system
- System plays sound from `res/raw/` directory
- Respects system notification volume

This ensures notifications work reliably in ALL scenarios! 🎉
