import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart' as firebase_auth;
import 'package:firebase_messaging/firebase_messaging.dart';

class SelfCheckOverlay extends StatefulWidget {
  const SelfCheckOverlay({super.key});

  @override
  State<SelfCheckOverlay> createState() => _SelfCheckOverlayState();
}

class _SelfCheckOverlayState extends State<SelfCheckOverlay> {
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    // Keep it minimal and semi-transparent; can be hidden or removed later
    return Positioned(
      right: 12,
      bottom: 80,
      child: Opacity(
        opacity: 0.6,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(24),
            onTap: _busy ? null : _runSelfCheck,
            child: CircleAvatar(
              radius: 22,
              backgroundColor: Colors.blue,
              child: _busy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                    )
                  : const Icon(Icons.verified, color: Colors.white),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _runSelfCheck() async {
    setState(() => _busy = true);
    try {
      final u = firebase_auth.FirebaseAuth.instance.currentUser;
      final t = await FirebaseMessaging.instance.getToken();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Token: ${t ?? 'none'}')),
      );

      if (u != null) {
        await FirebaseFirestore.instance
            .collection('self_test')
            .doc(u.uid)
            .collection('pings')
            .add({'ts': DateTime.now().millisecondsSinceEpoch});
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Self-test push requested.')),
        );
      }
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Self-check failed')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}
