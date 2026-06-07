const http = require("http");
const fs = require("fs");
const path = require("path");
const { WebSocketServer } = require("ws");

const PORT = process.env.PORT || 8080;

let creator = null;  // The iOS streamer
let viewer = null;   // The web viewer

// TURN: ExpressTURN (1000 GB/month free, reliable)
const EXPRESSTURN_SERVER = process.env.EXPRESSTURN_SERVER || "free.expressturn.com";
const EXPRESSTURN_USER = process.env.EXPRESSTURN_USER || "efPU52K4SLOQ34W2QY";
const EXPRESSTURN_PASS = process.env.EXPRESSTURN_PASS || "1TJPNFxHKXrZfelz";

function getTurnCredentials() {
  return {
    iceServers: [
      {
        urls: [
          `turn:${EXPRESSTURN_SERVER}:3478`,
          `turn:${EXPRESSTURN_SERVER}:3478?transport=tcp`,
          `turn:${EXPRESSTURN_SERVER}:80`,
          `turn:${EXPRESSTURN_SERVER}:80?transport=tcp`,
          `turns:${EXPRESSTURN_SERVER}:443?transport=tcp`,
        ],
        username: EXPRESSTURN_USER,
        credential: EXPRESSTURN_PASS,
      },
    ],
  };
}

// HTTP server for serving the web viewer
const httpServer = http.createServer((req, res) => {
  if (req.url === "/api/turn") {
    const creds = getTurnCredentials();
    res.writeHead(200, {
      "Content-Type": "application/json",
      "Access-Control-Allow-Origin": "*",
    });
    res.end(JSON.stringify(creds));
    return;
  }

  let filePath = path.join(__dirname, "public", req.url === "/" ? "index.html" : req.url);
  const ext = path.extname(filePath);
  const contentTypes = { ".html": "text/html", ".js": "application/javascript", ".css": "text/css" };

  fs.readFile(filePath, (err, data) => {
    if (err) {
      res.writeHead(404);
      res.end("Not found");
      return;
    }
    res.writeHead(200, { "Content-Type": contentTypes[ext] || "text/plain" });
    res.end(data);
  });
});

// WebSocket signaling server — pairs first two clients
const wss = new WebSocketServer({ server: httpServer });

// Ping all clients every 30s to keep connections alive (especially iOS)
const PING_INTERVAL_MS = 30000;
const pingInterval = setInterval(() => {
  wss.clients.forEach((ws) => {
    if (ws.readyState === 1) {
      ws.ping();
    }
  });
}, PING_INTERVAL_MS);

wss.on("connection", (ws, req) => {
  const clientIP = req.headers["x-forwarded-for"] || req.socket.remoteAddress;
  let role = null;

  ws.on("message", (data) => {
    let msg;
    try {
      msg = JSON.parse(data);
    } catch {
      return;
    }

    switch (msg.type) {
      case "create": {
        // iOS app connects as creator
        if (creator && creator !== ws && creator.readyState === 1) {
          console.log("[WS] New creator replacing old creator");
          creator.close(1000, "Replaced by new creator");
        }
        creator = ws;
        role = "creator";
        ws.send(JSON.stringify({ type: "room_created" }));
        console.log(`[WS] Creator connected from ${clientIP}`);

        // If viewer is already waiting, notify both
        if (viewer && viewer.readyState === 1) {
          ws.send(JSON.stringify({ type: "peer_joined" }));
          viewer.send(JSON.stringify({ type: "peer_joined" }));
          console.log("[WS] Auto-paired: viewer already waiting");
        }
        break;
      }

      case "join": {
        // Web viewer connects
        if (viewer && viewer !== ws && viewer.readyState === 1) {
          console.log("[WS] New viewer replacing old viewer");
          viewer.close(1000, "Replaced by new viewer");
        }
        viewer = ws;
        role = "viewer";
        ws.send(JSON.stringify({ type: "room_joined" }));
        console.log(`[WS] Viewer connected from ${clientIP}`);

        // If creator is already waiting, trigger offer
        if (creator && creator.readyState === 1) {
          creator.send(JSON.stringify({ type: "peer_joined" }));
          console.log("[WS] Auto-paired: creator already waiting");
        }
        break;
      }

      // Relay SDP and ICE candidates and overlay data
      case "offer":
      case "answer":
      case "candidate":
      case "overlay": {
        const target = role === "creator" ? viewer : creator;
        if (target && target.readyState === 1) {
          target.send(JSON.stringify(msg));
          console.log(`[Relay] ${msg.type} ${role} -> ${role === "creator" ? "viewer" : "creator"}`);
        }
        break;
      }
    }
  });

  ws.on("error", (err) => {
    console.log(`[WS] Error for ${role}: ${err.message}`);
  });

  ws.on("close", (code, reason) => {
    console.log(`[WS] ${role} disconnected (code=${code}, reason=${reason || "none"})`);
    if (role === "creator" && creator === ws) {
      creator = null;
      if (viewer && viewer.readyState === 1) {
        viewer.send(JSON.stringify({ type: "peer_left" }));
      }
    } else if (role === "viewer" && viewer === ws) {
      viewer = null;
      if (creator && creator.readyState === 1) {
        creator.send(JSON.stringify({ type: "peer_left" }));
      }
    }
  });
});

httpServer.listen(PORT, "0.0.0.0", () => {
  console.log(`Signaling server running on http://0.0.0.0:${PORT}`);
  console.log(`Web viewer available at http://localhost:${PORT}`);
});
