/* This runs as a server on the Pi or whatever you use as server. Make it run 24/7 and start on boot with pm2. 
With this you are going to be hosting a web server that the rig will hit whenever it needs work. The work is given in ranges of 1.1 trillion, is determined randomly, 
and setup so that you will never guess the same key twice. The keyspace (2^70) is divided into 1.1trillion key chunks. Each time a range is generated its taken MOD the total space.
This ensures that it snaps to the grid. There is no replacement because before giving the work to the rig the server checks the database to ensure that the range has not been searched.

If the rig reports that it found the key this will write to the database, the disk the db is on, and any other disks that you specify.
*/
import 'dotenv/config';
import express from 'express';
import sqlite3 from 'sqlite3';
import fs from 'fs';
import { exec } from 'child_process';
import crypto from 'crypto'; // Native Node.js crypto for secure grid generation

const app = express();

// CONFIGURATION
const PORT = process.env.PORT || 3000;
const RIG_MAC_ADDRESS = process.env.RIG_MAC_ADDRESS;
const ALLOWED_IP_PREFIX = process.env.ALLOWED_IP_PREFIX || '10.42.';

// --- PUZZLE CONFIGURATION (Puzzle #71) ---
const PUZZLE_START = BigInt("0x400000000000000000");
const PUZZLE_END = BigInt("0x7fffffffffffffffff");

// PRODUCTION MODE: 1.1 Trillion Keys (~9-12 mins at 1500-2000 MKeys/s)
const CHUNK_SIZE = BigInt("1100000000000");

// --- DATABASE SETUP ---
const sql = sqlite3.verbose();
const db = new sql.Database('/mnt/usb_storage/mining.db');

db.serialize(() => {
    // Note: start_hex is UNIQUE. This works with the logic below to prevent repeats.
    db.run(`CREATE TABLE IF NOT EXISTS ranges (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        start_hex TEXT UNIQUE,
        end_hex TEXT,
        status TEXT DEFAULT 'PROCESSING',
        assigned_to TEXT,
        started_at INTEGER,
        completed_at INTEGER
    )`);
});

app.use(express.json());

// --- MIDDLEWARE: IP SECURITY (RELAXED) ---
app.use((req, res, next) => {
    const requestIP = req.ip.replace('::ffff:', '');
    if (requestIP === '127.0.0.1' || requestIP.startsWith('10.42.')) {
        next();
    } else {
        console.warn(`[SECURITY] Blocked request from unauthorized IP: ${requestIP}`);
        res.status(403).send("Forbidden: Unauthorized Miner");
    }
});

// --- HELPER: Random Range Generator (GRID SNAPPED) ---
function generateRandomRange() {
    const totalSpace = PUZZLE_END - PUZZLE_START;
    const totalSlots = totalSpace / CHUNK_SIZE; // How many 1.1T blocks fit?

    // 1. Generate a random "Slot Number" (Index)
    // We use crypto to get a random index between 0 and totalSlots
    const buffer = crypto.randomBytes(8);
    const randomHex = buffer.toString('hex');
    let randomIndex = BigInt("0x" + randomHex);

    // Modulo to ensure it falls within valid slot count
    randomIndex = randomIndex % totalSlots;

    // 2. Calculate the exact start based on the slot index
    // This snaps the start to a perfect multiple of CHUNK_SIZE
    const offset = randomIndex * CHUNK_SIZE;

    const newStart = PUZZLE_START + offset;
    let newEnd = newStart + CHUNK_SIZE;

    // Cap at end of puzzle
    if (newEnd > PUZZLE_END) newEnd = PUZZLE_END;

    return { start: newStart, end: newEnd };
}

// --- API: WAKE RIG ---
app.get('/wake', (req, res) => {
    console.log("[WOL] Sending Magic Packet to Rig...");
    exec(`sudo etherwake -i eth0 ${RIG_MAC_ADDRESS}`, (err, stdout, stderr) => {
        if (err) {
            console.error(`[WOL] Error: ${stderr}`);
            return res.status(500).send("WOL Failed");
        }
        res.send("Magic Packet Sent");
    });
});

// --- API: ASSIGN WORK (With Internal Retry) ---
app.get('/work', (req, res) => {
    const workerIp = req.ip.replace('::ffff:', '');
    const timeoutCutoff = Date.now() - (30 * 60 * 1000); // 30 mins

    // 1. Recover dropped work (Older than 30 mins)
    db.get(`SELECT * FROM ranges WHERE status = 'PROCESSING' AND started_at < ? LIMIT 1`, [timeoutCutoff], (err, row) => {
        if (row) {
            assignJob(row, workerIp, res);
        } else {
            // 2. Generate NEW Random Work (Recursive Retry Loop)
            tryAssignNewJob(workerIp, res, 0);
        }
    });
});

// Helper function to handle collisions recursively
function tryAssignNewJob(workerIp, res, attempts) {
    if (attempts > 10) {
        console.error("CRITICAL: Too many collisions. DB might be full?");
        return res.status(500).send("Server Busy");
    }

    const range = generateRandomRange();

    // STRICT INSERT (No "OR IGNORE") - We want to catch the error
    db.run(`INSERT INTO ranges (start_hex, end_hex, assigned_to, started_at) VALUES (?, ?, ?, ?)`,
        [range.start.toString(16), range.end.toString(16), workerIp, Date.now()],
        function (err) {
            if (err) {
                // If error is "UNIQUE constraint failed", we hit a duplicate.
                // Log it and try again immediately.
                if (err.message.includes("UNIQUE constraint failed") || err.code === 'SQLITE_CONSTRAINT') {
                    console.log(`[COLLISION] Slot already mined. Retrying... (Attempt ${attempts + 1})`);
                    return tryAssignNewJob(workerIp, res, attempts + 1);
                }
                // Real error? Crash.
                console.error(err);
                return res.status(500).send("Database Error");
            }

            // Success! We found a fresh slot.
            db.get(`SELECT * FROM ranges WHERE rowid = ?`, [this.lastID], (err, newRow) => {
                assignJob(newRow, workerIp, res);
            });
        }
    );
}

function assignJob(row, ip, res) {
    const now = Date.now();
    const timeStr = new Date(now).toLocaleTimeString('en-US', { hour12: false });

    // Update DB
    db.run(`UPDATE ranges SET status = 'PROCESSING', assigned_to = ?, started_at = ? WHERE id = ?`,
        [ip, now, row.id]);

    // LOGGING UPDATE: Time + Range
    console.log(`[ASSIGN] [${timeStr}] Job #${row.id} -> ${ip}`);
    console.log(`         Range: 0x${row.start_hex} -> 0x${row.end_hex}`);

    res.json({ id: row.id, start: row.start_hex, end: row.end_hex });
}

// --- API: RECEIVE RESULT ---
app.post('/submit-work', (req, res) => {
    const { id, result, speed, key } = req.body;
    const now = Date.now();
    const timeStr = new Date(now).toLocaleTimeString('en-US', { hour12: false });

    db.get(`SELECT started_at, start_hex, end_hex FROM ranges WHERE id = ?`, [id], (err, row) => {
        if (!row) return res.send("ACK");

        const duration = ((now - row.started_at) / 1000).toFixed(2); // Seconds

        console.log(`[REPORT] [${timeStr}] Job #${id} (${result}) - Duration: ${duration}s`);
        console.log(`         Speed: ${speed}`);

        if (result === 'FOUND') {
            const msg = `\n[VICTORY] KEY FOUND: ${key}\nRange: 0x${row.start_hex} -> 0x${row.end_hex}\nTime: ${timeStr}\n`;

            console.log(msg);

            // Priority 1: Save to USB (Synchronous)
            try {
                fs.appendFileSync('/mnt/usb_storage/WINNER.txt', msg);
            } catch (err) {
                console.error("[ERROR] USB Write Failed:", err.message);
            }

            // Priority 2: Save to Local SD (Synchronous)
            try {
                fs.appendFileSync('./WINNER.txt', msg);
            } catch (err) {
                console.error("[ERROR] Local Write Failed:", err.message);
            }

            // Priority 3: Update Database (Async)
            db.run(`UPDATE ranges SET status = 'FOUND', completed_at = ? WHERE id = ?`, [now, id]);

            // Finally TRIGGER ALERT
            // We use process.execPath to ensure we use the same 'node' that is running this server
            try {
                console.log("[ALERT] Triggering notification script...");
                exec(`${process.execPath} alert.js check`, (error, stdout, stderr) => {
                    if (error) {
                        console.error(`[ALERT ERROR] Failed to run script: ${error.message}`);
                        return;
                    }
                    console.log("[ALERT] Notification script launched successfully.");
                });
            } catch (e) {
                console.error("[ALERT CRITICAL] Could not trigger alert:", e.message);
            }

        } else {
            // Mark as DONE
            db.run(`UPDATE ranges SET status = 'DONE', completed_at = ? WHERE id = ?`, [now, id]);
        }
        res.send("ACK");
    });
});

app.listen(PORT, '0.0.0.0', () => console.log(`--- ORCHESTRATOR ONLINE (Secure/Grid/Production) ---\nAllowed IP: 10.42.x.x`));