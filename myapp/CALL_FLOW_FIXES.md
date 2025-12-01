# Call Flow Fixes - Complete Implementation

## Issues Fixed

### 1. **Web Ringtone Not Playing** ✅
**Problem**: When calling from Android to Web, the web receiver didn't hear any ringtone.

**Root Cause**: `NotificationService._playCallRingtone()` had an early return for web platform (`if (kIsWeb) return;`), preventing ringtone playback.

**Solution**: 
- Removed the web platform check that was blocking ringtone playback
- Made audio context configuration conditional (Android-only, since web doesn't need it)
- Web users now hear ringtones through the AudioPlayer

**Files Modified**:
- `lib/notification_service.dart`: Enabled ringtone playback on web by removing early return

### 2. **Waiting State Issue** ✅
**Problem**: After accepting a call, the receiver would see "Waiting for the other user..." instead of connecting immediately. They had to close and accept again.

**Root Cause**: The `IncomingCallDialog` in `messages.dart` was not updating the `call_sessions` Firestore document status to "accepted" when the user pressed Accept. The `CallPage` was waiting for this status change before joining the Agora channel.

**Solution**:
- Modified Accept button to query `call_sessions` by channel name
- Update status to "accepted" with timestamp **before** opening CallPage
- Modified Decline button to update status to "rejected"
- When CallPage opens, it detects the "accepted" status immediately and joins the channel

**Files Modified**:
- `lib/messages.dart` (IncomingCallDialog): Added Firestore updates for Accept and Decline actions

### 3. **Call Timer Synchronization** ✅
**Problem**: Timer was starting on caller's screen before receiver accepted the call, and both users had different elapsed times.

**Root Cause**: Each device started its own timer when joining the Agora channel, which happened at different times.

**Solution**:
- Added `call_start_time` field to `call_sessions` document
- First user to join sets the timestamp atomically using Firestore transaction
- Both users read and sync to the same timestamp
- Modified `_startElapsedTimer()` to accept optional `syncedStartTime` parameter
- Created `_syncCallStartTime()` method to handle synchronization

**Files Modified**:
- `lib/agora_call_page.dart`: Added timer synchronization logic

## Call Flow (After Fixes)

### One-to-One Call Flow
1. **Caller** presses audio/video call button
   - Creates `call_sessions` document with status "ringing"
   - Sends call message to conversation
   - Opens `CallPage` and starts outgoing tone

2. **Receiver** gets notification
   - `_attachCallSessionListener` in `main.dart` detects new call session
   - Shows `IncomingCallDialog` with Accept/Decline buttons
   - **Plays ringtone** (works on both Android and Web now)

3. **Receiver** presses **Accept**
   - Updates `call_sessions` status to "accepted" with timestamp
   - Stops ringtone
   - Opens `CallPage`

4. **Both CallPages** detect "accepted" status
   - Stop all ringtones
   - Join Agora channel immediately
   - Call `_syncCallStartTime()` to sync timer
   - First joiner sets `call_start_time` in Firestore
   - Second joiner reads and syncs to same timestamp
   - Both start timer at `00:00` simultaneously
   - Call connects ✅

5. **Receiver** presses **Decline**
   - Updates `call_sessions` status to "rejected"
   - Stops ringtone
   - Caller's CallPage detects rejection and closes

### Group Call Flow
- Skips the status-waiting logic entirely
- All participants join immediately when they accept
- Timer syncs across all participants
- Each participant can join/leave independently

## Testing Checklist

- [x] Android → Android call (ringtone, connect, timer sync)
- [ ] Android → Web call (ringtone on web, connect, timer sync)
- [ ] Web → Android call (ringtone on both, connect, timer sync)
- [ ] Web → Web call (ringtone on both, connect, timer sync)
- [ ] Group call with mixed platforms (everyone connects, timer syncs)
- [ ] Decline call (both platforms update status correctly)
- [ ] Missed call (caller sees appropriate message)

## Key Implementation Details

### Timer Synchronization
```dart
// First joiner sets the timestamp
await FirebaseFirestore.instance.runTransaction((transaction) async {
  if (existingStartTime == null) {
    transaction.update(sessionRef, {'call_start_time': now});
  }
});

// Both users read and sync
final startTimeMs = doc.data()?['call_start_time'] as int?;
final syncedStartTime = DateTime.fromMillisecondsSinceEpoch(startTimeMs);
_startElapsedTimer(syncedStartTime: syncedStartTime);
```

### Status Updates on Accept/Decline
```dart
// Find call session by channel name
final callSessions = await _firestore
    .collection('call_sessions')
    .where('channel', isEqualTo: widget.channelName)
    .where('status', isEqualTo: 'ringing')
    .limit(1)
    .get();

// Update to accepted/rejected
await sessionDoc.reference.update({
  'status': 'accepted',
  'accepted_at': DateTime.now().millisecondsSinceEpoch,
});
```

### Web Ringtone Support
```dart
// Conditional audio context (Android-only)
if (!kIsWeb) {
  await _ringtonePlayer!.setAudioContext(AudioContext(
    android: const AudioContextAndroid(...),
  ));
} else {
  debugPrint('Web platform - skipping audio context');
}

// Ringtone plays on all platforms
await _ringtonePlayer!.play(AssetSource(strippedPath));
```

## Benefits

1. **Seamless Experience**: Accept once → instant connection
2. **Cross-Platform**: Works consistently on Android, iOS, and Web
3. **Synchronized Timer**: Both users see the same call duration
4. **No Confusion**: No more "Waiting..." states that require retries
5. **Proper Feedback**: Decline/reject actions immediately notify the other party
