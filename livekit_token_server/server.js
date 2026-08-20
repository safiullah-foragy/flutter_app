require('dotenv').config();
const express = require('express');
const cors = require('cors');
const { AccessToken } = require('livekit-server-sdk');

const app = express();
const PORT = process.env.PORT || 3000;

const apiKey = process.env.LIVEKIT_API_KEY;
const apiSecret = process.env.LIVEKIT_API_SECRET;

app.use(cors());
app.use(express.json());

// Health check endpoint
app.get('/', (req, res) => {
  res.json({
    status: 'online',
    service: 'LiveKit Token Server',
    timestamp: new Date().toISOString()
  });
});

/**
 * Endpoint to get LiveKit Access Token
 * Query / Body Parameters:
 * - room: name of the stream/room (e.g. postId or channelName)
 * - identity: unique user ID or username
 * - isPublisher: 'true' (broadcaster) or 'false' (viewer in newsfeed)
 * - name: optional display name
 */
app.get('/getToken', async (req, res) => {
  try {
    const room = req.query.room;
    const identity = req.query.identity || `user_${Math.floor(Math.random() * 100000)}`;
    const name = req.query.name || identity;
    const isPublisher = req.query.isPublisher === 'true' || req.query.isPublisher === true;

    if (!room) {
      return res.status(400).json({ error: 'Missing required query parameter: room' });
    }

    if (!apiKey || !apiSecret) {
      return res.status(500).json({
        error: 'LIVEKIT_API_KEY or LIVEKIT_API_SECRET not configured on server'
      });
    }

    // Create Access Token valid for 6 hours
    const at = new AccessToken(apiKey, apiSecret, {
      identity: identity,
      name: name,
      ttl: '6h'
    });

    // Set Room Grants
    at.addGrant({
      room: room,
      roomJoin: true,
      canPublish: isPublisher, // Broadcaster can publish video/audio
      canPublishData: true,    // Send chat messages / reactions
      canSubscribe: true       // Viewers and broadcasters can subscribe to tracks
    });

    const token = await at.toJwt();

    return res.json({
      token: token,
      room: room,
      identity: identity,
      isPublisher: isPublisher
    });
  } catch (error) {
    console.error('Error generating token:', error);
    return res.status(500).json({ error: 'Failed to generate token', details: error.message });
  }
});

app.listen(PORT, () => {
  console.log(`LiveKit Token Server listening on port ${PORT}`);
});
