import 'dotenv/config'; // Load .env
import express from 'express';
import sqlite3 from 'sqlite3';
import fs from 'fs';
import { execFile } from 'child_process';
import path from 'path'; // Needed for path defaults

const app = express();
const PORT = process.env.PORT || 3000;

// --- SECURITY CONFIGURATION ---
// Updated to use the Prefix from .env to allow the whole subnet
const ALLOWED_IP_PREFIX = process.env.ALLOWED_IP_PREFIX || '10.42.';
const RIG_MAC_ADDRESS = process.env.RIG_MAC_ADDRESS;
const WOL_INTERFACE = process.env.WOL_INTERFACE || 'eth0';

// --- PATHS ---
const DB_PATH = process.env.DB_PATH || path.join(process.cwd(), 'mining.db');
const WINNER_PATH = process.env.WINNER_PATH || path.join(process.cwd(), 'WINNER.txt');

// --- PUZZLE CONFIGURATION (Puzzle #71) ---
const PUZZLE_START = BigInt("0x400000000000000000");
const PUZZLE_END = BigInt("0x7fffffffffffffffff");
// TEST MODE: 50 Billion Keys (~5 seconds on 3080)
const CHUNK_SIZE = BigInt("1000000000");

// --- DATABASE SETUP ---
const sql = sqlite3.verbose();
const db = new sql.Database(DB_PATH);

db.serialize(() => {
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

// --- MIDDLEWARE: IP SECURITY ---
app.use((req, res, next) => {
    const requestIP = req.ip.replace('::ffff:', '');
    // Updated check to use startsWith for the prefix
    if (requestIP === '127.0.0.1' || requestIP.startsWith(ALLOWED_IP_PREFIX)) {
        next();
    } else {
        console.warn(`[SECURITY] Blocked request from unauthorized IP: ${requestIP}`);
        res.status(403).send("Forbidden: Unauthorized Miner");
    }
});

// --- HELPER: Random Range Generator ---
function generateRandomRange() {
    // !!! FIELD TEST MODE !!!
    // We strictly hardcode the start to Puzzle 71 base
    // to ensure we capture the test key (which is at offset +1000)

    const newStart = BigInt("0x400000000000000000");
    const newEnd = newStart + CHUNK_SIZE;

    return { start: newStart, end: newEnd };
}

// --- API: WAKE RIG ---
app.get('/wake', (req, res) => {
    console.log("[WOL] Sending Magic Packet to Rig...");
    execFile('sudo', ['etherwake', '-i', WOL_INTERFACE, RIG_MAC_ADDRESS || ''], (err, stdout, stderr) => {
        if (err) {
            console.error(`[WOL] Error: ${stderr}`);
            return res.status(500).send("WOL Failed");
        }
        res.send("Magic Packet Sent");
    });
});

// --- API: ASSIGN WORK ---
app.get('/work', (req, res) => {
    const workerIp = req.ip.replace('::ffff:', '');
    const timeoutCutoff = Date.now() - (15 * 60 * 1000); // 15 mins

    // 1. Recover dropped work
    db.get(`SELECT * FROM ranges WHERE status = 'PROCESSING' AND started_at < ? LIMIT 1`, [timeoutCutoff], (err, row) => {
        if (row) {
            assignJob(row, workerIp, res);
        } else {
            // 2. Generate NEW Work (Hardcoded for Test)
            const range = generateRandomRange();
            db.run(`INSERT OR IGNORE INTO ranges (start_hex, end_hex, assigned_to, started_at) VALUES (?, ?, ?, ?)`,
                [range.start.toString(16), range.end.toString(16), workerIp, Date.now()],
                function (err) {
                    if (err) {
                        return res.redirect('/work'); // Retry on collision
                    }
                    db.get(`SELECT * FROM ranges WHERE rowid = ?`, [this.lastID], (err, newRow) => {
                        assignJob(newRow, workerIp, res);
                    });
                }
            );
        }
    });
});

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

    // Fetch start time to calculate duration
    db.get(`SELECT started_at, start_hex, end_hex FROM ranges WHERE id = ?`, [id], (err, row) => {
        if (!row) return res.send("ACK");

        const duration = ((now - row.started_at) / 1000).toFixed(2); // Seconds

        console.log(`[REPORT] [${timeStr}] Job #${id} (${result}) - Duration: ${duration}s`);
        console.log(`         Speed: ${speed}`);

        if (result === 'FOUND') {
            const msg = `\n[VICTORY] KEY FOUND: ${key}\nRange: 0x${row.start_hex} -> 0x${row.end_hex}\nTime: ${timeStr}\n`;
            console.log(msg);
            fs.appendFileSync(WINNER_PATH, msg);
            db.run(`UPDATE ranges SET status = 'FOUND', completed_at = ? WHERE id = ?`, [now, id]);
        } else {
            db.run(`UPDATE ranges SET status = 'DONE', completed_at = ? WHERE id = ?`, [now, id]);
        }
        res.send("ACK");
    });
});

app.listen(PORT, '0.0.0.0', () => console.log(`--- ORCHESTRATOR ONLINE (Secure/Test Mode) ---\nAllowed IP Prefix: ${ALLOWED_IP_PREFIX}`));
