# Setup Notification Sounds for Background Notifications

## Problem
The notification ringtone doesn't play when the app is in the background because Android requires sound files to be in the `res/raw` directory, not in Flutter assets.

## Solution

### Step 1: Copy Sound Files to Android Resources

Run these commands to copy the sound files:

```powershell
# Create raw directory if it doesn't exist
New-Item -ItemType Directory -Path "android\app\src\main\res\raw" -Force

# Copy notification sound (shorter sound for messages)
Copy-Item "assets\mp3 file\Iphone-Notification.mp3" "android\app\src\main\res\raw\notification.mp3"

# Copy ringtone sound (longer sound for calls)
Copy-Item "assets\mp3 file\Lovely-Alarm.mp3" "android\app\src\main\res\raw\ringtone.mp3"
```

Or manually:
1. Navigate to `android\app\src\main\res\raw\` (create the `raw` folder if it doesn't exist)
2. Copy `Iphone-Notification.mp3` from `assets\mp3 file\` and rename it to `notification.mp3`
3. Copy `Lovely-Alarm.mp3` from `assets\mp3 file\` and rename it to `ringtone.mp3`

**Important**: 
- File names MUST be lowercase with no spaces
- Files must be in the `res/raw` directory, NOT in assets
- Sound files should be MP3 format

### Step 2: Rebuild the App

After copying the files, rebuild the app:

```bash
flutter clean
flutter build apk
# or
flutter run
```

### Step 3: Test

1. **Close the app completely** (swipe it away from recent apps)
2. Send a message from another device
3. **You should hear the notification sound**
4. Make a call from another device
5. **You should see full-screen call notification with ringtone**

## How It Works

### Message Notifications
- Uses Android notification channel with `RawResourceAndroidNotificationSound('notification')`
- Plays `notification.mp3` from `res/raw/notification.mp3`
- Respects system notification volume
- Works when app is closed, background, or locked

### Call Notifications
- Uses Android notification channel with `RawResourceAndroidNotificationSound('ringtone')`
- Also plays via AudioPlayer for looping (when app is open)
- Shows full-screen intent notification
- Works when app is closed, background, or locked

## Troubleshooting

### Sound doesn't play when app is closed:

1. **Check files exist**:
   ```
   android/app/src/main/res/raw/notification.mp3
   android/app/src/main/res/raw/ringtone.mp3
   ```

2. **Check file names**: Must be lowercase, no spaces, no special characters

3. **Rebuild after adding files**:
   ```bash
   flutter clean
   flutter build apk
   ```

4. **Check notification settings**:
   - Android Settings → Apps → Your App → Notifications → Enabled
   - Messages channel → Sound enabled
   - Calls channel → Sound enabled

5. **Check volume**: Make sure notification volume is not muted

6. **Check battery optimization**: Disable battery optimization for your app

### Alternative Sound Files

You can replace with any other MP3 files from your `assets/mp3 file/` folder:

For messages (short sound):
- `Iphone-Notification.mp3` (current)
- `Soft.mp3`
- `Sweet-Sms.mp3`
- `Whistle.mp3`

For calls (longer ringtone):
- `Lovely-Alarm.mp3` (current)
- `Morning-Flower-Alarm.mp3`
- `Love-Music.mp3`
- `Violin.mp3`

Just copy the file and rename it to `notification.mp3` or `ringtone.mp3` in the `res/raw` folder.

## Deploy Cloud Functions

Don't forget to deploy the updated Cloud Functions:

```bash
cd e:\flutter_app\myapp
firebase deploy --only functions
```

This will enable FCM to send notifications with the proper payload.
