const functions = require('firebase-functions');
const admin = require('firebase-admin');

try { admin.app(); } catch (e) { admin.initializeApp(); }

// Sends a push notification to the other participant when a new message is created
exports.onMessageCreated = functions.firestore
  .document('conversations/{conversationId}/messages/{messageId}')
  .onCreate(async (snap, context) => {
    const data = snap.data() || {};
    const conversationId = context.params.conversationId;
    const senderId = data.sender_id;
    const text = data.text || '';

    // Load conversation to find participants
    const convRef = admin.firestore().collection('conversations').doc(conversationId);
    const convSnap = await convRef.get();
    if (!convSnap.exists) return null;
    const conv = convSnap.data() || {};
    const participants = conv.participants || [];
    const targetIds = participants.filter((p) => p && p !== senderId);
    if (targetIds.length === 0) return null;

    // Get sender name (optional)
    let senderName = 'New message';
    try {
      const senderSnap = await admin.firestore().collection('users').doc(senderId).get();
      if (senderSnap.exists) {
        const u = senderSnap.data() || {};
        if (u.name) senderName = u.name;
      }
    } catch (_) {}

    // Collect target tokens
    const tokenSet = new Set();
    for (const uid of targetIds) {
      const uSnap = await admin.firestore().collection('users').doc(uid).get();
      if (uSnap.exists) {
        const u = uSnap.data() || {};
        const tokens = u.fcmTokens || [];
        for (const t of tokens) tokenSet.add(t);
      }
    }
    const tokens = Array.from(tokenSet);
    if (tokens.length === 0) return null;

    const payload = {
      notification: {
        title: senderName,
        body: text && text.length > 0 ? text : 'Sent you a message',
      },
      data: {
        conversationId: conversationId,
        otherUserId: senderId,
      },
    };

    try {
      const response = await admin.messaging().sendEachForMulticast({
        tokens,
        notification: payload.notification,
        data: payload.data,
      });
      console.log('Sent notifications:', response.successCount);
    } catch (e) {
      console.error('Error sending notifications:', e);
    }

    return null;
  });
