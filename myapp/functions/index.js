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
    const userDocs = [];
    const tokenSet = new Set();
    for (const uid of targetIds) {
      const ref = admin.firestore().collection('users').doc(uid);
      const uSnap = await ref.get();
      if (uSnap.exists) {
        userDocs.push({ uid, ref, data: uSnap.data() || {} });
        const tokens = (uSnap.data() || {}).fcmTokens || [];
        for (const t of tokens) tokenSet.add(t);
      }
    }
  const tokens = Array.from(tokenSet);

    const payload = {
      notification: {
        title: senderName,
        body: text && text.length > 0 ? text : 'Sent you a message',
      },
      data: {
        conversationId: conversationId,
        otherUserId: senderId,
        senderName: senderName,
      },
    };

    try {
      if (tokens.length > 0) {
        const response = await admin.messaging().sendEachForMulticast({
          tokens,
          notification: payload.notification,
          data: payload.data,
          android: {
            priority: 'high',
            notification: {
              channelId: 'messages',
              clickAction: 'FLUTTER_NOTIFICATION_CLICK',
            },
          },
        });
        console.log('Sent notifications (tokens):', response.successCount);
        // Prune invalid tokens
        if (response.failureCount > 0) {
          const invalid = new Set();
          response.responses.forEach((r, i) => {
            if (!r.success) {
              const code = r.error && r.error.code ? r.error.code : '';
              if (code.includes('registration-token-not-registered') || code.includes('invalid-argument')) {
                invalid.add(tokens[i]);
              }
            }
          });
          if (invalid.size > 0) {
            const batch = admin.firestore().batch();
            for (const { ref, data } of userDocs) {
              const oldTokens = (data.fcmTokens || []).filter((t) => !invalid.has(t));
              batch.set(ref, { fcmTokens: oldTokens }, { merge: true });
            }
            await batch.commit();
            console.log('Pruned invalid tokens:', invalid.size);
          }
        }
      } else {
        // Fallback: send to per-user topics for robust delivery
        const sends = targetIds.map((uid) => admin.messaging().send({
          topic: `user_${uid}`,
          notification: payload.notification,
          data: payload.data,
          android: {
            priority: 'high',
            notification: {
              channelId: 'messages',
              clickAction: 'FLUTTER_NOTIFICATION_CLICK',
            },
          },
        }));
        const results = await Promise.allSettled(sends);
        const ok = results.filter(r => r.status === 'fulfilled').length;
        console.log('Sent notifications (topics):', ok);
      }
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
