import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart' as firebase_auth;
import 'package:audioplayers/audioplayers.dart';

class NotificationService {
  static final NotificationService instance = NotificationService._();
  NotificationService._();

  final FlutterLocalNotificationsPlugin _flnp = FlutterLocalNotificationsPlugin();
  AudioPlayer? _ringtonePlayer;
  
  // Default ringtones
  static const String defaultCallRingtone = 'assets/mp3 file/lovely-Alarm.mp3';
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
      enableVibration: true,
    );

    // Call notification channel (max importance, full screen intent)
    const AndroidNotificationChannel callChannel = AndroidNotificationChannel(
      'calls',
      'Calls',
      description: 'Incoming call notifications',
      importance: Importance.max,
      playSound: true,
      enableVibration: true,
    );

    await _flnp
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(messageChannel);
    
    await _flnp
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(callChannel);
  }

  /// Get conversation-specific ringtone settings
  Future<Map<String, dynamic>> _getConversationSettings(String conversationId, String otherUserId) async {
    try {
      final uid = firebase_auth.FirebaseAuth.instance.currentUser?.uid;
      if (uid == null) return _getDefaultSettings();

      final doc = await FirebaseFirestore.instance
          .collection('conversations')
          .doc(conversationId)
          .get();

      if (!doc.exists) return _getDefaultSettings();

      final data = doc.data() ?? {};
      final settings = data['settings'] as Map<String, dynamic>? ?? {};
      final userSettings = settings[uid] as Map<String, dynamic>? ?? {};

      return {
        'notification_sound': userSettings['notification_sound'] ?? defaultMessageSound,
        'notification_silent': userSettings['notification_silent'] ?? false,
        'call_ringtone': userSettings['call_ringtone'] ?? defaultCallRingtone,
        'call_ringtone_silent': userSettings['call_ringtone_silent'] ?? false,
      };
    } catch (e) {
      debugPrint('Error loading conversation settings: $e');
      return _getDefaultSettings();
    }
  }

  Map<String, dynamic> _getDefaultSettings() {
    return {
      'notification_sound': defaultMessageSound,
      'notification_silent': false,
      'call_ringtone': defaultCallRingtone,
      'call_ringtone_silent': false,
    };
  }

  /// Show message notification with custom ringtone
  Future<void> showMessageNotification({
    required String conversationId,
    required String otherUserId,
    required String title,
    required String body,
  }) async {
    if (kIsWeb) return;

    final settings = await _getConversationSettings(conversationId, otherUserId);
    final isSilent = settings['notification_silent'] as bool? ?? false;
    final soundPath = settings['notification_sound'] as String? ?? defaultMessageSound;

    // Play custom ringtone if not silent
    if (!isSilent && soundPath.isNotEmpty) {
      await _playNotificationSound(soundPath);
    }

    // Show notification
    final payload = 'convId=$conversationId&otherId=$otherUserId';
    await _flnp.show(
      conversationId.hashCode,
      title,
      body,
      NotificationDetails(
        android: AndroidNotificationDetails(
          'messages',
          'Messages',
          channelDescription: 'Message notifications',
          importance: Importance.high,
          priority: Priority.high,
          playSound: false, // We handle sound ourselves
          enableVibration: !isSilent,
        ),
      ),
      payload: payload,
    );
  }

  /// Show incoming call notification with custom ringtone
  Future<void> showCallNotification({
    required String conversationId,
    required String otherUserId,
    required String callerName,
    required String channelName,
    required bool isVideo,
    required String sessionId,
  }) async {
    if (kIsWeb) return;

    final settings = await _getConversationSettings(conversationId, otherUserId);
    final isSilent = settings['call_ringtone_silent'] as bool? ?? false;
    final ringtonePath = settings['call_ringtone'] as String? ?? defaultCallRingtone;

    // Play custom ringtone if not silent (loop until answered/declined)
    if (!isSilent && ringtonePath.isNotEmpty) {
      await _playCallRingtone(ringtonePath);
    }

    // Show full-screen call notification
    final payload = 'call&convId=$conversationId&otherId=$otherUserId&channel=$channelName&video=$isVideo&sessionId=$sessionId';
    
    await _flnp.show(
      sessionId.hashCode,
      '${isVideo ? 'Video' : 'Audio'} Call',
      'Incoming call from $callerName',
      NotificationDetails(
        android: AndroidNotificationDetails(
          'calls',
          'Calls',
          channelDescription: 'Incoming call notifications',
          importance: Importance.max,
          priority: Priority.max,
          playSound: false, // We handle sound ourselves
          enableVibration: !isSilent,
          fullScreenIntent: true,
          category: AndroidNotificationCategory.call,
          ongoing: true,
          autoCancel: false,
          actions: [
            const AndroidNotificationAction('decline', 'Decline', showsUserInterface: false),
            const AndroidNotificationAction('accept', 'Accept', showsUserInterface: true),
          ],
        ),
      ),
      payload: payload,
    );
  }

  /// Play notification sound once
  Future<void> _playNotificationSound(String assetPath) async {
    try {
      await _ringtonePlayer?.stop();
      await _ringtonePlayer?.dispose();
      
      _ringtonePlayer = AudioPlayer();
      
      // Configure for notification sound
      await _ringtonePlayer!.setAudioContext(AudioContext(
        android: const AudioContextAndroid(
          isSpeakerphoneOn: false,
          contentType: AndroidContentType.sonification,
          usageType: AndroidUsageType.notification,
          audioFocus: AndroidAudioFocus.gainTransientMayDuck,
        ),
      ));
      
      await _ringtonePlayer!.setReleaseMode(ReleaseMode.stop);
      await _ringtonePlayer!.setVolume(1.0);
      
      // Strip 'assets/' prefix for AssetSource
      String strippedPath = assetPath.replaceFirst('assets/', '');
      await _ringtonePlayer!.play(AssetSource(strippedPath));
      
      // Auto-dispose after completion
      _ringtonePlayer!.onPlayerComplete.first.then((_) {
        _ringtonePlayer?.dispose();
        _ringtonePlayer = null;
      });
    } catch (e) {
      debugPrint('Error playing notification sound: $e');
    }
  }

  /// Play call ringtone (looping)
  Future<void> _playCallRingtone(String assetPath) async {
    try {
      await stopCallRingtone(); // Stop any existing player
      
      _ringtonePlayer = AudioPlayer();
      
      // Configure for ringtone (loud, looping)
      await _ringtonePlayer!.setAudioContext(AudioContext(
        android: const AudioContextAndroid(
          isSpeakerphoneOn: true,
          contentType: AndroidContentType.music,
          usageType: AndroidUsageType.notificationRingtone,
          audioFocus: AndroidAudioFocus.gain,
        ),
      ));
      
      await _ringtonePlayer!.setReleaseMode(ReleaseMode.loop); // Loop until stopped
      await _ringtonePlayer!.setVolume(1.0);
      
      // Strip 'assets/' prefix for AssetSource
      String strippedPath = assetPath.replaceFirst('assets/', '');
      debugPrint('Playing call ringtone: $strippedPath');
      await _ringtonePlayer!.play(AssetSource(strippedPath));
      debugPrint('Call ringtone started');
    } catch (e) {
      debugPrint('Error playing call ringtone: $e');
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
