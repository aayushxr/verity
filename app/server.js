const http = require("http");

const PORT = 3000;
const HOST = "127.0.0.1";
const startTime = Date.now();

let pool = null;

// Connect to PostgreSQL if available
try {
  const { Pool } = require("pg");
  pool = new Pool({
    host: "127.0.0.1",
    database: "verity",
    user: "postgres",
    max: 5,
  });
} catch (_) {
  // pg not available — run without database
}

function json(res, status, data) {
  res.writeHead(status, { "Content-Type": "application/json" });
  res.end(JSON.stringify(data));
}

async function handleHealth(_req, res) {
  const result = { status: "ok" };
  if (pool) {
    try {
      const row = await pool.query("SELECT NOW() AS time");
      result.time = row.rows[0].time;
    } catch (err) {
      result.status = "degraded";
      result.db_error = err.message;
    }
  }
  json(res, 200, result);
}

function handleInfo(_req, res) {
  json(res, 200, {
    name: "verity",
    node: process.version,
    uptime: Math.floor((Date.now() - startTime) / 1000),
    db: pool ? "connected" : "unavailable",
  });
}

const server = http.createServer(async (req, res) => {
  if (req.method === "GET" && req.url === "/api/health") {
    return handleHealth(req, res);
  }
  if (req.method === "GET" && req.url === "/api/info") {
    return handleInfo(req, res);
  }
  json(res, 404, { error: "not found" });
});

server.listen(PORT, HOST, () => {
  console.log(`verity: node api listening on ${HOST}:${PORT}`);
});
