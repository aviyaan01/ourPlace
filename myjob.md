# Nest — User Manual Action Items & Setup Guide (`myjob.md`)

This guide contains all external, manual tasks you need to complete for the project as we progress through the phases. You can complete these at your own pace while the codebase development continues smoothly.

---

## 📋 Master Roadmap: Your Manual Tasks

- [x] **Phase 11: Firebase Cloud Setup (COMPLETED ✅ — 2026-09-18)**
- [x] **Phase 12: Message Synchronization (COMPLETED ✅ — 2026-09-18)**
- [x] **Phase 13: Real-Time Features (COMPLETED ✅ — 2026-09-18)**
- [x] **Phase 14: Push Notifications (COMPLETED ✅ — 2026-09-18)**
- [x] **Phase 15: Media Messaging (COMPLETED ✅ — 2026-09-19)**
- [x] **Phase 16: Love Connection (COMPLETED ✅ — 2026-09-19)**
- [x] **Phase 17: One-Time Love Code & Conversation Sharing (COMPLETED ✅ — 2026-09-19)**
- [x] **Phase 18: Couple-Specific Features & Micro-Interactions (COMPLETED ✅ — 2026-09-19)**
- [x] **Phase 19: Production Readiness & Store Compliance (COMPLETED ✅ — 2026-09-24)**
- [x] **Phase 20: 10,000+ Concurrent Users Scale Upgrade (COMPLETED ✅ — 2026-11-14)**

---

## 1. Firebase Realtime Database Security Rules Update (REQUIRED)

To support 10,000+ concurrent users with atomic username reservation and secure inboxes:
1. Open the [Firebase Console](https://console.firebase.google.com/) for project `ourplace-chat`.
2. Navigate to **Realtime Database** ➔ **Rules** tab.
3. Paste the contents of [`firebase_security_rules.json`](../firebase_security_rules.json).
4. Click **Publish**.

The rules ensure:
- `/usernames/{username}` has create-only atomic reservation (no collisions possible).
- `/inbox/{uid}/{pushId}` allows write only by the sender and read/delete only by the recipient.
- `/presence/{uid}` and `/typing/{chatId}/{uid}` are strictly authenticated and scoped.
- `/directory` and `/relays` maintain backward compatibility with older clients.

---

## 2. Deploy Cloud Functions (Node.js / TypeScript)

From the project root:
```powershell
cd functions
npm run build
firebase deploy --only functions
```
This deploys:
1. `onMessageCreated`: Silent background FCM wakeup when messages arrive.
2. `cleanupExpiredInbox`: Hourly purge of 30-day expired envelopes and storage blobs.
3. `rateLimiter`: Protects against spam attacks ($> 100$ msgs/min).

---

## 3. Fresh APK Installation & Testing

Because the Android application ID was finalized to `com.ourplace.nest` with database migrations to schema v7:

### Step 1: Uninstall Old Version from Device
On both test devices (Device A and Device B):
1. Locate the existing `Nest` or `Chatbox` app icon on your home screen or app drawer.
2. Long-press the icon ➔ select **App info** (or drag to **Uninstall**).
3. Tap **Uninstall** and confirm.
   *(Or via ADB: `adb uninstall com.ourplace.nest` / `adb uninstall com.example.chatbox`)*

### Step 2: Install Fresh Release APK
The updated standalone release APK is located in the project root:
```
Nest-release.apk
```
Install on your device using ADB:
```powershell
adb install -r Nest-release.apk
```
Or transfer `Nest-release.apk` to your phone via USB / Google Drive and tap to install.

### Step 3: Two-Device Verification Walkthrough
1. **Device A (Registration):**
   - Open Nest.
   - Enter username: `@alex` and password: `password123`.
   - Tap **Create Account**. Save your 12-word mnemonic phrase.
   - Setup a 4-digit app lock passcode: `1234`.
2. **Device B (Registration):**
   - Open Nest.
   - Enter username: `@twilight` and password: `password123`.
   - Tap **Create Account**. Save your 12-word recovery phrase.
   - Setup a 4-digit app lock passcode: `5678`.
3. **Directory Search Verification:**
   - On Device A's Inbox screen, type `twi` in the search bar.
   - Observe the 300ms debounce and fast prefix results displaying `@twilight`.
   - Notice the blue verified badge or key change warning indicator.
4. **Reliable Messaging & ACK:**
   - Tap `@twilight` to open `ChatScreen`.
   - Send: `"Hey Twilight, welcome to Nest 10k!"`.
   - Notice status transitions: `sending` $\to$ `sent` $\to$ `delivered` (double checkmark).
   - On Device B, notice the message arrives in real-time and is automatically ACK-purged from the cloud inbox.
5. **Presence & Typing:**
   - On Device B, type a letter into the input field. Observe Device A immediately shows `typing...` in pink in the header.
   - Clear the input field or wait 3 seconds: observe `typing...` disappears immediately.
   - Observe the green dot `● online` presence indicator.
6. **Couple Space & "Send luv":**
   - Form Love Connection via Profile ➔ Love Connection.
   - Tap **Send luv** in `ChatScreen` and watch floating hearts shower across both phones!
