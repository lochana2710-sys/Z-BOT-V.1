const { 
    default: makeWASocket, 
    useMultiFileAuthState, 
    DisconnectReason, 
    downloadContentFromMessage,
    fetchLatestBaileysVersion,
    makeCacheableSignalKeyStore
} = require('@whiskeysockets/baileys');
const { Boom } = require('@hapi/boom');
const pino = require('pino');
const fs = require('fs');
const express = require('express');
const yts = require('yt-search');
const ytdl = require('ytdl-core');
const axios = require('axios');

const app = express();
const PORT = process.env.PORT || 3000;
app.use(express.json());
app.use(express.urlencoded({ extended: true }));

if (!fs.existsSync('./sessions')) fs.mkdirSync('./sessions');

// --- 🛡️ CONFIGURATION ---
const botName = "Z-BOT V1";
const botLogo = "https://ibb.co/pvtzZq0y";

let botSettings = {
    alwaysOnline: true,
    autoStatusSeen: true,
    autoStatusReact: true,
    antiDelete: true,
    antiViewOnce: true,
    useButtons: false,
    ownerNumber: "" // 
};

if (fs.existsSync('./settings.json')) {
    try {
        botSettings = JSON.parse(fs.readFileSync('./settings.json'));
    } catch (e) { console.log("Settings error"); }
}

const saveSettings = () => {
    fs.writeFileSync('./settings.json', JSON.stringify(botSettings, null, 2));
};

// --- WEB PANEL ---
app.get('/', (req, res) => {
    res.send(`<body style="font-family:sans-serif;text-align:center;padding:50px;background:#f0f2f5;">
    <img src="${botLogo}" width="120" style="border-radius:50%; box-shadow: 0 4px 10px rgba(0,0,0,0.1);"><br>
    <h2>🤖 ${botName} SECURE PANEL ✅</h2>
    <p>Status: Running...</p>
    </body>`);
});

const store = {}; 

async function startBot(phoneNumber, res = null) {
    const sessionId = `session_${phoneNumber}`;
    const sessionPath = `./sessions/${sessionId}`;
    if (!fs.existsSync(sessionPath)) fs.mkdirSync(sessionPath, { recursive: true });

    const { state, saveCreds } = await useMultiFileAuthState(sessionPath);
    const { version } = await fetchLatestBaileysVersion();

    const sock = makeWASocket({
        version,
        auth: {
            creds: state.creds,
            keys: makeCacheableSignalKeyStore(state.keys, pino({ level: 'silent' })),
        },
        printQRInTerminal: false,
        logger: pino({ level: 'silent' }),
    });

    sock.ev.on('creds.update', saveCreds);

    sock.ev.on('connection.update', (update) => {
        const { connection, lastDisconnect } = update;
        
        if (connection === 'open') {
            console.log("Connected Successfully!");
            // 🛡️ AUTO DETECT OWNER NUMBER
            const myNum = sock.user.id.split(':')[0];
            if (!botSettings.ownerNumber || botSettings.ownerNumber === "") {
                botSettings.ownerNumber = myNum;
                saveSettings();
                console.log("Owner detected and saved: " + myNum);
            }
            if (botSettings.alwaysOnline) sock.sendPresenceUpdate('available');
        }

        if (connection === 'close') {
            const shouldReconnect = (lastDisconnect.error instanceof Boom)?.output?.statusCode !== DisconnectReason.loggedOut;
            if (shouldReconnect) startBot(phoneNumber);
        }
    });

    if (!sock.authState.creds.registered && phoneNumber && res) {
        setTimeout(async () => {
            try {
                const code = await sock.requestPairingCode(phoneNumber);
                res.send(`<body style="font-family:sans-serif;text-align:center;padding:50px;">
                <div style="border:2px solid #25D366;padding:20px;display:inline-block;border-radius:10px;">
                <h2>${botName} Pairing Code</h2>
                <h1 style="font-size:45px;letter-spacing:5px;color:#25D366;">${code}</h1>
                <p>Link with Phone Number on WhatsApp</p>
                </div></body>`);
            } catch (err) { res.send("Error generating code."); }
        }, 3000);
    }

    sock.ev.on('messages.upsert', async m => {
        const msg = m.messages[0];
        if (!msg.message || msg.key.fromMe) return;

        const from = msg.key.remoteJid;
        const pushName = msg.pushName || "User";
        const sender = msg.key.participant || msg.key.remoteJid;
        
        // 🛡️ SECURITY: CHECK IF SENDER IS OWNER
        const isOwner = sender.includes(botSettings.ownerNumber); 
        const prefix = ".";

        // Auto Status
        if (from === 'status@broadcast') {
            if (botSettings.autoStatusSeen) await sock.readMessages([msg.key]);
            if (botSettings.autoStatusReact) {
                await sock.sendMessage(from, { react: { text: '❤️', key: msg.key } }, { statusJidList: [msg.key.participant] });
            }
            return;
        }

        // View Once Bypass
        const isViewOnce = msg.message.viewOnceMessageV2 || msg.message.viewOnceMessage;
        if (isViewOnce && botSettings.antiViewOnce) {
            try {
                const viewOnceData = isViewOnce.message.imageMessage || isViewOnce.message.videoMessage;
                const mType = isViewOnce.message.imageMessage ? 'image' : 'video';
                const stream = await downloadContentFromMessage(viewOnceData, mType);
                let buffer = Buffer.from([]);
                for await (const chunk of stream) buffer = Buffer.concat([buffer, chunk]);
                await sock.sendMessage(sock.user.id, { [mType]: buffer, caption: `*🛡️ ${botName} VO BYPASS*\nSender: @${sender.split('@')[0]}`, mentions: [sender] });
            } catch (e) { console.log("VO Error"); }
        }

        store[msg.key.id] = JSON.parse(JSON.stringify(msg));
        const text = (msg.message.conversation || msg.message.extendedTextMessage?.text || (msg.message.imageMessage && msg.message.imageMessage.caption) || "").toLowerCase();
        const command = text.startsWith(prefix) ? text.slice(prefix.length).trim().split(' ')[0] : "";
        const args = text.trim().split(/ +/).slice(1);

        // --- SETTINGS COMMAND ---
        if (command === 'set' || command === 'settings') {
            if (!isOwner) return sock.sendMessage(from, { text: "❌ Only my Owner can use this command!" }, { quoted: msg });
            
            const subCmd = args[0];
            const value = args[1];
            if (!subCmd) {
                let statusMsg = `*🛡️ [ ${botName} SETTINGS ] ──*\n\n`;
                statusMsg += `🟢 Online: ${botSettings.alwaysOnline ? 'ON' : 'OFF'}\n`;
                statusMsg += `👁️ Status Seen: ${botSettings.autoStatusSeen ? 'ON' : 'OFF'}\n`;
                statusMsg += `❤️ Status React: ${botSettings.autoStatusReact ? 'ON' : 'OFF'}\n`;
                statusMsg += `🛡️ Anti-Delete: ${botSettings.antiDelete ? 'ON' : 'OFF'}\n`;
                statusMsg += `📸 Anti-VO: ${botSettings.antiViewOnce ? 'ON' : 'OFF'}\n`;
                statusMsg += `🔘 Buttons: ${botSettings.useButtons ? 'ON' : 'OFF'}\n\n`;
                statusMsg += `*Owner:* ${botSettings.ownerNumber}\n\n`;
                statusMsg += `*Commands:* .set [feature] [on/off]`;
                return await sock.sendMessage(from, { image: { url: botLogo }, caption: statusMsg }, { quoted: msg });
            }
            if (value === 'on' || value === 'off') {
                const boolValue = (value === 'on');
                if (subCmd === 'online') botSettings.alwaysOnline = boolValue;
                else if (subCmd === 'status') botSettings.autoStatusSeen = boolValue;
                else if (subCmd === 'react') botSettings.autoStatusReact = boolValue;
                else if (subCmd === 'delete') botSettings.antiDelete = boolValue;
                else if (subCmd === 'viewonce') botSettings.antiViewOnce = boolValue;
                else if (subCmd === 'buttons') botSettings.useButtons = boolValue;
                saveSettings();
                await sock.sendMessage(from, { text: `✅ *${subCmd}* is now *${value.toUpperCase()}*` }, { quoted: msg });
            }
        }

        // MENU
        if (command === 'menu') {
            let menuTxt = `*👋 Hello ${pushName}!*\nWelcome to *${botName}*\n\n`;
            menuTxt += `📥 *DOWNLOADS*\n.song | .video | .tt | .fb\n\n`;
            menuTxt += `🛠️ *SYSTEMS*\n.set | .ping | .s (Sticker)\n\n`;
            menuTxt += `_© Secure Automation_`;
            await sock.sendMessage(from, { image: { url: botLogo }, caption: menuTxt }, { quoted: msg });
        }

        // DOWNLOADERS (Simple YT Example)
        if (command === 'song') {
            if (!args[0]) return sock.sendMessage(from, { text: "Please provide a song name." });
            try {
                const search = await yts(args.join(" "));
                const video = search.videos[0];
                await sock.sendMessage(from, { text: `🎧 Downloading: *${video.title}*` });
                const stream = ytdl(video.url, { filter: 'audioonly' });
                let chunks = [];
                stream.on('data', c => chunks.push(c));
                stream.on('end', async () => {
                    await sock.sendMessage(from, { audio: Buffer.concat(chunks), mimetype: 'audio/mp4' }, { quoted: msg });
                });
            } catch (e) { sock.sendMessage(from, { text: "Download error." }); }
        }

        if (command === 'ping') await sock.sendMessage(from, { text: `*Pong!* ⚡` });

        if (command === 's' || command === 'sticker') {
            let target = msg.message.imageMessage ? msg.message : (msg.message.extendedTextMessage?.contextInfo?.quotedMessage?.imageMessage ? msg.message.extendedTextMessage.contextInfo.quotedMessage : null);
            if (target) {
                const stream = await downloadContentFromMessage(target, 'image');
                let buffer = Buffer.from([]);
                for await (const chunk of stream) buffer = Buffer.concat([buffer, chunk]);
                await sock.sendMessage(from, { sticker: buffer });
            }
        }
    });

    // ANTI-DELETE
    sock.ev.on('messages.update', async (chatUpdate) => {
        if (!botSettings.antiDelete) return;
        for (const { key, update } of chatUpdate) {
            if (update.protocolMessage && update.protocolMessage.type === 14) {
                const original = store[update.protocolMessage.key.id];
                if (original) {
                    const sender = update.protocolMessage.key.participant || update.protocolMessage.key.remoteJid;
                    const content = original.message.conversation || original.message.extendedTextMessage?.text || "Media File";
                    await sock.sendMessage(sock.user.id, { text: `*🛡️ ANTI-DELETE ALERT*\nFrom: @${sender.split('@')[0]}\nMessage: ${content}`, mentions: [sender] });
                }
            }
        }
    });
}

// Start existing sessions
if (fs.existsSync('./sessions')) {
    fs.readdirSync('./sessions').forEach(folder => {
        const num = folder.replace('session_', '');
        if (num && !isNaN(num)) startBot(num).catch(e => console.log(e));
    });
}

app.post('/getcode', async (req, res) => {
    let num = req.body.number.replace(/[^0-9]/g, '');
    if (num.startsWith('94')) startBot(num, res).catch(e => res.send("Error"));
});

app.listen(PORT, () => console.log(`${botName} is ready!`));

