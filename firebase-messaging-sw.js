importScripts('https://www.gstatic.com/firebasejs/10.12.3/firebase-app-compat.js');
importScripts('https://www.gstatic.com/firebasejs/10.12.3/firebase-messaging-compat.js');

// These values must match your firebase_options.dart web config
firebase.initializeApp({
  apiKey: 'AIzaSyAGHexBH5avdbHzVZDoE-YoXLY3izwfdlU',
  appId: '1:60848340645:web:0b48c96b8c6d724254d74c',
  messagingSenderId: '60848340645',
  projectId: 'myapp-6cbbf',
});

const messaging = firebase.messaging();

// Handle background messages
messaging.onBackgroundMessage(function(payload) {
  const title = (payload.notification && payload.notification.title) || 'New message';
  const options = {
    body: (payload.notification && payload.notification.body) || '',
    data: payload.data || {},
  };
  self.registration.showNotification(title, options);
});

self.addEventListener('notificationclick', function(event) {
  event.notification.close();
  const data = event.notification.data || {};
  const url = self.location.origin + '/#conv=' + (data.conversationId || '');
  event.waitUntil(clients.matchAll({ type: 'window' }).then(windowClients => {
    for (let client of windowClients) {
      if (client.url === url && 'focus' in client) return client.focus();
    }
    if (clients.openWindow) return clients.openWindow(url);
  }));
});
