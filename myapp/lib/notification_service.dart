import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:audioplayers/audioplayers.dart';

class NotificationService {
  static final NotificationService instance = NotificationService._();
  NotificationService._();

  final FlutterLocalNotificationsPlugin _flnp = FlutterLocalNotificationsPlugin();
  AudioPlayer? _ringtonePlayer;
  
  // Default ringtones
  static const String defaultCallRingtone = 'assets/mp3 file/Lovely-Alarm.mp3';
  static const String defaultMessageSound = 'assets/mp3 file/Iphone-Notification.mp3';

  Future<void> initialize() async {
    if (kIsWeb) return;

    const AndroidInitializationSettings androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    const InitializationSettings initSettings = InitializationSettings(android: androidInit);
    
    await _flnp.initialize(initSettings);

    // Create notification channels
    await _createNotificationChannels();
  }

  Future<void> _createNotificationChannels() async {
    // Message notification channel (high importance, with sound)
    const AndroidNotificationChannel messageChannel = AndroidNotificationChannel(
      'messages',
      'Messages',
      description: 'Message notifications',
      importance: Importance.high,
      playSound: true,
      sound: RawResourceAndroidNotificationSound('notification'),
      enableVibration: true,
    );

    // Call notification channel (max importance, full screen intent, with sound)
    const AndroidNotificationChannel callChannel = AndroidNotificationChannel(
      'calls',
      'Calls',
      description: 'Incoming call notifications',
      importance: Importance.max,
      playSound: true,
      sound: RawResourceAndroidNotificationSound('ringtone'),
      enableVibration: true,
    );

    await _flnp
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(messageChannel);
    
    await _flnp
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(callChannel);
  }



  /// Show message notification with constant ringtone
  Future<void> showMessageNotification({
    required String conversationId,
    required String otherUserId,
    required String title,
    required String body,
  }) async {
    if (kIsWeb) return;

    // Show notification with channel sound
    final payload = 'convId=$conversationId&otherId=$otherUserId';
    await _flnp.show(
      conversationId.hashCode,
      title,
      body,
      const NotificationDetails(
        android: AndroidNotificationDetails(
          'messages',
          'Messages',
          channelDescription: 'Message notifications',
          importance: Importance.high,
          priority: Priority.high,
          playSound: true,
          sound: RawResourceAndroidNotificationSound('notification'),
          enableVibration: true,
        ),
      ),
      payload: payload,
    );
  }

  /// Show incoming call notification with constant ringtone
  Future<void> showCallNotification({
    required String conversationId,
    required String otherUserId,
    required String callerName,
    required String channelName,
    required bool isVideo,
    required String sessionId,
  }) async {
    if (kIsWeb) return;

    // Play call ringtone using audio player for looping
    await _playCallRingtone(defaultCallRingtone);

    // Show full-screen call notification
    final payload = 'call&convId=$conversationId&otherId=$otherUserId&channel=$channelName&video=$isVideo&sessionId=$sessionId';
    
    await _flnp.show(
      sessionId.hashCode,
      '${isVideo ? 'Video' : 'Audio'} Call',
      'Incoming call from $callerName',
      const NotificationDetails(
        android: AndroidNotificationDetails(
          'calls',
          'Calls',
          channelDescription: 'Incoming call notifications',
          importance: Importance.max,
          priority: Priority.max,
          playSound: true,
          sound: RawResourceAndroidNotificationSound('ringtone'),
          enableVibration: true,
          fullScreenIntent: true,
          category: AndroidNotificationCategory.call,
          ongoing: true,
          autoCancel: false,
          actions: [
            AndroidNotificationAction('decline', 'Decline', showsUserInterface: false),
            AndroidNotificationAction('accept', 'Accept', showsUserInterface: true),
          ],
        ),
      ),
      payload: payload,
    );
  }

  /// Play call ringtone (looping) - used when app is in foreground
  Future<void> _playCallRingtone(String assetPath) async {
    try {
      debugPrint('=== Starting call ringtone playback ===');
      debugPrint('Asset path: $assetPath');
      
      await stopCallRingtone(); // Stop any existing player
      
      _ringtonePlayer = AudioPlayer();
      debugPrint('AudioPlayer created');
      
      // Configure for ringtone (loud, looping)
      await _ringtonePlayer!.setAudioContext(AudioContext(
        android: const AudioContextAndroid(
          isSpeakerphoneOn: true,
          contentType: AndroidContentType.music,
          usageType: AndroidUsageType.notificationRingtone,
          audioFocus: AndroidAudioFocus.gain,
        ),
      ));
      debugPrint('Audio context configured');
      
      await _ringtonePlayer!.setReleaseMode(ReleaseMode.loop); // Loop until stopped
      await _ringtonePlayer!.setVolume(1.0);
      debugPrint('Release mode and volume set');
      
      // Strip 'assets/' prefix for AssetSource
      String strippedPath = assetPath.replaceFirst('assets/', '');
      debugPrint('Stripped path for AssetSource: $strippedPath');
      
      // Play the ringtone
      final source = AssetSource(strippedPath);
      await _ringtonePlayer!.play(source);
      debugPrint('=== Call ringtone started playing successfully ===');
      
      // Listen for errors
      _ringtonePlayer!.onPlayerComplete.listen((event) {
        debugPrint('Ringtone playback completed (should be looping)');
      });
    } catch (e, stackTrace) {
      debugPrint('!!! Error playing call ringtone: $e');
      debugPrint('Stack trace: $stackTrace');
      // Try fallback with system sound
      try {
        await stopCallRingtone();
      } catch (_) {}
    }
  }

  /// Play message notification sound once
  Future<void> playMessageSound() async {
    try {
      debugPrint('=== Playing message notification sound ===');
      final player = AudioPlayer();
      
      // Set volume first
      await player.setVolume(0.5);
      debugPrint('Volume set to 0.5');
      
      // Play the sound
      await player.play(AssetSource('mp3 file/Iphone-Notification.mp3'));
      debugPrint('Message sound playing');
      
      // Auto-dispose after completion
      player.onPlayerComplete.first.then((_) {
        debugPrint('Message sound completed, disposing player');
        player.dispose();
      });
    } catch (e) {
      debugPrint('!!! Error playing message notification sound: $e');
    }
  }

  /// Play call ringtone directly (for use in main.dart)
  Future<void> playCallRingtone(String assetPath) async {
    await _playCallRingtone(assetPath);
  }

  /// Stop call ringtone
  Future<void> stopCallRingtone() async {
    try {
      await _ringtonePlayer?.stop();
      await _ringtonePlayer?.dispose();
      _ringtonePlayer = null;
    } catch (e) {
      debugPrint('Error stopping ringtone: $e');
    }
  }

  /// Cancel notification
  Future<void> cancelNotification(int id) async {
    await _flnp.cancel(id);
  }

  /// Cancel all notifications
  Future<void> cancelAllNotifications() async {
    await _flnp.cancelAll();
    await stopCallRingtone();
  }
}
