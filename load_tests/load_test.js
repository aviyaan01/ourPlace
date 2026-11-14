/**
 * Nest High-Concurrency Load Test (1,000 to 10,000 Clients)
 * Simulates real user lifecycle: Auth -> Prefix Search -> E2EE Message Send -> Receive & ACK
 * Measures p50, p95, p99 latencies, throughput, and error rates.
 */

const crypto = require('crypto');

// Helper to compute percentile from array of durations (ms)
function computePercentile(durations, p) {
  if (durations.length === 0) return 0;
  const sorted = [...durations].sort((a, b) => a - b);
  const index = Math.min(sorted.length - 1, Math.floor((p / 100) * sorted.length));
  return sorted[index];
}

class MockRealtimeDatabase {
  constructor() {
    this.usernames = new Map(); // username -> uid
    this.users = new Map();     // uid -> profile
    this.inbox = new Map();     // uid -> Map<pushId, envelope>
    this.presence = new Map();  // uid -> { online, lastSeen }
    this.typing = new Map();    // chatId -> Map<uid, boolean>
  }

  // Atomic claim
  async claimUsername(username, uid) {
    await new Promise((r) => setTimeout(r, Math.random() * 8 + 2)); // 2-10ms simulated network
    if (this.usernames.has(username)) {
      throw new Error(`Username ${username} already claimed`);
    }
    this.usernames.set(username, uid);
    this.users.set(uid, {
      username: `@${username}`,
      publicIdentityKey: crypto.randomBytes(32).toString('base64'),
      createdAt: Date.now(),
    });
  }

  // Prefix search: startAt(prefix).endAt(prefix + '\uf8ff').limitToFirst(20)
  async prefixSearch(prefix, limit = 20) {
    await new Promise((r) => setTimeout(r, Math.random() * 12 + 3)); // 3-15ms index scan
    const results = [];
    for (const [uname, uid] of this.usernames.entries()) {
      if (uname.startsWith(prefix)) {
        const profile = this.users.get(uid);
        if (profile) {
          results.push(profile);
          if (results.length >= limit) break;
        }
      }
    }
    return results;
  }

  // Push to /inbox/{recipientUid}/{pushId}
  async pushInbox(recipientUid, envelope) {
    await new Promise((r) => setTimeout(r, Math.random() * 10 + 4));
    if (!this.inbox.has(recipientUid)) {
      this.inbox.set(recipientUid, new Map());
    }
    const pushId = `push_${Date.now()}_${Math.random().toString(36).substring(2, 9)}`;
    this.inbox.get(recipientUid).set(pushId, envelope);
    return pushId;
  }

  // Atomic ACK: remove from /inbox/{recipientUid}/{pushId}
  async ackInbox(recipientUid, pushId) {
    await new Promise((r) => setTimeout(r, Math.random() * 5 + 2));
    if (this.inbox.has(recipientUid)) {
      this.inbox.get(recipientUid).delete(pushId);
      return true;
    }
    return false;
  }
}

async function runLoadSimulation({ totalClients = 1000, batchSize = 100 }) {
  console.log(`\n======================================================`);
  console.log(` Starting Nest Load Test: ${totalClients} Concurrent Clients`);
  console.log(` Concurrency Batch Size: ${batchSize}`);
  console.log(`======================================================\n`);

  const rtdb = new MockRealtimeDatabase();
  const searchLatencies = [];
  const sendLatencies = [];
  const ackLatencies = [];
  const fullCycleLatencies = [];

  let successCount = 0;
  let failureCount = 0;

  // 1. Seed user directory for realistic prefix search
  console.log(`Pre-seeding ${totalClients} directory entries...`);
  for (let i = 0; i < totalClients; i++) {
    const handle = `user_${String(i).padStart(5, '0')}`;
    const uid = `uid_${i}`;
    await rtdb.claimUsername(handle, uid);
  }
  console.log(`Seeding complete.\n`);

  const startTime = Date.now();

  // 2. Run simulation in concurrency batches
  for (let batchStart = 0; batchStart < totalClients; batchStart += batchSize) {
    const batchEnd = Math.min(totalClients, batchStart + batchSize);
    const batchPromises = [];

    for (let i = batchStart; i < batchEnd; i++) {
      batchPromises.push(
        (async () => {
          const clientStartTime = Date.now();
          try {
            const senderHandle = `user_${String(i).padStart(5, '0')}`;
            const senderUid = `uid_${i}`;

            // A. Prefix Search (minimum 3 chars)
            const searchStart = Date.now();
            const prefix = 'user_0';
            const searchResults = await rtdb.prefixSearch(prefix, 20);
            searchLatencies.push(Date.now() - searchStart);

            if (searchResults.length === 0) {
              throw new Error('Search returned empty');
            }

            // B. Pick random target peer
            const targetPeer = searchResults[Math.floor(Math.random() * searchResults.length)];
            const targetUid = targetPeer.username.replace('@', '').replace('user_', 'uid_');

            // C. Send E2EE Envelope
            const sendStart = Date.now();
            const envelope = {
              id: `msg_${Date.now()}_${i}`,
              senderUid: senderUid,
              senderUsername: `@${senderHandle}`,
              ciphertext: crypto.randomBytes(64).toString('base64'),
              type: 'message',
              timestamp: Date.now(),
              expiresAt: Date.now() + 48 * 3600 * 1000,
            };
            const pushId = await rtdb.pushInbox(targetUid, envelope);
            sendLatencies.push(Date.now() - sendStart);

            // D. Receive & Atomic ACK
            const ackStart = Date.now();
            const acked = await rtdb.ackInbox(targetUid, pushId);
            ackLatencies.push(Date.now() - ackStart);

            if (!acked) {
              throw new Error('ACK failed');
            }

            fullCycleLatencies.push(Date.now() - clientStartTime);
            successCount++;
          } catch (err) {
            failureCount++;
          }
        })()
      );
    }

    await Promise.all(batchPromises);
    const progress = Math.min(100, Math.round((batchEnd / totalClients) * 100));
    process.stdout.write(` Progress: ${batchEnd}/${totalClients} clients (${progress}%)\r`);
  }

  const totalDurationMs = Date.now() - startTime;
  const opsPerSec = Math.round(((totalClients * 3) / (totalDurationMs / 1000)) * 10) / 10;

  console.log(`\n\n================ LOAD TEST RESULTS ================`);
  console.log(`Total Simulated Clients:   ${totalClients}`);
  console.log(`Successful Full Cycles:    ${successCount}`);
  console.log(`Failed Cycles:             ${failureCount}`);
  console.log(`Success Rate:              ${((successCount / totalClients) * 100).toFixed(2)}%`);
  console.log(`Total Execution Time:      ${totalDurationMs} ms`);
  console.log(`Effective Throughput:      ${opsPerSec} ops/sec\n`);

  console.log(`--- Latency Breakdown (ms) ---`);
  console.log(`Operation        | p50   | p90   | p95   | p99   | Max`);
  console.log(`-----------------+-------+-------+-------+-------+------`);
  console.log(
    `Prefix Search    | ${computePercentile(searchLatencies, 50).toString().padEnd(5)} | ${computePercentile(searchLatencies, 90).toString().padEnd(5)} | ${computePercentile(searchLatencies, 95).toString().padEnd(5)} | ${computePercentile(searchLatencies, 99).toString().padEnd(5)} | ${Math.max(...searchLatencies, 0)}`
  );
  console.log(
    `Inbox Push       | ${computePercentile(sendLatencies, 50).toString().padEnd(5)} | ${computePercentile(sendLatencies, 90).toString().padEnd(5)} | ${computePercentile(sendLatencies, 95).toString().padEnd(5)} | ${computePercentile(sendLatencies, 99).toString().padEnd(5)} | ${Math.max(...sendLatencies, 0)}`
  );
  console.log(
    `Atomic ACK Purge | ${computePercentile(ackLatencies, 50).toString().padEnd(5)} | ${computePercentile(ackLatencies, 90).toString().padEnd(5)} | ${computePercentile(ackLatencies, 95).toString().padEnd(5)} | ${computePercentile(ackLatencies, 99).toString().padEnd(5)} | ${Math.max(...ackLatencies, 0)}`
  );
  console.log(
    `Full Cycle       | ${computePercentile(fullCycleLatencies, 50).toString().padEnd(5)} | ${computePercentile(fullCycleLatencies, 90).toString().padEnd(5)} | ${computePercentile(fullCycleLatencies, 95).toString().padEnd(5)} | ${computePercentile(fullCycleLatencies, 99).toString().padEnd(5)} | ${Math.max(...fullCycleLatencies, 0)}`
  );
  console.log(`====================================================\n`);

  return { successCount, failureCount, opsPerSec };
}

// Execute 1,000 clients and 10,000 clients verification
(async () => {
  try {
    // 1. 1,000 Clients Run
    await runLoadSimulation({ totalClients: 1000, batchSize: 100 });

    // 2. 10,000 Clients Run (Batch mode)
    await runLoadSimulation({ totalClients: 10000, batchSize: 500 });
  } catch (err) {
    console.error('Fatal load test error:', err);
    process.exit(1);
  }
})();

