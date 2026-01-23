/* RANGE IMPORTER
   - Imports a list of hex ranges from a text file.
   - Marks them as 'DONE' so the Orchestrator skips them.
   - Uses .env for configuration.
*/

import 'dotenv/config'; // Load .env
import sqlite3 from 'sqlite3';
import fs from 'fs';
import readline from 'readline';
import path from 'path';

// --- CONFIGURATION ---
// Use the same DB_PATH as the server to ensure we write to the right place
const DB_PATH = process.env.DB_PATH || path.join(process.cwd(), 'mining.db');
// You can add IMPORT_FILE to .env or just default to local file
const DATA_FILE = process.env.IMPORT_FILE || path.join(process.cwd(), 'searched_ranges.txt');

const STATUS = 'DONE';

function connectToDb() {
    return new sqlite3.Database(DB_PATH);
}

async function processLineByLine() {
    const db = connectToDb();

    db.serialize(() => {
        // 1. MATCH SERVER SCHEMA EXACTLY
        // We use the exact same CREATE statement as server.js to ensure compatibility
        db.run(`CREATE TABLE IF NOT EXISTS ranges (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            start_hex TEXT UNIQUE,
            end_hex TEXT,
            status TEXT DEFAULT 'PROCESSING',
            assigned_to TEXT,
            started_at INTEGER,
            completed_at INTEGER
        )`);

        // 2. PREPARE STATEMENT
        // We use INSERT OR IGNORE to skip ranges that already exist in the DB
        const stmt = db.prepare("INSERT OR IGNORE INTO ranges (start_hex, end_hex, status, assigned_to, completed_at) VALUES (?, ?, ?, ?, ?)");

        if (!fs.existsSync(DATA_FILE)) {
            console.error(`[ERROR] File not found: ${DATA_FILE}`);
            return;
        }

        const fileStream = fs.createReadStream(DATA_FILE);

        const rl = readline.createInterface({
            input: fileStream,
            crlfDelay: Infinity
        });

        let count = 0;

        console.log(`--- STARTING IMPORT FROM ${DATA_FILE} ---`);
        console.log(`Target DB: ${DB_PATH}`);

        rl.on('line', (line) => {
            const startHex = line.trim();
            if (startHex) {
                // We use Date.now() for completed_at because server.js expects an Integer timestamp
                stmt.run(startHex, "IMPORTED_FROM_LIST", STATUS, "COMMUNITY_DATA", Date.now());

                count++;
                if (count % 1000 === 0) process.stdout.write(`\rImported: ${count}`);
            }
        });

        rl.on('close', () => {
            stmt.finalize();
            console.log(`\n\n[SUCCESS] Imported ${count} ranges as 'DONE'.`);
            db.close();
        });
    });
}

processLineByLine();