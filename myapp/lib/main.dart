import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'agora_call_page.dart';
import 'package:firebase_auth/firebase_auth.dart' as firebase_auth;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:firebase_app_check/firebase_app_check.dart';
import 'firebase_options.dart';
import 'login.dart';
// import 'homepage.dart'; // now hosted inside HomeAndFeedPage
import 'home_and_feed.dart';
import 'supabase.dart' as sb;
import 'messages.dart';
import 'fcm_web.dart';
import 'theme_controller.dart';
import 'background_tasks.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'connectivity_service.dart';
import 'notification_service.dart';

import 'dart:async';
import 'package:flutter/services.dart';
// Self-check overlay removed per request

void main() {
  runZonedGuarded(() async {
    WidgetsFlutterBinding.ensureInitialized();
    // Capture uncaught errors to avoid silent exits on web
    FlutterError.onError = (FlutterErrorDetails details) {
      // Print and keep default behavior
      // ignore: avoid_print
      print('FlutterError: ${details.exceptionAsString()}');
      FlutterError.presentError(details);
    };

    // Initialize Firebase
    // ignore: avoid_print
    print('main: Initializing Firebase');
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
    // ignore: avoid_print
    print('main: Firebase initialized');

    // App Check: activate providers
    // - In development, we use Debug providers so Firestore/Functions work even when enforcement is ON.
    // - For production, switch to Play Integrity (Android) and DeviceCheck/App Attest (Apple), and configure in Firebase Console.
    try {
      await FirebaseAppCheck.instance.activate(
        androidProvider: AndroidProvider.debug,
        appleProvider: AppleProvider.debug,
      );
      // Print a fresh debug token once to help register it in Firebase Console > App Check > Debug tokens
      try {
        final token = await FirebaseAppCheck.instance.getToken(true);
        // ignore: avoid_print
        print('AppCheck debug token (register this in Firebase Console if enforcement is enabled): ${token ?? 'null'}');
      } catch (e) {
        // ignore: avoid_print
        print('AppCheck getToken error: $e');
      }
    } catch (e) {
      // ignore: avoid_print
      print('AppCheck activation error: $e');
    }

    // Ensure auth persistence across app restarts (especially for Web)
    if (kIsWeb) {
      try {
        await firebase_auth.FirebaseAuth.instance.setPersistence(firebase_auth.Persistence.LOCAL);
      } catch (_) {
        // ignore
      }
    }

    if (kIsWeb) {
      try {
        FirebaseFirestore.instance.settings = const Settings(persistenceEnabled: true);
      } catch (_) {
        try {
          FirebaseFirestore.instance.settings = const Settings(persistenceEnabled: false);
        } catch (_) {}
      }
    }

    // Initialize Supabase
    await sb.initializeSupabase();
    // ignore: avoid_print
    print('main: Supabase initialized');

    // Push notifications setup
    if (!kIsWeb) {
      try {
        FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);
        // Initialize notification service
        await NotificationService.instance.initialize();
      } catch (e) {
        debugPrint('Notification init error: $e');
      }

      // Save FCM token ASAP if user is already signed in
      try {
        final u = firebase_auth.FirebaseAuth.instance.currentUser;
        final t = await FirebaseMessaging.instance.getToken();
        if (u != null && t != null) {
          await FirebaseFirestore.instance.collection('users').doc(u.uid).set({
            'fcmTokens': FieldValue.arrayUnion([t])
          }, SetOptions(merge: true));
        }
      } catch (_) {}

      try {
        await _setupPushNotifications();
      } catch (e) {
        debugPrint('Push setup error: $e');
      }
    }

    // Load persisted theme before starting UI
    try {
      await ThemeController.instance.init();
    } catch (e) {
      debugPrint('Theme init error: $e');
    }

    // Start the app UI ASAP
    // ignore: avoid_print
    print('main: calling runApp');
    runApp(const MyApp());

    // Initialize background tasks & connectivity safely after UI start
    try {
      await BackgroundTasks.initialize();
    } catch (_) {}
    try {
      await ConnectivityService.instance.initialize();
    } catch (_) {}

    // Web: request permission and get token with VAPID key (deferred; don't block startup)
    if (kIsWeb) {
      unawaited(Future(() async {
        try {
          await FirebaseMessaging.instance.requestPermission();
        } catch (_) {}
        if (FcmWebConfig.vapidKey.isNotEmpty) {
          try {
            final token = await FirebaseMessaging.instance.getToken(vapidKey: FcmWebConfig.vapidKey);
            final u = firebase_auth.FirebaseAuth.instance.currentUser;
            if (token != null && u != null) {
              await FirebaseFirestore.instance.collection('users').doc(u.uid).set({
                'fcmTokens': FieldValue.arrayUnion([token])
              }, SetOptions(merge: true));
            }
          } catch (_) {}
        }
      }));
    }
  }, (e, st) {
    // ignore: avoid_print
    print('Uncaught zone error: $e\n$st');
  });
}

// Global instances
final FlutterLocalNotificationsPlugin _flnp = FlutterLocalNotificationsPlugin();

@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  try {
    // Ensure Firebase is initialized in background isolate
    await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
    
    // Initialize notification service
    await NotificationService.instance.initialize();
    
    final data = message.data;
    final notification = message.notification;
    final type = data['type']?.toString() ?? 'message';
    
    debugPrint('=== Background FCM Message Received ===');
    debugPrint('Type: $type');
    debugPrint('Data: $data');
    
    if (type == 'call_invite') {
      // Incoming call - show full screen notification with ringtone
      final callerId = data['caller_id']?.toString() ?? '';
      final callerName = data['caller_name']?.toString() ?? 'Unknown';
      final channel = data['call_channel']?.toString() ?? '';
      final isVideo = data['video']?.toString() == '1' || data['video'] == true;
      final sessionId = data['call_session_id']?.toString() ?? '';
      
      debugPrint('Call from: $callerName, channel: $channel');
      
      if (callerId.isNotEmpty && channel.isNotEmpty) {
        await NotificationService.instance.showCallNotification(
          conversationId: '',
          otherUserId: callerId,
          callerName: callerName,
          channelName: channel,
          isVideo: isVideo,
          sessionId: sessionId,
        );
      }
    } else {
      // Regular message - show notification with sound
      final convId = data['conversationId']?.toString() ?? '';
      final otherId = data['otherUserId']?.toString() ?? '';
      final title = notification?.title ?? data['senderName']?.toString() ?? 'New message';
      final body = notification?.body ?? data['text']?.toString() ?? 'You have a new message';
      
      debugPrint('Message from: $title, convId: $convId');
      
      if (convId.isNotEmpty) {
        // Play sound in background
        await NotificationService.instance.playMessageSound();
        
        await NotificationService.instance.showMessageNotification(
          conversationId: convId,
          otherUserId: otherId,
          title: title,
          body: body,
        );
      }
    }
  } catch (e, stack) {
    debugPrint('Error in _firebaseMessagingBackgroundHandler: $e\n$stack');
  }
  debugPrint('=== Background handler complete ===');
}

Future<void> _setupPushNotifications() async {
  // Request permissions (Android 13+ and iOS)
  await FirebaseMessaging.instance.requestPermission();
  // On Android 13+, explicitly request notifications permission via local notifications plugin API
  try {
    await _flnp
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
        ?.requestNotificationsPermission();
  } catch (_) {}

  // Android local notifications init
  const AndroidInitializationSettings androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
  const InitializationSettings initSettings = InitializationSettings(android: androidInit);
  await _flnp.initialize(initSettings,
      onDidReceiveNotificationResponse: (resp) {
    final payload = resp.payload;
    if (payload != null && payload.isNotEmpty) {
      _onNotificationTap(payload);
    }
  });

  // Create a default channel
  const AndroidNotificationChannel channel = AndroidNotificationChannel(
    'messages',
    'Messages',
    description: 'Message notifications',
    importance: Importance.high,
    playSound: true,
    sound: RawResourceAndroidNotificationSound('notification'),
    enableVibration: true,
  );
  await _flnp.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()?.createNotificationChannel(channel);

  // Create calls channel
  const AndroidNotificationChannel callChannel = AndroidNotificationChannel(
    'calls',
    'Calls',
    description: 'Incoming call notifications',
    importance: Importance.max,
    playSound: true,
    sound: RawResourceAndroidNotificationSound('ringtone'),
    enableVibration: true,
  );
  await _flnp.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()?.createNotificationChannel(callChannel);

  // Foreground messages → show local notification with custom ringtone
  FirebaseMessaging.onMessage.listen((RemoteMessage message) async {
    debugPrint('=== Foreground FCM Message Received ===');
    final n = message.notification;
    final data = message.data;
    final type = data['type'] ?? 'message';
    
    debugPrint('Type: $type');
    debugPrint('Notification: ${n?.title} - ${n?.body}');
    debugPrint('Data: $data');
    
    if (type == 'call_invite') {
      // Incoming call - show call notification with ringtone
      final callerId = data['caller_id'] ?? '';
      final callerName = data['caller_name'] ?? n?.title ?? 'Unknown';
      final channel = data['call_channel'] ?? '';
      final isVideo = data['video'] == '1';
      final sessionId = data['call_session_id'] ?? '';
      
      debugPrint('Call from: $callerName');
      
      if (callerId.isNotEmpty && channel.isNotEmpty) {
        await NotificationService.instance.showCallNotification(
          conversationId: '',
          otherUserId: callerId,
          callerName: callerName,
          channelName: channel,
          isVideo: isVideo,
          sessionId: sessionId,
        );
      }
    } else {
      // Regular message - show message notification with sound
      final convId = data['conversationId'] ?? '';
      final otherId = data['otherUserId'] ?? '';
      
      debugPrint('Message - convId: $convId, otherId: $otherId');
      
      if (convId.isNotEmpty && n != null) {
        // Play notification sound
        debugPrint('Playing message notification sound...');
        await NotificationService.instance.playMessageSound();
        
        await NotificationService.instance.showMessageNotification(
          conversationId: convId,
          otherUserId: otherId,
          title: n.title ?? 'New message',
          body: n.body ?? '',
        );
        debugPrint('Message notification shown');
      }
    }
    debugPrint('=== Foreground handler complete ===');
  });

  // Taps: app in background
  FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage message) async {
    final data = message.data;
    final type = data['type'] ?? 'message';
    
    if (type == 'call_invite') {
      // Call notification tapped
      final channel = data['call_channel'] ?? '';
      final callerId = data['caller_id'] ?? '';
      final isVideo = data['video'] == '1';
      final sessionId = data['call_session_id'] ?? '';
      
      if (channel.isNotEmpty && callerId.isNotEmpty) {
        if (sessionId.isNotEmpty) {
          try {
            final doc = await FirebaseFirestore.instance.collection('call_sessions').doc(sessionId).get();
            if (!doc.exists) return;
            final status = doc.data()?['status'];
            if (status != 'ringing' && status != 'accepted') return;
            if (status == 'ringing') {
              await doc.reference.update({
                'status': 'accepted',
                'accepted_at': DateTime.now().millisecondsSinceEpoch,
              });
            }
          } catch (_) {}
        }
        final ctx = _MyAppNavigator.navigatorKey.currentContext;
        if (ctx != null) {
          Navigator.of(ctx).push(
            CallPage.route(
              channelName: channel,
              video: isVideo,
              remoteUserId: callerId,
              callSessionId: sessionId,
              isCaller: false,
            ),
          );
          _clearBadgeNative();
        }
      }
    } else {
      // Message notification tapped
      final convId = data['conversationId'];
      final otherId = data['otherUserId'] ?? '';
      if (convId != null) {
        _navigateToConversation(convId, otherId);
        _clearBadgeNative();
      }
    }
  });

  // Taps: app terminated
  final initialMessage = await FirebaseMessaging.instance.getInitialMessage();
  if (initialMessage != null) {
    final data = initialMessage.data;
    final type = data['type'] ?? 'message';
    
    if (type == 'call_invite') {
      // Call notification tapped
      final channel = data['call_channel'] ?? '';
      final callerId = data['caller_id'] ?? '';
      final isVideo = data['video'] == '1';
      final sessionId = data['call_session_id'] ?? '';
      
      if (channel.isNotEmpty && callerId.isNotEmpty) {
        WidgetsBinding.instance.addPostFrameCallback((_) async {
          if (sessionId.isNotEmpty) {
            try {
              final doc = await FirebaseFirestore.instance.collection('call_sessions').doc(sessionId).get();
              if (!doc.exists) return;
              final status = doc.data()?['status'];
              if (status != 'ringing' && status != 'accepted') return;
              if (status == 'ringing') {
                await doc.reference.update({
                  'status': 'accepted',
                  'accepted_at': DateTime.now().millisecondsSinceEpoch,
                });
              }
            } catch (_) {}
          }
          final ctx = _MyAppNavigator.navigatorKey.currentContext;
          if (ctx != null) {
            Navigator.of(ctx).push(
              CallPage.route(
                channelName: channel,
                video: isVideo,
                remoteUserId: callerId,
                callSessionId: sessionId,
                isCaller: false,
              ),
            );
            _clearBadgeNative();
          }
        });
      }
    } else {
      // Message notification tapped
      final convId = data['conversationId'];
      final otherId = data['otherUserId'] ?? '';
      if (convId != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _navigateToConversation(convId, otherId);
          _clearBadgeNative();
        });
      }
    }
  }
}

void _onNotificationTap(String payload) async {
  if (payload.isEmpty) return;
  // Parse payload
  try {
    // Check if it's a call notification
    if (payload.startsWith('call&')) {
      final m = Uri.splitQueryString(payload.substring(5));
      final channel = m['channel'] ?? '';
      final otherId = m['otherId'] ?? '';
      final isVideo = m['video'] == 'true';
      final sessionId = m['sessionId'] ?? '';
      
      if (channel.isNotEmpty && otherId.isNotEmpty) {
        if (sessionId.isNotEmpty) {
          try {
            final doc = await FirebaseFirestore.instance.collection('call_sessions').doc(sessionId).get();
            if (!doc.exists) return;
            final status = doc.data()?['status'];
            if (status != 'ringing' && status != 'accepted') return;
            if (status == 'ringing') {
              await doc.reference.update({
                'status': 'accepted',
                'accepted_at': DateTime.now().millisecondsSinceEpoch,
              });
            }
          } catch (_) {}
        }
        final ctx = _MyAppNavigator.navigatorKey.currentContext;
        if (ctx != null) {
          Navigator.of(ctx).push(
            CallPage.route(
              channelName: channel,
              video: isVideo,
              remoteUserId: otherId,
              callSessionId: sessionId,
              isCaller: false,
            ),
          );
          _clearBadgeNative();
        }
      }
      return;
    }
    
    // Regular message notification
    final m = Uri.splitQueryString(payload);
    final convId = m['convId'] ?? '';
    final otherId = m['otherId'] ?? '';
    if (convId.isNotEmpty) {
      _navigateToConversation(convId, otherId);
      _clearBadgeNative();
    }
  } catch (_) {
    // Fallback: treat payload as conversationId only
    _navigateToConversation(payload, '');
  }
}

void _navigateToConversation(String conversationId, String otherUserId) {
  final ctx = _MyAppNavigator.navigatorKey.currentContext;
  if (ctx == null) return;
  Future<void> doNav(String resolvedOther) async {
    Navigator.of(ctx).restorablePush(
      ChatPage.restorableRoute,
      arguments: {
        'conversationId': conversationId,
        'otherUserId': resolvedOther,
      },
    );
  }

  // Ensure user is signed-in before navigating (especially on cold-start from notif)
  final user = firebase_auth.FirebaseAuth.instance.currentUser;
  if (user == null) {
    firebase_auth.FirebaseAuth.instance.authStateChanges().firstWhere((u) => u != null).then((_) {
      _navigateToConversation(conversationId, otherUserId);
    });
    return;
  }

  if (otherUserId.isEmpty) {
    // Try to resolve other user id from Firestore before navigating
    FirebaseFirestore.instance.collection('conversations').doc(conversationId).get().then((doc) {
      final me = firebase_auth.FirebaseAuth.instance.currentUser?.uid;
      String resolved = otherUserId;
      if (doc.exists) {
        final data = doc.data();
        final parts = List<String>.from(data?['participants'] ?? <String>[]);
        if (me != null) {
          resolved = parts.firstWhere((p) => p != me, orElse: () => otherUserId);
        }
      }
      doNav(resolved.isNotEmpty ? resolved : otherUserId);
    }).catchError((_) {
      doNav(otherUserId);
    });
  } else {
    doNav(otherUserId);
  }
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    // ignore: avoid_print
    print('MyApp.build');
    return AnimatedBuilder(
      animation: ThemeController.instance,
      builder: (context, _) {
        return MaterialApp(
          debugShowCheckedModeBanner: false,
          title: 'MyApp',
          restorationScopeId: 'app',
          themeMode: ThemeController.instance.mode,
          theme: ThemeData(
            colorScheme: ColorScheme.fromSeed(seedColor: ThemeController.instance.seedColor, brightness: Brightness.light),
            useMaterial3: true,
          ),
          darkTheme: ThemeData(
            colorScheme: ColorScheme.fromSeed(seedColor: ThemeController.instance.seedColor, brightness: Brightness.dark),
            useMaterial3: true,
          ),
          navigatorKey: _MyAppNavigator.navigatorKey,
          builder: (context, child) {
            // Constrain app to phone dimensions on web/desktop
            Widget content = child ?? const SizedBox.shrink();
            
            if (kIsWeb || (MediaQuery.of(context).size.width > 600)) {
              content = Center(
                child: Container(
                  constraints: const BoxConstraints(
                    maxWidth: 430, // iPhone 14 Pro Max width
                    maxHeight: 932, // iPhone 14 Pro Max height
                  ),
                  decoration: BoxDecoration(
                    border: Border.all(color: Colors.grey.shade300, width: 1),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.1),
                        blurRadius: 20,
                        spreadRadius: 5,
                      ),
                    ],
                  ),
                  child: ClipRect(
                    child: content,
                  ),
                ),
              );
            }
            
            return Stack(
              children: [
                content,
                const Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: OfflineBanner(),
                ),
              ],
            );
          },
          home: const MessagingInitializer(child: AuthGate()),
        );
      },
    );
  }
}

class _MyAppNavigator {
  static final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();
}

class MessagingInitializer extends StatefulWidget {
  final Widget child;
  const MessagingInitializer({super.key, required this.child});

  @override
  State<MessagingInitializer> createState() => _MessagingInitializerState();
}

class _MessagingInitializerState extends State<MessagingInitializer> with WidgetsBindingObserver {
  static const MethodChannel _navChannel = MethodChannel('com.example.myapp/navigation');
  static const MethodChannel _appChannel = MethodChannel('com.example.myapp/app');
  StreamSubscription<firebase_auth.User?>? _authSub;
  StreamSubscription<QuerySnapshot>? _callSessionSub;
  Timer? _presenceTimer;
  
  @override
  void initState() {
    super.initState();
    // Observe app lifecycle to start/stop Android background watcher
    WidgetsBinding.instance.addObserver(this);
    // On web, messaging may be disabled or service worker missing; wrap to avoid crashes
    _ensureFcmTokenSaved();
    try {
      FirebaseMessaging.instance.onTokenRefresh.listen((token) => _saveFcmToken(token));
    } catch (_) {}
    // Start periodic presence update (every 2 minutes to keep online status fresh)
    _startPresenceHeartbeat();
    final initialU = firebase_auth.FirebaseAuth.instance.currentUser;
    if (initialU != null) {
      _attachCallSessionListener(initialU.uid);
      NotificationService.instance.startRealtimeNotificationListener(initialU.uid);
    }
    // Ensure token is saved as soon as user signs in
    _authSub = firebase_auth.FirebaseAuth.instance.authStateChanges().listen((u) async {
      final prefs = await SharedPreferences.getInstance();
      final lastUid = prefs.getString('last_topic_uid');
      if (u != null) {
        // Save token and subscribe to a per-user topic for robust delivery
        await _ensureFcmTokenSaved();
        final topic = 'user_${u.uid}';
        try { await FirebaseMessaging.instance.subscribeToTopic(topic); } catch (_) {}
        await prefs.setString('last_topic_uid', u.uid);
        _attachCallSessionListener(u.uid);
        // Start real-time Firestore notification alerts for Android device
        NotificationService.instance.startRealtimeNotificationListener(u.uid);
        // Start background message watcher for closed/background notifications
        if (!kIsWeb) _startMessageWatcher();
        // Set user as online when authenticated
        _updateUserPresence(isOnline: true);
      } else {
        // On sign out, best-effort unsubscribe from previous topic
        if (lastUid != null && lastUid.isNotEmpty) {
          try { await FirebaseMessaging.instance.unsubscribeFromTopic('user_$lastUid'); } catch (_) {}
          await prefs.remove('last_topic_uid');
        }
        // Stop background watcher if running
        _stopMessageWatcher();
        _detachCallSessionListener();
        NotificationService.instance.stopRealtimeNotificationListener();
        // Set user as offline when signed out
        _updateUserPresence(isOnline: false);
      }
    });
    // Listen for navigation requests from Android native (notification taps)
    _navChannel.setMethodCallHandler((call) async {
      if (call.method == 'openConversation') {
        final args = Map<String, dynamic>.from(call.arguments as Map);
        final convId = args['conversationId'] as String?;
        if (convId != null && convId.isNotEmpty) {
          _navigateToConversation(convId, '');
          _clearBadgeNative();
        }
      } else if (call.method == 'openCall') {
        final args = Map<String, dynamic>.from(call.arguments as Map);
        _handleOpenCall(args);
      }
    });

    // Check if app was launched via call/conversation notification
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkPendingNativeNavigation();
    });
  }

  void _handleOpenCall(Map<String, dynamic> args) {
    final channel = args['channel'] as String?;
    final callerId = args['callerId'] as String?;
    final video = (args['video'] as bool?) ?? false;
    final sessionId = args['sessionId'] as String?;
    if (channel != null && channel.isNotEmpty && callerId != null && callerId.isNotEmpty) {
      try { NotificationService.instance.stopCallRingtone(); } catch (_) {}
      
      int retryCount = 0;
      void pushCall() {
        final nav = _MyAppNavigator.navigatorKey.currentState;
        if (nav != null) {
          nav.push(
            CallPage.route(
              channelName: channel,
              video: video,
              remoteUserId: callerId,
              callSessionId: (sessionId != null && sessionId.isNotEmpty) ? sessionId : null,
              isCaller: false,
            ),
          );
        } else if (retryCount < 25) {
          retryCount++;
          // If navigator is still initializing on cold boot, retry every 120ms
          Future.delayed(const Duration(milliseconds: 120), pushCall);
        }
      }

      pushCall();
    }
  }

  Future<void> _checkPendingNativeNavigation() async {
    try {
      final callData = await _navChannel.invokeMethod('getPendingCall');
      if (callData is Map) {
        _handleOpenCall(Map<String, dynamic>.from(callData));
      }
    } catch (_) {}

    try {
      final convId = await _navChannel.invokeMethod('getPendingConv');
      if (convId is String && convId.isNotEmpty) {
        _navigateToConversation(convId, '');
        _clearBadgeNative();
      }
    } catch (_) {}
  }

  Future<void> _ensureFcmTokenSaved() async {
    try {
      final token = await FirebaseMessaging.instance.getToken();
      if (token != null) await _saveFcmToken(token);
    } catch (_) {}
  }

  Future<void> _saveFcmToken(String token) async {
    final user = firebase_auth.FirebaseAuth.instance.currentUser;
    if (user == null) return;
    await FirebaseFirestore.instance.collection('users').doc(user.uid).set({
      'fcmTokens': FieldValue.arrayUnion([token]),
    }, SetOptions(merge: true));
  }

  @override
  void dispose() {
    _authSub?.cancel();
    _detachCallSessionListener();
    _presenceTimer?.cancel();
    _updateUserPresence(isOnline: false);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void _startPresenceHeartbeat() {
    _presenceTimer?.cancel();
    // Update presence every 2 minutes to keep online status fresh
    _presenceTimer = Timer.periodic(const Duration(minutes: 2), (_) {
      _updateUserPresence(isOnline: true);
    });
  }

  // Start the native foreground service when app is backgrounded; stop when resumed
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!kIsWeb) {
      if (state == AppLifecycleState.paused || state == AppLifecycleState.inactive || state == AppLifecycleState.detached) {
        _startMessageWatcher();
        _updateUserPresence(isOnline: false);
      } else if (state == AppLifecycleState.resumed) {
        _startMessageWatcher();
        _updateUserPresence(isOnline: true);
      }
    } else {
      // Web: update presence on lifecycle changes
      if (state == AppLifecycleState.paused || state == AppLifecycleState.inactive || state == AppLifecycleState.detached) {
        _updateUserPresence(isOnline: false);
      } else if (state == AppLifecycleState.resumed) {
        _updateUserPresence(isOnline: true);
      }
    }
  }

  Future<void> _updateUserPresence({required bool isOnline}) async {
    try {
      final uid = firebase_auth.FirebaseAuth.instance.currentUser?.uid;
      if (uid == null) return;
      
      await FirebaseFirestore.instance.collection('users').doc(uid).update({
        'is_online': isOnline,
        'last_active': DateTime.now().millisecondsSinceEpoch,
      });
      debugPrint('User presence updated: ${isOnline ? "online" : "offline"}');
    } catch (e) {
      debugPrint('Error updating user presence: $e');
    }
  }

  Future<void> _startMessageWatcher() async {
    try {
      await _appChannel.invokeMethod('startMessageWatcher');
    } catch (_) {}
  }

  Future<void> _stopMessageWatcher() async {
    try {
      await _appChannel.invokeMethod('stopMessageWatcher');
    } catch (_) {}
  }

  void _attachCallSessionListener(String uid) {
    debugPrint('=== Attaching call session listener for uid: $uid ===');
    _callSessionSub?.cancel();
    _callSessionSub = FirebaseFirestore.instance
        .collection('call_sessions')
        .where('callee_id', isEqualTo: uid)
        .snapshots()
        .listen((snap) async {
      debugPrint('Call session snapshot received: ${snap.docs.length} docs for callee $uid');
      if (snap.docs.isEmpty) {
        try { NotificationService.instance.stopCallRingtone(); } catch (_) {}
        return;
      }

      bool hasRinging = false;
      for (final doc in snap.docs) {
        final data = doc.data();
        final status = data['status'] as String? ?? '';
        if (status != 'ringing') continue;

        final channel = data['channel'] as String? ?? '';
        final callerId = data['caller_id'] as String? ?? '';
        final video = data['video'] == true;

        if (channel.isEmpty || callerId.isEmpty) continue;
        hasRinging = true;
        debugPrint('Incoming call ringing: caller=$callerId, channel=$channel, video=$video');

        // Play receiver ringtone
        try {
          await NotificationService.instance.playCallRingtone(NotificationService.defaultCallRingtone);
        } catch (_) {}

        if (kIsWeb) {
          // On Web, if user is active, navigate directly or prompt
        }
        break;
      }

      if (!hasRinging) {
        try { NotificationService.instance.stopCallRingtone(); } catch (_) {}
      }
    }, onError: (error) {
      debugPrint('Call session listener error: $error');
    });
  }

  void _detachCallSessionListener() {
    _callSessionSub?.cancel();
    _callSessionSub = null;
    try { NotificationService.instance.stopCallRingtone(); } catch (_) {}
  }


  Future<String?> _findConversationWith(String otherId) async {
    final uid = firebase_auth.FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return null;
    try {
      final snap = await FirebaseFirestore.instance.collection('conversations').where('participants', arrayContains: uid).get();
      for (final d in snap.docs) {
        final parts = List<String>.from(d.data()['participants'] ?? []);
        if (parts.contains(otherId)) return d.id;
      }
    } catch (_) {}
    return null;
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class AuthGate extends StatelessWidget {
  const AuthGate({super.key});
  static bool _didHandleInitialLink = false;

  @override
  Widget build(BuildContext context) {
    // ignore: avoid_print
    print('AuthGate.build');
    return StreamBuilder<firebase_auth.User?>(
      stream: firebase_auth.FirebaseAuth.instance.authStateChanges(),
      builder: (context, snapshot) {
        // ignore: avoid_print
        print('AuthGate: connectionState=${snapshot.connectionState}, hasData=${snapshot.data != null}');
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        final user = snapshot.data;
        if (user != null) {
          // ignore: avoid_print
          print('AuthGate: user logged in');
          // User is signed in; keep them logged in until explicit sign out
          // Handle web deep link: #conv=conversationId
          if (kIsWeb && !_didHandleInitialLink) {
            _didHandleInitialLink = true;
            final frag = Uri.base.fragment; // e.g., conv=abc
            if (frag.contains('conv=')) {
              final convId = Uri.splitQueryString(frag)['conv'];
              if (convId != null && convId.isNotEmpty) {
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  _navigateToConversation(convId, '');
                });
              }
            }
          }
          return const HomeAndFeedPage();
        }
        // ignore: avoid_print
        print('AuthGate: no user, showing LoginPage');
        // Not signed in
        return const LoginPage();
      },
    );
  }
}

Future<void> _clearBadgeNative() async {
  try {
    const MethodChannel('com.example.myapp/app').invokeMethod('clearBadge');
  } catch (_) {}
}