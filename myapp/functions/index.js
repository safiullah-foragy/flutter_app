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

// Create a notification when a new comment is added to a post
exports.onPostCommentCreated = functions.firestore
  .document('posts/{postId}/comments/{commentId}')
  .onCreate(async (snap, context) => {
    const data = snap.data() || {};
    const postId = context.params.postId;
    const from = data.user_id;
    if (!from) return null;

    try {
      const postSnap = await admin.firestore().collection('posts').doc(postId).get();
      if (!postSnap.exists) return null;
      const post = postSnap.data() || {};
      const to = post.user_id;
      if (!to || to === from) return null; // skip self

      // fromName best-effort lookup
      let fromName = '';
      try {
        const userSnap = await admin.firestore().collection('users').doc(from).get();
        if (userSnap.exists) {
          const u = userSnap.data() || {};
          fromName = u.name || u.displayName || '';
        }
      } catch (_) {}

      await admin.firestore().collection('notifications').add({
        to,
        type: 'comment',
        from,
        fromName,
        postId,
        timestamp: Date.now(),
        read: false,
      });
    } catch (e) {
      console.error('onPostCommentCreated error', e);
    }
    return null;
  });

// Create a notification when a like doc is created (first-like)
exports.onPostLikeCreated = functions.firestore
  .document('posts/{postId}/likes/{likeUid}')
  .onCreate(async (snap, context) => {
    const data = snap.data() || {};
    const postId = context.params.postId;
    const from = data.user_id || context.params.likeUid; // like doc id is the liker uid
    if (!from) return null;

    try {
      const postSnap = await admin.firestore().collection('posts').doc(postId).get();
      if (!postSnap.exists) return null;
      const post = postSnap.data() || {};
      const to = post.user_id;
      if (!to || to === from) return null; // skip self

      // fromName best-effort lookup
      let fromName = '';
      try {
        const userSnap = await admin.firestore().collection('users').doc(from).get();
        if (userSnap.exists) {
          const u = userSnap.data() || {};
          fromName = u.name || u.displayName || '';
        }
      } catch (_) {}

      await admin.firestore().collection('notifications').add({
        to,
        type: 'like',
        from,
        fromName,
        postId,
        timestamp: Date.now(),
        read: false,
      });
    } catch (e) {
      console.error('onPostLikeCreated error', e);
    }
    return null;
  });
