// 常驻翻译服务：维持一个 agy 进程（stream-json 双向模式），通过本机 HTTP 接收翻译请求。
// 这样 agy 的启动和账号检查（约 3~5 秒）只在服务启动时做一次，之后每条翻译只剩模型生成的时间。
//
// 用法：node agy-server.js <port> <model> <token> <父进程 PID>
// 接口：POST /translate?to=zh|en   请求头 X-Token: <token>   请求体：原文（UTF-8）
//       返回 200 + 译文（text/plain; charset=utf-8），出错返回 500 + 错误信息
"use strict";
const http = require("http");
const fs = require("fs");
const os = require("os");
const path = require("path");
const { spawn } = require("child_process");

const [PORT, MODEL, TOKEN, PARENT_PID] = [Number(process.argv[2]), process.argv[3], process.argv[4], Number(process.argv[5])];
const AGY = path.join(process.env.LOCALAPPDATA, "agy", "bin", "agy.exe");
const WORK_DIR = path.join(__dirname, "workspace");
// 最简翻译 agent（workspace/.agents/agents/translator/agent.md）：不带工具，翻译规则写在它的系统提示里。
// 比默认 agent 每条少发约 80% 的 token（约 2.3k 对 12k），速度更稳定
const AGENT = "translator";
const LOG_FILE = path.join(os.tmpdir(), "gemini-translate", "agy-server.log");
const MAX_TURNS = 30;            // 同一个对话最多翻译这么多条，之后换新对话，避免历史越积越长
const TURN_TIMEOUT_MS = 45000;   // 单条翻译超过这个时间就判定失败

fs.mkdirSync(WORK_DIR, { recursive: true });
fs.mkdirSync(path.dirname(LOG_FILE), { recursive: true });
fs.writeFileSync(LOG_FILE, "");
const log = (msg) => fs.appendFileSync(LOG_FILE, `${new Date().toISOString()} ${msg}\n`);

// ---------------- agy 会话 ----------------

class Session {
  constructor() {
    this.turns = 0;
    this.pending = null;
    this.dead = false;
    this.startedAt = Date.now();
    this.child = spawn(AGY, ["--input-format", "stream-json", "--output-format", "stream-json",
      "--disable-slash-commands", "--model", MODEL, "--agent", AGENT], { cwd: WORK_DIR, windowsHide: true });
    log(`session start pid=${this.child.pid} agent=${AGENT}`);
    let buf = "";
    this.child.stdout.on("data", (d) => {
      buf += d.toString("utf8");
      let i;
      while ((i = buf.indexOf("\n")) >= 0) {
        const line = buf.slice(0, i).trim();
        buf = buf.slice(i + 1);
        if (line) this.onEvent(line);
      }
    });
    this.child.stderr.on("data", (d) => log(`agy stderr: ${d.toString("utf8").trim()}`));
    this.child.on("error", (e) => this.onExit(`spawn error: ${e.message}`));
    this.child.on("close", (code) => this.onExit(`exit code=${code}`));
  }

  onEvent(line) {
    let ev;
    try { ev = JSON.parse(line); } catch { return; }
    if (ev.event === "init") {
      log(`session ready in ${Date.now() - this.startedAt} ms`);
    } else if (ev.event === "result" && this.pending) {
      const { resolve, reject, timer } = this.pending;
      this.pending = null;
      clearTimeout(timer);
      const r = ev.result || {};
      if (r.status === "SUCCESS") resolve(String(r.response || "").trim());
      else reject(new Error(`agy 返回 ${r.status}: ${r.error || JSON.stringify(r).slice(0, 300)}`));
    }
  }

  onExit(reason) {
    if (this.dead) return;
    this.dead = true;
    log(`session ended: ${reason}`);
    if (this.pending) {
      clearTimeout(this.pending.timer);
      this.pending.reject(new Error(`agy 进程退出（${reason}）`));
      this.pending = null;
    }
  }

  send(prompt) {
    return new Promise((resolve, reject) => {
      if (this.dead) return reject(new Error("agy 进程已退出"));
      const timer = setTimeout(() => {
        this.pending = null;
        reject(new Error(`超过 ${TURN_TIMEOUT_MS / 1000} 秒没有返回`));
        this.close(); // 卡住的会话直接丢掉，下次换新的
      }, TURN_TIMEOUT_MS);
      this.pending = { resolve, reject, timer };
      this.turns++;
      this.child.stdin.write(JSON.stringify({ event: "user", message: { content: prompt } }) + "\n");
    });
  }

  close() {
    if (this.dead) return;
    try { this.child.stdin.end(); } catch {}
    setTimeout(() => { try { this.child.kill(); } catch {} }, 3000);
  }
}

let session = new Session(); // 服务一启动就预热
function currentSession() {
  if (session.dead || session.turns >= MAX_TURNS) {
    session.close();
    session = new Session();
  }
  return session;
}

// ---------------- 翻译 ----------------

// 翻译规则在 translator agent 的系统提示里，每条消息只需给出目标语言和原文
function buildPrompt(text, to) {
  const target = to === "en" ? "英文" : "简体中文";
  return `翻译成${target}：\n<text>\n${text}\n</text>`;
}

async function translate(text, to) {
  const t0 = Date.now();
  try {
    return await currentSession().send(buildPrompt(text, to));
  } catch (e) {
    // 会话可能因为长时间闲置、网络中断等原因很快失败：换一个新会话重试一次。
    // 如果是等了很久才失败（比如超时），就不再重试，免得用户等太久
    if (Date.now() - t0 > 10000) throw e;
    log(`turn failed, retrying with a new session: ${e.message}`);
    session.close();
    session = new Session();
    return await session.send(buildPrompt(text, to));
  }
}

// agy 一次只能处理一条，请求按顺序排队；客户端已经放弃的请求直接跳过
let queue = Promise.resolve();

const server = http.createServer((req, res) => {
  const url = new URL(req.url, "http://127.0.0.1");
  if (req.method !== "POST" || url.pathname !== "/translate" || req.headers["x-token"] !== TOKEN) {
    res.writeHead(404).end();
    return;
  }
  const chunks = [];
  req.on("data", (c) => chunks.push(c));
  req.on("end", () => {
    const text = Buffer.concat(chunks).toString("utf8");
    const to = url.searchParams.get("to") === "en" ? "en" : "zh";
    let abandoned = false;
    res.on("close", () => { if (!res.writableEnded) abandoned = true; });
    queue = queue.then(async () => {
      if (abandoned) return;
      const t0 = Date.now();
      try {
        const out = await translate(text, to);
        log(`translate ok in ${Date.now() - t0} ms (turn ${session.turns}, ${text.length} chars)${abandoned ? " — but client already gave up" : ""}`);
        if (!abandoned) res.writeHead(200, { "Content-Type": "text/plain; charset=utf-8" }).end(out);
      } catch (e) {
        log(`translate failed in ${Date.now() - t0} ms: ${e.message}`);
        if (!abandoned) res.writeHead(500, { "Content-Type": "text/plain; charset=utf-8" }).end(e.message);
      }
    });
  });
});

// 上一个实例可能还没完全退出，端口被占用时等一会儿再试
let bindAttempts = 0;
server.on("error", (e) => {
  if (e.code === "EADDRINUSE" && ++bindAttempts < 20) {
    setTimeout(() => server.listen(PORT, "127.0.0.1"), 500);
  } else {
    log(`server error: ${e.message}`);
    process.exit(1);
  }
});
server.listen(PORT, "127.0.0.1", () => log(`listening on 127.0.0.1:${PORT}, model=${MODEL}`));

// AHK 脚本退出（包括崩溃）后，服务和 agy 一起退出
setInterval(() => {
  try { process.kill(PARENT_PID, 0); } catch {
    log("parent gone, exiting");
    session.close();
    setTimeout(() => process.exit(0), 500);
  }
}, 1000);
