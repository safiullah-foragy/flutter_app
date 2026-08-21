import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'livekit_token_service.dart';

class VirtualMeetingService {
  static final VirtualMeetingService instance = VirtualMeetingService._();
  VirtualMeetingService._();

  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  /// Create a new LiveKit virtual meeting document in call_sessions
  Future<Map<String, dynamic>> createMeeting({
    required String title,
    required String hostId,
    required String hostName,
    String hostAvatar = '',
  }) async {
    final meetingId = 'meet_${DateTime.now().millisecondsSinceEpoch}_${(1000 + (DateTime.now().microsecond % 9000))}';
    final roomName = 'room_$meetingId';

    final meetingData = <String, dynamic>{
      'id': meetingId,
      'channel': roomName,
      'room_name': roomName,
      'title': title.trim().isNotEmpty ? title.trim() : 'Virtual Meeting',
      'caller_id': hostId,
      'callee_id': 'all',
      'host_id': hostId,
      'host_name': hostName,
      'host_avatar': hostAvatar,
      'is_group': true,
      'is_meeting': true,
      'video': true,
      'status': 'active', // 'active' | 'ended'
      'created_at': DateTime.now().millisecondsSinceEpoch,
      'participant_count': 1,
      'removed_participants': <String>[],
    };

    await _firestore.collection('call_sessions').doc(meetingId).set(meetingData);

    return {
      'meetingId': meetingId,
      'roomName': roomName,
      'title': meetingData['title'],
    };
  }

  /// Get meeting metadata
  Future<Map<String, dynamic>?> getMeeting(String meetingIdOrRoom) async {
    try {
      final doc = await _firestore.collection('call_sessions').doc(meetingIdOrRoom).get();
      if (doc.exists && doc.data() != null) {
        return {'docId': doc.id, ...doc.data()!};
      }

      final q = await _firestore
          .collection('call_sessions')
          .where('room_name', isEqualTo: meetingIdOrRoom)
          .limit(1)
          .get();
      if (q.docs.isNotEmpty) {
        return {'docId': q.docs.first.id, ...q.docs.first.data()};
      }

      final q2 = await _firestore
          .collection('call_sessions')
          .where('id', isEqualTo: meetingIdOrRoom)
          .limit(1)
          .get();
      if (q2.docs.isNotEmpty) {
        return {'docId': q2.docs.first.id, ...q2.docs.first.data()};
      }
    } catch (e) {
      debugPrint('Error getting meeting: $e');
    }
    return null;
  }

  /// Invite multiple users to a meeting (Writes ringing call_sessions docs)
  Future<List<Map<String, dynamic>>> inviteUsersToMeeting({
    required String meetingId,
    required String roomName,
    required String title,
    required Map<String, dynamic> hostInfo,
    required List<Map<String, dynamic>> selectedUsers,
  }) async {
    final List<Map<String, dynamic>> sentInvites = [];

    for (final user in selectedUsers) {
      final calleeId = (user['id'] ?? user['uid'] ?? '').toString();
      if (calleeId.isEmpty) continue;

      final inviteId = 'inv_${meetingId}_${calleeId}_${DateTime.now().millisecondsSinceEpoch}';
      final inviteData = <String, dynamic>{
        'id': inviteId,
        'meeting_id': meetingId,
        'channel': roomName,
        'room_name': roomName,
        'title': title.isNotEmpty ? title : 'Virtual Meeting',
        'caller_id': hostInfo['id'] ?? '',
        'host_id': hostInfo['id'] ?? '',
        'host_name': hostInfo['name'] ?? 'Host',
        'host_avatar': hostInfo['avatar'] ?? '',
        'callee_id': calleeId,
        'callee_name': user['name'] ?? 'User',
        'is_group': true,
        'is_meeting': true,
        'video': true,
        'status': 'ringing',
        'created_at': DateTime.now().millisecondsSinceEpoch,
      };

      await _firestore.collection('call_sessions').doc(inviteId).set(inviteData);
      sentInvites.add(inviteData);
    }

    return sentInvites;
  }

  /// Listen to incoming virtual meeting invitations for current user
  Stream<QuerySnapshot<Map<String, dynamic>>> subscribeToIncomingMeetingInvites(String userId) {
    if (userId.isEmpty) {
      return const Stream.empty();
    }
    return _firestore
        .collection('call_sessions')
        .where('callee_id', isEqualTo: userId)
        .where('status', isEqualTo: 'ringing')
        .snapshots();
  }

  /// Accept an incoming meeting invite
  Future<void> acceptMeetingInvite(String docId) async {
    try {
      await _firestore.collection('call_sessions').doc(docId).update({
        'status': 'accepted',
        'accepted_at': DateTime.now().millisecondsSinceEpoch,
      });
    } catch (e) {
      debugPrint('Error accepting meeting invite: $e');
    }
  }

  /// Reject an incoming meeting invite
  Future<void> rejectMeetingInvite(String docId) async {
    try {
      await _firestore.collection('call_sessions').doc(docId).update({
        'status': 'rejected',
        'rejected_at': DateTime.now().millisecondsSinceEpoch,
      });
    } catch (e) {
      debugPrint('Error rejecting meeting invite: $e');
    }
  }

  /// Remove a participant from the meeting in Firestore
  Future<void> removeMemberFromMeeting(String meetingId, String memberId) async {
    try {
      await _firestore.collection('call_sessions').doc(meetingId).update({
        'removed_participants': FieldValue.arrayUnion([memberId]),
      });
    } catch (e) {
      debugPrint('Error removing member from meeting: $e');
    }
  }

  /// End meeting and cancel ringing invites
  Future<void> endMeeting(String meetingId, String roomName) async {
    try {
      if (meetingId.isNotEmpty) {
        await _firestore.collection('call_sessions').doc(meetingId).update({
          'status': 'ended',
          'ended_at': DateTime.now().millisecondsSinceEpoch,
        });
      }

      final invitesSnap = await _firestore
          .collection('call_sessions')
          .where('meeting_id', isEqualTo: meetingId)
          .get();

      for (final doc in invitesSnap.docs) {
        await doc.reference.update({'status': 'ended'});
      }
    } catch (e) {
      debugPrint('Error ending meeting in Firestore: $e');
    }
  }

  /// Fetch LiveKit JWT token for meeting
  Future<String?> getMeetingToken({
    required String roomName,
    required String identity,
    required String userName,
    bool isPublisher = true,
  }) async {
    return await LiveKitTokenService.fetchLiveKitToken(
      roomName: roomName,
      identity: identity,
      isPublisher: isPublisher,
      userName: userName,
    );
  }
}
