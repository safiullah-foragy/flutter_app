import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';

import 'background_tasks.dart';

/// ConnectivityService observes network connectivity and
/// - Toggles Firestore network on/off to quiet gRPC errors while offline
/// - Flushes any pending local actions when back online
class ConnectivityService with ChangeNotifier {
  ConnectivityService._();
  static final ConnectivityService instance = ConnectivityService._();

  final ValueNotifier<bool> _isOnline = ValueNotifier<bool>(true);
  ValueListenable<bool> get onlineListenable => _isOnline;
  bool get isOnline => _isOnline.value;

  StreamSubscription<ConnectivityResult>? _sub;
  bool _initialized = false;

  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;

    // Bootstrap with current state
    final current = await Connectivity().checkConnectivity();
    final onlineNow = current != ConnectivityResult.none;
    _isOnline.value = onlineNow;
    await _applyNetworkState(onlineNow);

    _sub = Connectivity().onConnectivityChanged.listen((result) async {
      final online = result != ConnectivityResult.none;
      if (online == _isOnline.value) return; // no change
      _isOnline.value = online;
      notifyListeners();
      await _applyNetworkState(online);
    });
  }

  Future<void> _applyNetworkState(bool online) async {
    try {
      if (online) {
        await FirebaseFirestore.instance.enableNetwork();
        // Best-effort flush of pending actions when we regain connectivity
        unawaited(BackgroundTasks.flushPending());
      } else {
        await FirebaseFirestore.instance.disableNetwork();
      }
    } catch (_) {
      // Method may throw on some platforms; ignore to avoid crashes
    }
  }

  Future<void> disposeService() async {
    await _sub?.cancel();
  }
}

/// Simple thin banner that shows when offline, reminding the user that
/// changes will sync automatically when back online.
class OfflineBanner extends StatelessWidget {
  const OfflineBanner({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: ConnectivityService.instance.onlineListenable,
      builder: (context, isOnline, _) {
        if (isOnline) return const SizedBox.shrink();
        return Material(
          color: Colors.transparent,
          child: Container(
            color: Colors.amber.shade800,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: SafeArea(
              bottom: false,
              child: Row(
                children: const [
                  Icon(Icons.wifi_off, color: Colors.white, size: 16),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'You\'re offline. Changes will sync when back online.',
                      style: TextStyle(color: Colors.white),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
