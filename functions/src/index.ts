import * as admin from 'firebase-admin';
import * as functions from 'firebase-functions';

admin.initializeApp();

const db = admin.database();
const storage = admin.storage();

/**
 * 1. onMessageCreated Trigger:
 * Listens to new envelopes queued at /inbox/{uid}/{pushId}.
 * - Enforces rate limiting (< 100 messages/min per sender).
 * - Delivers a data-only (silent) background FCM push to the recipient device.
 * - Adheres strictly to E2EE zero-knowledge rules: ZERO plaintext is included in FCM.
 */
export const onMessageCreated = functions.database
  .ref('/inbox/{uid}/{pushId}')
  .onCreate(async (snapshot, context) => {
    const { uid, pushId } = context.params;
    const envelope = snapshot.val();

    if (!envelope) return null;

    const senderUid = envelope.senderUid || 'anonymous';
    const now = Date.now();

    // 1. Rate Limiting Check: max 100 messages per minute per sender
    const rateLimitRef = db.ref(`/rate_limits/${senderUid}`);
    const rateLimitSnap = await rateLimitRef.get();
    let currentWindow = { count: 0, resetAt: now + 60000 };

    if (rateLimitSnap.exists()) {
      const val = rateLimitSnap.val();
      if (val && val.resetAt && now < val.resetAt) {
        currentWindow = val;
      }
    }

    currentWindow.count = (currentWindow.count || 0) + 1;

    if (currentWindow.count > 100) {
      console.warn(
        `RATE LIMIT EXCEEDED: Sender ${senderUid} exceeded 100 msgs/min (count=${currentWindow.count}). Purging envelope ${pushId}.`
      );
      await snapshot.ref.remove();
      return null;
    }

    await rateLimitRef.set(currentWindow);

    // 2. Fetch recipient's FCM registration token
    const fcmSnap = await db.ref(`/users/${uid}/private/fcm`).get();
    if (!fcmSnap.exists() || !fcmSnap.val()) {
      return null;
    }

    const fcmToken = String(fcmSnap.val());

    // 3. Dispatch Data-Only Silent FCM Push (Wakes device to drain /inbox)
    const payload: admin.messaging.Message = {
      token: fcmToken,
      data: {
        type: 'inbox_drain',
        senderUsername: String(envelope.senderUsername || '@user'),
        pushId: String(pushId),
        timestamp: String(envelope.timestamp || now),
      },
      android: {
        priority: 'high',
      },
      apns: {
        payload: {
          aps: {
            'content-available': 1,
          },
        },
        headers: {
          'apns-priority': '5',
          'apns-push-type': 'background',
        },
      },
    };

    try {
      await admin.messaging().send(payload);
      console.log(`FCM Silent Push dispatched to UID ${uid} for pushId ${pushId}`);
    } catch (err) {
      console.error(`FCM dispatch error for UID ${uid}:`, err);
    }

    return null;
  });

/**
 * 2. Scheduled Cleanup Job (Hourly):
 * - Purges envelopes in /inbox older than 30 days.
 * - Purges orphaned ephemeral media blobs in Storage older than 30 days.
 */
export const cleanupExpiredInbox = functions.pubsub
  .schedule('0 * * * *')
  .onRun(async () => {
    const thirtyDaysAgo = Date.now() - 30 * 24 * 60 * 60 * 1000;
    console.log(`Starting hourly cleanup. Cutoff: ${new Date(thirtyDaysAgo).toISOString()}`);

    // Clean up /inbox
    try {
      const inboxRef = db.ref('/inbox');
      const snap = await inboxRef.get();
      if (snap.exists()) {
        const inboxData = snap.val();
        let purgedCount = 0;

        for (const [recipientUid, messages] of Object.entries<any>(inboxData)) {
          if (messages && typeof messages === 'object') {
            for (const [msgPushId, msgData] of Object.entries<any>(messages)) {
              const timestamp = msgData.timestamp || 0;
              const expiresAt = msgData.expiresAt || 0;

              if (timestamp < thirtyDaysAgo || (expiresAt > 0 && Date.now() > expiresAt)) {
                await db.ref(`/inbox/${recipientUid}/${msgPushId}`).remove();
                purgedCount++;
              }
            }
          }
        }
        console.log(`Cleaned up ${purgedCount} expired envelopes from /inbox`);
      }
    } catch (e) {
      console.error('Error during /inbox cleanup:', e);
    }

    // Clean up ephemeral Storage media blobs
    try {
      const bucket = storage.bucket();
      const [files] = await bucket.getFiles({ prefix: 'ephemeral_media/' });
      let purgedBlobs = 0;

      for (const file of files) {
        const [metadata] = await file.getMetadata();
        const created = metadata.timeCreated
          ? new Date(metadata.timeCreated).getTime()
          : 0;

        if (created < thirtyDaysAgo) {
          await file.delete();
          purgedBlobs++;
        }
      }
      console.log(`Cleaned up ${purgedBlobs} expired ephemeral media blobs from Storage`);
    } catch (e) {
      console.error('Error during Storage media cleanup:', e);
    }

    return null;
  });
