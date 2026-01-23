/* This is to monitor your rig and server. You connect the bot to your Telegram and will get a few notifcations. I recommend setting this script to run once every hour with the check flag
and once daily with the report flag. The hourly check first checks if the key is found, if it is, the bot will blow up your phone, texiting and callign every hour. If the bots status changes, 
for example, if it was online and now is off, you will get notified and vice versa. This is determined using the database and when the last job was finished. 

If this rig goes down, you won't get spammed messages every hour, you will get one message and then no more until the rig is back up.

*/

import 'dotenv/config';
import fs from 'fs';
import sqlite3 from 'sqlite3';
import fetch from 'node-fetch';

// CONFIGURATION
// Get from @BotFather
const BOT_TOKEN = process.env.TELEGRAM_BOT_TOKEN;

// Get from @userinfobot
const CHAT_ID = process.env.TELEGRAM_CHAT_ID;

// Get from @CallMeBot_txt2voicebot (include the @ symbol if instructed)
const CALLMEBOT_USER = process.env.TELEGRAM_USERNAME;

// --- MINING CONFIG ---
const CHUNK_SIZE = 1100000000000n; // 1.1 Trillion
const DB_PATH = process.env.DB_PATH || './mining.db';
const WINNER_PATH = process.env.WINNER_PATH || './WINNER.txt';
// New: File to track previous state (prevents spamming alerts)
const STATE_FILE = process.env.STATE_FILE || './monitor_state.json';

// --- HELPERS ---
async function sendTelegram(text) {
    const url = `https://api.telegram.org/bot${BOT_TOKEN}/sendMessage`;
    try {
        await fetch(url, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ chat_id: CHAT_ID, text: text })
        });
    } catch (e) {
        console.error("Telegram Error:", e.message);
    }
}

async function makePhoneCall(text) {
    const encodedText = encodeURIComponent(text);
    const url = `http://api.callmebot.com/start.php?user=${CALLMEBOT_USER}&text=${encodedText}&lang=en-US-Standard-C&rpt=2`;
    try { await fetch(url); } catch (e) { console.error("Call Error:", e.message); }
}

// --- LOGIC ---
const mode = process.argv[2];

if (mode === 'check') {
    // 1. VICTORY CHECK
    if (fs.existsSync(WINNER_PATH)) {
        console.log("WINNER FILE FOUND! TRIGGERING ALARM!");
        const secureMsg = `VICTORY DECLARED\n\n` +
            `A winner file has been detected on the USB drive.\n` +
            `The system has successfully found the key.\n\n` +
            `ACTION REQUIRED:\n` +
            `1. Go to the physical location.\n` +
            `2. Remove the USB drive.\n` +
            `3. Secure the key manually.`;

        await sendTelegram(secureMsg);
        await makePhoneCall("Wake up. The key has been found. Go to the miner now.");

        // Exit to prevent sending offline alerts during a victory
        process.exit(0);
    }

    // 2. HEALTH CHECK (New Stateful Logic)
    const db = new sqlite3.Database(DB_PATH, sqlite3.OPEN_READONLY);

    // Check the last time a job was finished
    db.get("SELECT max(completed_at) as last_seen FROM ranges WHERE status IN ('DONE', 'FOUND')", [], async (err, row) => {
        if (err) return console.error(err);

        const lastSeen = row.last_seen || 0;
        const minutesAgo = (Date.now() - lastSeen) / 1000 / 60;

        // Determine Current Real-Time Status (Buffer: 20 mins)
        const isCurrentlyDown = minutesAgo > 20;
        const currentStatus = isCurrentlyDown ? 'DOWN' : 'UP';

        // Load Previous State from file (Default to 'UP' if no file exists)
        let previousStatus = 'UP';
        try {
            if (fs.existsSync(STATE_FILE)) {
                const data = fs.readFileSync(STATE_FILE, 'utf8');
                previousStatus = JSON.parse(data).status;
            }
        } catch (e) {
            console.error("Could not read state file, assuming UP.");
        }

        // COMPARE and ALERT
        if (currentStatus === 'DOWN' && previousStatus === 'UP') {
            // SCENARIO: Just Crashed -> Send Alert
            console.log("[ALERT] System went DOWN.");
            await sendTelegram(`⚠️ ALERT ⚠️\n\n🔴 Miner OFFLINE.\n⏰ Last active: ${Math.round(minutesAgo)} mins ago`);

        } else if (currentStatus === 'UP' && previousStatus === 'DOWN') {
            // SCENARIO: Just Recovered -> Send Alert
            console.log("[ALERT] System recovered.");
            await sendTelegram(`🟢 Miner ONLINE 🍀\n\n⏰ Last Job Finished: ${Math.round(minutesAgo)} mins ago.`);

        } else {
            // SCENARIO: No Change (Still UP or Still DOWN) -> Silence
            console.log(`[STATUS] No change. State: ${currentStatus}`);
        }

        // Save New State for next hour
        fs.writeFileSync(STATE_FILE, JSON.stringify({ status: currentStatus, timestamp: Date.now() }));
    });
}

else if (mode === 'report') {
    // 2. DAILY REPORT
    const db = new sqlite3.Database(DB_PATH, sqlite3.OPEN_READONLY);

    // Fetch Total Jobs AND the Last Time a job was finished
    const query = "SELECT count(*) as total, max(id) as current_job, max(completed_at) as last_seen FROM ranges WHERE status IN ('DONE', 'FOUND')";

    db.get(query, [], async (err, row) => {
        if (err) { console.error(err); return; }

        const totalJobs = row.total || 0;
        const currentJob = row.current_job || 0;
        const lastSeen = row.last_seen || 0;

        // 1. Calculate Stats
        const totalKeys = BigInt(totalJobs) * CHUNK_SIZE;
        const totalKeysNum = Number(totalKeys);

        const keysFormatted = totalKeysNum >= 1e15
            ? (totalKeysNum / 1e15).toFixed(3) + " Quadrillion"
            : (totalKeysNum / 1e12).toFixed(2) + " Trillion";

        // 2. Calculate Real Status
        const minutesAgo = (Date.now() - lastSeen) / 1000 / 60;

        // Format the Last Seen Time
        let lastFinishedTime = "N/A";
        if (lastSeen > 0) {
            lastFinishedTime = new Date(lastSeen).toLocaleString('en-US', {
                timeZone: 'America/New_York', // Adjust timezone if needed
                hour12: false
            });
        }

        let statusText = "ONLINE";
        let statusEmoji = "🟢";
        if (minutesAgo > 20) {
            statusText = `OFFLINE (Stalled ${Math.round(minutesAgo)}m ago)`;
            statusEmoji = "🔴";
        }

        const msg = `📊 Daily Mining Report\n\n` +
            `🛠 Current Job: #${currentJob}\n` +
            `✅ Completed Jobs: ${totalJobs}\n` +
            `🔑 Total Keys: ${keysFormatted}\n` +
            `⏱️ Last Job Finished: ${lastFinishedTime}\n` +
            `${statusEmoji} Status: ${statusText}`;

        await sendTelegram(msg);
        console.log("Report sent.");
    });
}