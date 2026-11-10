// freenet.js: minimal browser client for Freenet web apps (no dependencies).
// Copyright (c) 2026 holdmylatte. MIT License: https://opensource.org/license/mit
//
// In your page, load it with a script tag whose src is "freenet.js".
// `freenet-pack` writes this file, plus the table of your embedded delegates
// and contracts, into the site archive as `freenet.js`.
//
//   const client = await FreenetClient.connect();
//
//   // delegates: private logic on the user's node
//   const random = await client.delegate("random");
//   const [n] = await random.sendText("random");
//   const earlier = client.delegateAt(codeHashOfAnEarlierBuild); // already on the node
//
//   // contracts: shared state on the network
//   const room = client.contract("chat", ownerKeyBytes);   // parameters
//   await room.put(initialState);                           // create (once)
//   await room.subscribe((u) => render(u.state ?? u.delta));
//   await room.follow((state) => render(state));            // a copy kept in step, by deltas
//   await room.update(delta);
//
// Speaks the node's WebSocket API with ?encodingProtocol=native (bincode).
// Only `FreenetClient` is added to the page's globals. `FreenetClient.Error`
// is the error class for refusals from the node, and `FreenetClient.util` has
// the helpers pages need to work with ids: blake3, base58Encode, base58Decode,
// hexToBytes, bytesToHex, concatBytes.
(() => {
"use strict";

/** How long a timed-out request's late answer is still recognized (and dropped). */
const ORPHAN_MS = 5 * 60 * 1000;

class FreenetClient {
  /** Filled in by freenet-pack: { name: { wasm: base64, key: hex, codeHash: hex, parameters: hex } } */
  static embedded = {};
  /** Filled in by freenet-pack: this web app's contract id (hex), the parameters of its delegates. */
  static appId = null;
  /** Filled in by freenet-pack: { name: { wasm: base64, codeHash: hex } } */
  static contracts = {};
  /** How long the client waits for any sign of the node after a request timed out, before reconnecting. */
  static probeMs = 10000;
  /**
   * Extra connections ("lanes") for contract requests, so a slow one doesn't
   * hold up the rest: a connection answers one request at a time (replies
   * carry no request id). 0: everything on the one connection.
   */
  static lanes = 4;
  /** How long a lane stays open with nothing to do. */
  static laneIdleMs = 60000;

  /**
   * Connect to the local node (the page's own host when served by Freenet).
   * Options: url, reconnect (default true: after the connection is lost, or
   * after the node stops answering, reconnect every 2 s), onStatus(status)
   * with status one of "connecting" | "open" | "closed", lanes (default
   * `FreenetClient.lanes`: extra connections for contract gets, puts and
   * updates, opened when first needed; see `_contractRequest`).
   */
  static connect(options = {}) {
    const client = new FreenetClient(options);
    return client._open().then(() => client);
  }

  constructor({ url, reconnect = true, onStatus = () => {}, lanes = FreenetClient.lanes } = {}) {
    this.url = url ?? FreenetClient.defaultUrl();
    this.reconnect = reconnect;
    this.onStatus = onStatus;
    this._laneCount = Math.max(0, Math.floor(lanes) || 0);
    this._lanes = [];                // index -> { client, ready, busy, timer }: see _contractRequest
    this._inflight = null;           // the request awaiting an answer (one at a time)
    this._queue = Promise.resolve(); // serializes requests
    this._registered = new Map();    // delegate name -> Promise<DelegateHandle>
    this._listeners = new Map();     // contract id hex -> Set of callbacks
    this._subscribed = new Map();    // contract id hex -> Promise (subscription on this connection)
    this._summaries = new Map();     // contract id hex -> summary of the page's copy (`follow`), sent when subscribing
    this._followers = new Map();     // contract id hex -> Follower
    this._runners = new Map();       // code hash hex -> ContractRunner
    this._streams = new Map();       // stream id -> chunks of a large response
    this._everOpened = false;
    this._closing = false;
    this._openWaiters = new Set();   // requests waiting for a reconnect: { resolve, reject }
    this._orphans = [];              // timed-out requests whose late answers are dropped: { expects, contract, at }
    this._suspect = false;           // a request timed out: is the node still there? (see _request)
    this._timedOutAt = 0;
    this._lastHeard = 0;             // when the node last sent anything
  }

  static defaultUrl() {
    const proto = location.protocol === "https:" ? "wss" : "ws";
    return `${proto}://${location.host}/v1/contract/command?encodingProtocol=native`;
  }

  /**
   * Keeps the page's `#` route in the address bar, so a reload or a copied
   * link opens the same view. The page runs in the node's shell page, inside
   * a sandboxed iframe: its hash isn't the one the browser shows or reloads.
   * The shell copies its own hash into the iframe when it loads it, takes a
   * `{ type: "hash" }` message from the page (and replaces its address with
   * it, adding no history entry), and sends one back on back/forward or an
   * edited address. This sends the page's hash now and on every
   * `hashchange`, and follows the shell's. Call it once, connected or not;
   * outside a shell (a page opened directly) it does nothing. After changing
   * the hash without a `hashchange` (`history.replaceState`), call
   * `FreenetClient.shareHash()`.
   */
  static syncHash() {
    if (FreenetClient._hashSynced || typeof window === "undefined" || !window.parent || window.parent === window) return;
    FreenetClient._hashSynced = true;
    window.addEventListener("hashchange", () => FreenetClient.shareHash());
    window.addEventListener("message", (e) => {
      const m = e.data;
      if (e.source !== window.parent || !m || m.__freenet_shell__ !== true || m.type !== "hash") return;
      if (typeof m.hash !== "string" || m.hash.charAt(0) !== "#" || m.hash.length > 8192) return;
      if (m.hash !== (location.hash || "#")) location.hash = m.hash;
    });
    FreenetClient.shareHash();
  }

  /** Sends the page's hash to the shell page now (see `syncHash`); "#" for none. */
  static shareHash() {
    if (typeof window === "undefined" || !window.parent || window.parent === window) return;
    const hash = (location.hash || "#").slice(0, 8192);
    if (hash === FreenetClient._sharedHash) return;
    FreenetClient._sharedHash = hash;
    window.parent.postMessage({ __freenet_shell__: true, type: "hash", hash }, "*");
  }

  // ---- delegates ----

  /** Register an embedded delegate (once) and return a handle to message it. */
  delegate(name) {
    let pending = this._registered.get(name);
    if (!pending) {
      const spec = FreenetClient.embedded[name];
      if (!spec) return Promise.reject(new Error(`no embedded delegate named "${name}" (check addWebApp's delegates)`));
      const handle = new DelegateHandle(this, name, {
        wasm: b64ToBytes(spec.wasm), key: hexToBytes(spec.key), codeHash: hexToBytes(spec.codeHash),
        parameters: hexToBytes(spec.parameters ?? ""), // the web app's id, see Delegate.requireApp
      });
      pending = this._register(handle).then(() => handle);
      this._registered.set(name, pending);
      pending.catch(() => this._registered.delete(name)); // allow a retry
    }
    return pending;
  }

  /**
   * A handle to a delegate this page doesn't embed, by its code hash (hex,
   * base58 or bytes) and parameters (Uint8Array or string; default: this
   * app's id, which freenet-pack gives every delegate it embeds). Its key is
   * BLAKE3(code hash ‖ parameters). Nothing is registered, so it answers
   * only if the node already has it, such as this app's delegate from an
   * earlier build; otherwise `send` rejects with a FreenetError.
   */
  delegateAt(codeHash, parameters) {
    if (parameters === undefined && FreenetClient.appId == null)
      throw new TypeError("delegateAt needs parameters: this page has no app id (not packed by freenet-pack)");
    const hash = bytes32(codeHash, "code hash");
    const params = parameters === undefined ? hexToBytes(FreenetClient.appId) : toBytes(parameters);
    const key = blake3(concatBytes(hash, params));
    return new DelegateHandle(this, `at ${base58Encode(key)}`, { wasm: null, key, codeHash: hash, parameters: params });
  }

  // ---- contracts ----

  /**
   * A handle to the instance of embedded contract `name` with `parameters`
   * (Uint8Array or string; default empty). The id is computed locally.
   */
  contract(name, parameters = new Uint8Array(0)) {
    const spec = FreenetClient.contracts[name];
    if (!spec) throw new Error(`no embedded contract named "${name}" (check addWebApp's contracts)`);
    const params = toBytes(parameters);
    const codeHash = hexToBytes(spec.codeHash);
    const id = blake3(concatBytes(codeHash, params));
    return new ContractHandle(this, { id, codeHash, parameters: params, wasm: () => b64ToBytes(spec.wasm) });
  }

  /**
   * A handle to an existing contract instance by id (base58 string as Freenet
   * prints it, or 32 bytes). `codeHash` (hex, base58 or bytes) is needed for
   * `update`; it's also learned from `get`.
   */
  contractAt(id, codeHash) {
    return new ContractHandle(this, {
      id: bytes32(id, "contract id"),
      codeHash: codeHash == null ? null : bytes32(codeHash, "code hash"),
    });
  }

  close() {
    this._closing = true;
    for (const w of this._openWaiters) w.reject(new Error("not connected"));
    this._openWaiters.clear();
    for (const lane of this._lanes) if (lane) { clearTimeout(lane.timer); lane.client.close(); }
    this._lanes = [];
    this.ws?.close();
  }

  // ---- internals ----

  _open() {
    return new Promise((resolve, reject) => {
      this.onStatus("connecting");
      const ws = new WebSocket(this.url);
      ws.binaryType = "arraybuffer";
      this.ws = ws;
      let opened = false;
      ws.onopen = async () => {
        opened = true;
        this._everOpened = true;
        // Requests that waited for this reconnect go first; re-registering
        // queues behind them (it would wait for them anyway).
        if (this.ws === ws) {
          for (const w of this._openWaiters) w.resolve();
          this._openWaiters.clear();
        }
        // After a reconnect: register delegates and renew subscriptions again.
        // A failure is logged, not fatal; if the connection drops meanwhile,
        // onclose takes over.
        for (const pending of [...this._registered.values()]) {
          const handle = await pending.catch(() => null);
          if (handle) await this._register(handle).catch((err) => console.warn("freenet.js:", err.message));
        }
        for (const [idHex, set] of this._listeners) {
          if (set.size > 0) await this._ensureSubscribed(hexToBytes(idHex), idHex).catch((err) => console.warn("freenet.js:", err.message));
        }
        if (this.ws !== ws) return reject(new Error("connection closed"));
        this.onStatus("open");
        resolve();
      };
      ws.onmessage = (event) => {
        // Ignore a socket we already gave up on (e.g. after a timeout).
        if (this.ws === ws && ws.readyState === WebSocket.OPEN) this._handle(new Uint8Array(event.data));
      };
      ws.onclose = () => {
        if (this.ws !== ws) return;
        this.ws = null;
        if (this._inflight) {
          const entry = this._inflight;
          this._inflight = null;
          clearTimeout(entry.timer);
          entry.reject(new Error("connection closed"));
        }
        this._streams.clear();
        this._subscribed.clear();
        this._orphans = [];
        this._suspect = false;
        this.onStatus("closed");
        if (!opened) reject(new Error(`cannot connect to ${this.url}`));
        // Only a client that connected once reconnects; a failed first
        // connect just rejects `connect()`.
        if (this._everOpened && this.reconnect && !this._closing) {
          setTimeout(() => this._open().catch(() => {}), 2000);
        }
      };
    });
  }

  _handle(bytes) {
    this._lastHeard = Date.now();
    let res;
    try { res = parseHostResponse(bytes); } catch (err) { console.warn("freenet.js: bad message", err); return; }
    switch (res.kind) {
      case "chunk": return this._chunk(res);
      case "streamHeader": return;
      case "notification": {
        const listeners = this._listeners.get(bytesToHex(res.key.id));
        listeners?.forEach((fn) => { try { fn(res.update); } catch (err) { console.error(err); } });
        return;
      }
    }
    let entry = this._inflight;
    // A liveness probe (see _request) is answered by anything the node
    // sends: the node is there. Its own answer may still come; it's dropped.
    if (entry && entry.probe) {
      this._inflight = null;
      clearTimeout(entry.timer);
      if (!entry.expects(res)) this._orphans.push({ expects: entry.expects, contract: null, at: Date.now() });
      entry.resolve(res);
      if (entry.expects(res) || res.kind === "error") return;
      entry = null;
    }
    // Replies carry no request id. A reply the request in flight expects
    // (its kind, for its contract) is its answer; one only a request that
    // timed out expects is that one's late answer, and is dropped (requests
    // name their contract, so the two can only be confused for the same
    // contract, where either answer is that contract's). An error names its
    // contract only sometimes: one naming a timed-out request's contract
    // (and not the one in flight) is that request's; any other goes to the
    // one in flight.
    if (res.kind === "error") {
      const text = `${res.error.contract ?? ""} ${res.error.message ?? ""}`;
      const mentions = (c) => !!c && text.includes(c);
      const i = this._orphans.findIndex((o) => mentions(o.contract));
      if (i >= 0 && !(entry && mentions(entry.contract))) { this._orphans.splice(i, 1); return; }
    } else if (!entry || !entry.expects(res)) {
      const i = this._orphans.findIndex((o) => o.expects(res));
      if (i >= 0) this._orphans.splice(i, 1);
      return;
    }
    if (!entry) return;
    this._inflight = null;
    clearTimeout(entry.timer);
    if (res.kind === "error") entry.reject(new FreenetError(res.error)); else entry.resolve(res);
  }

  // Large responses (> 512 KiB) arrive as StreamChunks of the serialized response.
  _chunk({ streamId, index, total, data }) {
    let s = this._streams.get(streamId);
    if (!s) this._streams.set(streamId, s = { parts: new Array(total), received: 0 });
    if (s.parts[index] === undefined) { s.parts[index] = data.slice(); s.received++; }
    if (s.received === total) {
      this._streams.delete(streamId);
      this._handle(concatBytes(...s.parts));
    }
  }

  // Requests on a connection go out one at a time: replies carry no request
  // id, so the next request is sent only after the previous one was answered
  // or failed (contract requests have lanes of their own: _contractRequest). A
  // request the node doesn't answer within `timeoutMs` fails alone: on a
  // network node a contract nobody has yet can go unanswered for long. Its
  // late answer, if any, is dropped (see _handle). Before the next request
  // goes out, the client asks the node something every node answers at once
  // (NodeQueries: ConnectedPeers); if nothing at all comes back within
  // `FreenetClient.probeMs`, the node is gone: the connection is dropped (and reconnects,
  // if enabled) and the request waits for the new one. Subscriptions survive
  // a timeout. A request made while the client reconnects waits for the new
  // connection, up to its timeout. `contract` (base58) names the contract a
  // request is about, to tell its late errors from the next request's.
  _request(bytes, expects, timeoutMs = 30000, contract = null) {
    const run = async () => {
      if (!this._isOpen() && this._everOpened && this.reconnect && !this._closing) await this._reopened(timeoutMs);
      if (this._suspect) await this._checkAlive(timeoutMs);
      return this._send(bytes, expects, timeoutMs, contract);
    };
    const result = this._queue.then(run, run);
    this._queue = result.catch(() => {});
    return result;
  }

  _send(bytes, expects, timeoutMs, contract, probe = false) {
    return new Promise((resolve, reject) => {
      const ws = this.ws;
      if (!ws || ws.readyState !== WebSocket.OPEN) return reject(new Error("not connected"));
      const entry = { resolve, reject, expects, contract, probe };
      entry.timer = setTimeout(() => {
        if (this._inflight !== entry) return;
        this._inflight = null;
        const now = Date.now();
        this._orphans = this._orphans.filter((o) => now - o.at < ORPHAN_MS);
        this._orphans.push({ expects, contract, at: now });
        if (!probe) {
          this._suspect = true;
          this._timedOutAt = now;
          console.warn(`freenet.js: the node didn't answer within ${timeoutMs / 1000} s${contract ? ` (${contract})` : ""}`);
        }
        const err = new Error("timed out waiting for the node");
        err.timedOut = true;
        reject(err);
      }, timeoutMs);
      this._inflight = entry;
      ws.send(bytes);
    });
  }

  // After a timeout: is the node still there? Anything it sent since says
  // yes; otherwise a probe that anything answers. No answer: reconnect.
  async _checkAlive(timeoutMs) {
    if (this._lastHeard > this._timedOutAt) { this._suspect = false; return; }
    const ws = this.ws;
    try {
      // ClientRequest::NodeQueries(NodeQuery::ConnectedPeers)
      await this._send(new Writer().u32(4).u32(0).finish(), (r) => r.kind === "query", FreenetClient.probeMs, null, true);
    } catch (err) {
      if (!err.timedOut) { this._suspect = false; return; } // an error is an answer too
      console.warn(`freenet.js: the node didn't answer within ${FreenetClient.probeMs / 1000} s; reconnecting`);
      if (this.ws === ws) ws.close();
      if (!this.reconnect || this._closing) throw new Error("not connected");
      await this._reopened(timeoutMs);
      return;
    }
    this._suspect = false;
  }

  // Contract gets, puts and updates go out on lanes: up to `lanes` extra
  // connections, so a request the node is slow to answer (on a network node,
  // a contract nobody has can take seconds) holds up only its own lane. The
  // contract's id picks the lane (ids are hashes, so they spread evenly):
  // every get, put and update of one contract goes out on the same lane, in
  // the order the page made them, so a write and a later read of a contract
  // can't pass each other. Subscriptions (and a get or put that subscribes),
  // their notifications, and delegates stay on the main connection: a
  // subscription belongs to the connection that made it. A lane is a client
  // of its own (its own queue, timeout and liveness probe, reconnecting by
  // itself), opened when first needed and closed after `laneIdleMs` with
  // nothing to do. If it can't be opened, the request goes out on the main
  // connection.
  async _contractRequest(id, bytes, expects, timeoutMs, contract) {
    if (!this._laneCount || this._closing) return this._request(bytes, expects, timeoutMs, contract);
    const i = id[0] % this._laneCount;
    let lane = this._lanes[i];
    if (!lane) {
      const client = new FreenetClient({ url: this.url, reconnect: this.reconnect, lanes: 0 });
      lane = { client, ready: client._open(), busy: 0, timer: null };
      this._lanes[i] = lane;
      const opened = lane;
      lane.ready.catch(() => { if (this._lanes[i] === opened) this._lanes[i] = null; });
    }
    lane.busy++;
    clearTimeout(lane.timer);
    try {
      try { await lane.ready; } catch { return await this._request(bytes, expects, timeoutMs, contract); }
      return await lane.client._request(bytes, expects, timeoutMs, contract);
    } finally {
      if (--lane.busy === 0 && this._lanes[i] === lane) {
        lane.timer = setTimeout(() => {
          if (lane.busy || this._lanes[i] !== lane) return;
          this._lanes[i] = null;
          lane.client.close();
        }, FreenetClient.laneIdleMs);
      }
    }
  }

  _isOpen() {
    return !!this.ws && this.ws.readyState === WebSocket.OPEN;
  }

  // Resolves when a reconnect opens the socket; rejects after `timeoutMs`.
  _reopened(timeoutMs) {
    return new Promise((resolve, reject) => {
      const waiter = {
        resolve: () => { clearTimeout(timer); resolve(); },
        reject: (err) => { clearTimeout(timer); reject(err); },
      };
      const timer = setTimeout(() => { this._openWaiters.delete(waiter); reject(new Error("not connected")); }, timeoutMs);
      this._openWaiters.add(waiter);
    });
  }

  async _register(handle) {
    // ClientRequest::DelegateOp(DelegateRequest::RegisterDelegate { delegate, cipher, nonce })
    const req = new Writer()
      .u32(0).u32(1)            // DelegateOp, RegisterDelegate
      .u32(0).u32(0)            // DelegateContainer::Wasm, DelegateWasmAPIVersion::V1
      .bytes(handle.parameters) // Delegate.parameters
      .bytes(handle.wasm)       // Delegate.data.data
      .raw(handle.codeHash)     // Delegate.data.code_hash
      .raw(handle.key)          // Delegate.key.key
      .raw(handle.codeHash)     // Delegate.key.code_hash
      .raw(new Uint8Array(32))  // cipher (ignored by current nodes)
      .raw(new Uint8Array(24))  // nonce  (ignored by current nodes)
      .finish();
    try {
      await this._request(req, (r) => r.kind === "delegate" || r.kind === "ok");
    } catch (err) {
      // A refusal from the node (e.g. already registered) is not fatal;
      // messages will tell. Connection problems are.
      if (!(err instanceof FreenetError)) throw err;
      console.warn(`freenet.js: RegisterDelegate(${handle.name}):`, err.message);
    }
  }

  // One Subscribe per contract and connection, shared by concurrent callers.
  // With a summary of what the page holds (`follow`), the node sends deltas
  // against it; without one, the whole state on every change.
  _ensureSubscribed(id, idHex) {
    let pending = this._subscribed.get(idHex);
    if (!pending) {
      pending = this._subscribeRequest(id, this._summaries.get(idHex) ?? null);
      this._subscribed.set(idHex, pending);
      pending.catch(() => { if (this._subscribed.get(idHex) === pending) this._subscribed.delete(idHex); });
    }
    return pending;
  }

  // Subscribe again with a newer summary: the node replaces the one it keeps
  // for this connection, so its next deltas start from there.
  _resubscribe(id, idHex, summary) {
    this._summaries.set(idHex, summary);
    const pending = this._subscribeRequest(id, summary);
    this._subscribed.set(idHex, pending);
    pending.catch(() => { if (this._subscribed.get(idHex) === pending) this._subscribed.delete(idHex); });
    return pending;
  }

  _subscribeRequest(id, summary) {
    // ClientRequest::ContractOp(ContractRequest::Subscribe { key, summary: Option<StateSummary> })
    const w = new Writer().u32(1).u32(3).raw(id);
    const req = (summary === null ? w.u8(0) : w.u8(1).bytes(summary)).finish();
    return this._request(req, (r) => r.kind === "subscribed" && equalBytes(r.key.id, id), 30000, base58Encode(id));
  }

  _runner(codeHash, wasm) {
    const hashHex = bytesToHex(codeHash);
    let runner = this._runners.get(hashHex);
    if (!runner) this._runners.set(hashHex, runner = new ContractRunner(wasm()));
    return runner;
  }
}

class DelegateHandle {
  constructor(client, name, { wasm, key, codeHash, parameters = new Uint8Array(0) }) {
    Object.assign(this, { client, name, wasm, key, codeHash, parameters });
  }

  /**
   * Send a payload (Uint8Array or string); resolves to the reply payloads (Uint8Array[]).
   * `timeoutMs` (default 30 s) is how long to wait for the answer. Raise it
   * for a message the delegate answers only after a prompt to the user
   * (`requestUserInput`): the node waits up to 60 s for the user. Requests
   * on the main connection go out one at a time, so other delegate messages
   * and subscriptions wait too (contract gets, puts and updates go out on
   * lanes: see `_contractRequest`).
   */
  async send(payload, { timeoutMs = 30000 } = {}) {
    // InboundDelegateMsg::ApplicationMessage { payload, context, processed: false }
    const inbound = new Writer().u32(0).bytes(toBytes(payload)).bytes(new Uint8Array(0)).u8(0).finish();
    return this._send(inbound, timeoutMs);
  }

  /**
   * Answer a prompt the node didn't show (see `PromptNotShown` below): a
   * `UserResponse` with its `requestId` and the chosen label (or "" for
   * no). Resolves to the delegate's replies, like `send`. Only for nodes
   * that hand prompts to the page (local mode): the delegate can't tell
   * this answer from a person's, so ask the person first.
   */
  async respond(requestId, label, { timeoutMs = 30000 } = {}) {
    // InboundDelegateMsg::UserResponse(UserInputResponse { request_id, response, context })
    const inbound = new Writer().u32(1).u32(requestId).bytes(toBytes(label)).bytes(new Uint8Array(0)).finish();
    return this._send(inbound, timeoutMs);
  }

  async _send(inbound, timeoutMs) {
    // ClientRequest::DelegateOp(DelegateRequest::ApplicationMessages { key, params, inbound: [one] })
    const req = new Writer()
      .u32(0).u32(0)            // DelegateOp, ApplicationMessages
      .raw(this.key).raw(this.codeHash)
      .bytes(this.parameters)
      .u64(1)
      .raw(inbound)
      .finish();
    const res = await this.client._request(req, (r) => r.kind === "delegate" && equalBytes(r.key, this.key), timeoutMs);
    // A network node shows a delegate's prompt itself and answers once the
    // user has; a node that can't (local mode) hands the prompt back here.
    if (res.prompts.length) {
      throw new FreenetError({
        kind: "PromptNotShown", prompts: res.prompts, payloads: res.payloads,
        message: "This Freenet node didn't show the delegate's prompt (a node in local mode can't)",
      });
    }
    return res.payloads;
  }

  /** Like send, but decodes replies as UTF-8 text. */
  async sendText(text, options) {
    return (await this.send(text, options)).map(bytesToText);
  }
}

class ContractHandle {
  constructor(client, { id, codeHash, parameters = null, wasm = null }) {
    this.client = client;
    this.id = id;                       // 32-byte contract instance id
    this.idString = base58Encode(id);   // as Freenet prints it (URLs, logs)
    this.codeHash = codeHash;
    this.parameters = parameters;
    this._wasm = wasm;
  }

  /**
   * Create the contract with an initial state (string or bytes). Only works
   * for embedded contracts (it needs the code). Options: subscribe. If the
   * node already has the contract (another client put it first), it merges
   * the state in and answers with an UpdateResponse instead: that counts too.
   */
  async put(state, { subscribe = false } = {}) {
    if (!this._wasm) throw new Error("put needs the contract code: use client.contract(name, ...) with an embedded contract");
    const wasm = this._wasm();
    // ClientRequest::ContractOp(ContractRequest::Put { contract, state, related_contracts, subscribe, blocking_subscribe })
    const req = new Writer()
      .u32(1).u32(0)               // ContractOp, Put
      .u32(0).u32(0)               // ContractContainer::Wasm, ContractWasmAPIVersion::V1
      .bytes(wasm).raw(this.codeHash) // WrappedContract.data: ContractCode { data, code_hash }
      .bytes(this.parameters)      // WrappedContract.params
      .raw(this.id).raw(this.codeHash) // WrappedContract.key: ContractKey { instance, code }
      .bytes(toBytes(state))       // state
      .u64(0)                      // related_contracts: empty
      .u8(subscribe ? 1 : 0)       // subscribe
      .u8(0)                       // blocking_subscribe
      .finish();
    const expects = (r) => (r.kind === "put" || r.kind === "updated") && equalBytes(r.key.id, this.id);
    // a put that subscribes belongs on the main connection, with the subscription
    if (subscribe) await this.client._request(req, expects, 30000, this.idString);
    else await this.client._contractRequest(this.id, req, expects, 30000, this.idString);
    return this;
  }

  /**
   * The current state (Uint8Array), or null if the network doesn't have it.
   * Options: subscribe; timeoutMs (default 30 s): how long to wait. On a
   * network node a contract nobody has put yet may go unanswered rather than
   * not found; then `get` rejects with an error whose `timedOut` is true.
   */
  async get({ subscribe = false, timeoutMs = 30000 } = {}) {
    // ClientRequest::ContractOp(ContractRequest::Get { key, return_contract_code, subscribe, blocking_subscribe })
    const req = new Writer().u32(1).u32(2).raw(this.id).u8(0).u8(subscribe ? 1 : 0).u8(0).finish();
    let res;
    try {
      const expects = (r) => (r.kind === "get" && equalBytes(r.key.id, this.id)) || (r.kind === "notFound" && equalBytes(r.id, this.id));
      // a get that subscribes belongs on the main connection, with the subscription
      res = subscribe ? await this.client._request(req, expects, timeoutMs, this.idString)
        : await this.client._contractRequest(this.id, req, expects, timeoutMs, this.idString);
    } catch (err) {
      // Depending on mode and version, the node reports an unknown contract as
      // a NotFound response, or as a MissingContract / "state not found" error.
      if (isNotFound(err, this.idString)) return null;
      throw err;
    }
    if (res.kind === "notFound") return null;
    this.codeHash ??= res.key.codeHash;
    return res.state;
  }

  async getText(options) {
    const state = await this.get(options);
    return state === null ? null : bytesToText(state);
  }

  /** Send a delta (string or bytes); the contract's updateState merges it. Resolves to the new summary. */
  update(delta) {
    return this._update(1, toBytes(delta));
  }

  /** Propose a whole new state (string or bytes). Resolves to the new summary. */
  updateState(state) {
    return this._update(0, toBytes(state));
  }

  async _update(variant, data) {
    if (!this.codeHash) throw new Error("update needs the code hash: call get() first or pass it to contractAt");
    // ClientRequest::ContractOp(ContractRequest::Update { key: ContractKey, data: UpdateData })
    const req = new Writer().u32(1).u32(1).raw(this.id).raw(this.codeHash).u32(variant).bytes(data).finish();
    const res = await this.client._contractRequest(this.id, req, (r) => r.kind === "updated" && equalBytes(r.key.id, this.id), 30000, this.idString);
    return res.summary;
  }

  /**
   * Call `onUpdate({ state?, delta? })` (Uint8Arrays) whenever the contract
   * changes. Resolves, once the node confirmed the subscription, to a
   * function that removes the callback. Subscriptions are renewed after
   * reconnects; changes made while disconnected are not replayed.
   */
  async subscribe(onUpdate) {
    const c = this.client;
    const idHex = bytesToHex(this.id);
    let set = c._listeners.get(idHex);
    if (!set) c._listeners.set(idHex, set = new Set());
    set.add(onUpdate);
    try { await c._ensureSubscribed(this.id, idHex); } catch (err) { set.delete(onUpdate); throw err; }
    return () => set.delete(onUpdate);
  }

  /**
   * Keep a copy of the contract's state in the page, in step with the node,
   * receiving only what changed. `onState(state)` (a Uint8Array) is called
   * with the current state once the page has it, and after every change.
   *
   * A plain `subscribe` gets the whole state on every change: the node sends
   * a client deltas only against a summary of what it holds. So `follow`
   * merges each delta into its copy with the contract's own code
   * (`update_state`, run in the page as the node runs it, so the copy is the
   * node's state exactly), summarizes the copy (`summarize_state`) and
   * subscribes again with that summary. A merge that fails falls back to a
   * fresh `get`. Needs the contract's code: an embedded contract
   * (`client.contract(name, ...)`). One copy per contract and client, shared
   * by every `follow` on it.
   *
   * Resolves, once subscribed, to `{ state(), stop() }`: the current copy
   * (or null before the network has the contract), and a function that
   * removes `onState`.
   */
  async follow(onState) {
    if (!this._wasm) throw new Error("follow needs the contract code: use client.contract(name, ...) with an embedded contract");
    const c = this.client;
    const idHex = bytesToHex(this.id);
    let f = c._followers.get(idHex);
    if (!f) c._followers.set(idHex, f = new Follower(this, c._runner(this.codeHash, this._wasm)));
    f.callbacks.add(onState);
    try { await f.started; } catch (err) { f.callbacks.delete(onState); throw err; }
    if (f.state !== null) {
      try { onState(f.state); } catch (err) { console.error(err); }
    }
    return { state: () => f.state, stop: () => f.callbacks.delete(onState) };
  }
}

/**
 * The page's copy of one contract's state (`ContractHandle.follow`). Changes
 * are handled one at a time, in arrival order; after a burst, one Subscribe
 * with the summary of the result.
 */
class Follower {
  constructor(handle, runner) {
    this.handle = handle;
    this.runner = runner;
    this.state = null;
    this.callbacks = new Set();
    this._chain = Promise.resolve();
    this._pending = 0;
    this._latest = null;        // a summary waiting to be sent
    this._subscribing = false;  // a Subscribe in flight
    const c = handle.client, id = handle.id, idHex = bytesToHex(id);
    this._resubscribe = (summary) => c._resubscribe(id, idHex, summary);
    this.started = (async () => {
      const state = await handle.get();
      // notifications from here on (the listener set `subscribe` uses)
      let set = c._listeners.get(idHex);
      if (!set) c._listeners.set(idHex, set = new Set());
      set.add((update) => this._enqueue(update));
      if (state === null) return c._ensureSubscribed(id, idHex); // the first change brings the whole state
      this.state = state;
      // a Subscribe of its own even if the page already subscribed: the node must get the summary.
      // What changed since the `get` comes as a delta against it.
      await c._resubscribe(id, idHex, await runner.summarize(handle.parameters, state));
    })();
    this.started.catch(() => { if (c._followers.get(idHex) === this) c._followers.delete(idHex); });
  }

  _enqueue(update) {
    this._pending++;
    this._chain = this._chain.then(() => this._apply(update)).catch((err) => console.warn("freenet.js: follow:", err.message));
  }

  async _apply(update) {
    const { handle, runner } = this;
    let state = null;
    try {
      if (update.state) state = update.state;
      else if (update.delta && this.state !== null) state = await runner.merge(handle.parameters, this.state, update.delta);
    } catch (err) {
      console.warn("freenet.js: follow: merging a delta failed; fetching the state:", err.message);
    }
    state ??= await handle.get(); // no copy yet, a related-contract update, or a failed merge
    this._pending--;
    if (state === null) return;
    this.state = state;
    for (const fn of this.callbacks) {
      try { fn(state); } catch (err) { console.error(err); }
    }
    // after the last queued change only: one Subscribe per burst
    if (this._pending === 0) this._sendSummary(await runner.summarize(handle.parameters, state));
  }

  // Sends the summary without holding up the next change (a Subscribe to a contract another
  // node hosts takes a network round trip). One Subscribe in flight; meanwhile only the latest
  // summary waits. If one fails, the node keeps the older summary and its deltas carry more; a
  // reconnect subscribes with the latest.
  _sendSummary(summary) {
    this._latest = summary;
    if (this._subscribing) return;
    this._subscribing = true;
    (async () => {
      while (this._latest !== null) {
        const next = this._latest;
        this._latest = null;
        await this._resubscribe(next).catch((err) => console.warn("freenet.js: follow: subscribing with the new summary failed:", err.message));
      }
      this._subscribing = false;
    })();
  }
}

/**
 * An embedded contract's code, run in the page the way the node runs it: a
 * fresh instance for each call (contracts never free; the node drops the
 * instance), inputs written through `__frnt__initiate_buffer`, and a
 * bincode `Result` read back from the result struct. Contracts may log; any
 * other import is refused when the call is made.
 */
class ContractRunner {
  constructor(wasm) {
    this._module = WebAssembly.compile(wasm);
  }

  /** `summarize_state(parameters, state)`: the summary (Uint8Array). */
  async summarize(parameters, state) {
    return (await this._call("summarize_state", 3, [parameters, state])).bytes().slice();
  }

  /** `update_state` with one delta: the new state, or null if the contract gave none. */
  async merge(parameters, state, delta) {
    const updates = new Writer().u64(1).u32(1).bytes(delta).finish(); // Vec<UpdateData>: [Delta(delta)]
    const r = await this._call("update_state", 2, [parameters, state, updates]);
    return r.u8() === 1 ? r.bytes().slice() : null; // UpdateModification.new_state: Option<Bytes>
  }

  // Calls `entry` with the inputs; a Reader past the Ok tag of its Result.
  async _call(entry, kind, inputs) {
    const module = await this._module;
    const imports = {};
    for (const imp of WebAssembly.Module.imports(module)) {
      const fn = imp.module === "freenet_log" ? () => {} : () => {
        throw new Error(`the contract imports ${imp.module}.${imp.name}, which the page doesn't provide`);
      };
      (imports[imp.module] ??= {})[imp.name] = fn;
    }
    const { exports: ex } = await WebAssembly.instantiate(module, imports);
    ex.__frnt_set_id?.(0n);
    const args = inputs.map((bytes) => {
      const builder = ex.__frnt__initiate_buffer(bytes.length); // BufferBuilder { start i64, capacity u32, last_read i64, last_write i64 }
      const view = new DataView(ex.memory.buffer);
      const b = Number(builder);
      new Uint8Array(ex.memory.buffer, Number(view.getBigInt64(b, true)), bytes.length).set(bytes);
      view.setUint32(Number(view.getBigInt64(b + 24, true)), bytes.length, true);
      return builder;
    });
    const res = Number(ex[entry](...args)); // ContractResult { ptr i64, kind i32, size u32 }
    const view = new DataView(ex.memory.buffer);
    if (view.getInt32(res + 8, true) !== kind) throw new Error(`${entry}: the contract returned a result of another kind`);
    const r = new Reader(new Uint8Array(ex.memory.buffer, Number(view.getBigInt64(res, true)), view.getUint32(res + 12, true)).slice());
    if (r.u32() !== 0) throw new Error(`${entry} failed: ${contractErrorText(r)}`);
    return r;
  }
}

// ContractError: 0 Deser(String), 1 InvalidUpdate, 2 InvalidUpdateWithInfo { reason }, 3 InvalidState, 4 InvalidDelta, 5 Other(String)
function contractErrorText(r) {
  try {
    const v = r.u32();
    if (v === 0 || v === 2 || v === 5) return r.text();
    return ["", "invalid update", "", "invalid state", "invalid delta"][v] ?? `error ${v}`;
  } catch {
    return "unreadable error";
  }
}

// ---- bincode ----

class Writer {
  constructor() { this.parts = []; }
  raw(bytes) { this.parts.push(bytes); return this; }
  u8(v) { return this.raw(Uint8Array.of(v)); }
  u32(v) { const b = new Uint8Array(4); new DataView(b.buffer).setUint32(0, v, true); return this.raw(b); }
  u64(v) { const b = new Uint8Array(8); new DataView(b.buffer).setBigUint64(0, BigInt(v), true); return this.raw(b); }
  bytes(b) { return this.u64(b.length).raw(b); }
  finish() { return concatBytes(...this.parts); }
}

class Reader {
  constructor(buf) { this.buf = buf; this.view = new DataView(buf.buffer, buf.byteOffset, buf.byteLength); this.pos = 0; }
  need(n) { if (this.pos + n > this.buf.length) throw new Error("truncated message"); }
  raw(n) { this.need(n); const b = this.buf.subarray(this.pos, this.pos + n); this.pos += n; return b; }
  u8() { this.need(1); return this.buf[this.pos++]; }
  u32() { this.need(4); const v = this.view.getUint32(this.pos, true); this.pos += 4; return v; }
  u64() { this.need(8); const v = this.view.getBigUint64(this.pos, true); this.pos += 8; return Number(v); }
  bytes() { return this.raw(this.u64()); }
  text() { return bytesToText(this.bytes()); }
  contractKey() { return { id: this.raw(32).slice(), codeHash: this.raw(32).slice() }; }
}

/** Result<HostResponse, ClientError> -> { kind, ... } */
function parseHostResponse(buf) {
  const r = new Reader(buf);
  if (r.u32() !== 0) {
    let info;
    try { info = parseClientError(r); } catch { info = { kind: "Unknown" }; }
    return { kind: "error", error: info };
  }
  switch (r.u32()) {
    case 0: return parseContractResponse(r); // HostResponse::ContractResponse
    case 1: { // HostResponse::DelegateResponse { key: DelegateKey, values: Vec<OutboundDelegateMsg> }
      const key = r.raw(32).slice(); r.raw(32);
      const payloads = [], prompts = [];
      for (let i = 0, n = r.u64(); i < n; i++) {
        const tag = r.u32();
        if (tag === 0) { // ApplicationMessage { payload, context, processed }: a reply
          const payload = r.bytes(); r.bytes(); r.u8();
          payloads.push(payload.slice());
        } else if (tag === 1) { // RequestUserInput { request_id, message, responses }: a prompt the node didn't show
          const requestId = r.u32(), message = r.text(), labels = [];
          for (let j = 0, m = r.u64(); j < m; j++) labels.push(r.text());
          prompts.push({ requestId, message, labels });
        } else break; // nothing else is meant for the client
      }
      return { kind: "delegate", key, payloads, prompts };
    }
    case 2: return { kind: "query" }; // HostResponse::QueryResponse (not read further: the liveness probe's answer)
    case 3: return { kind: "ok" }; // HostResponse::Ok
    case 4: return { kind: "chunk", streamId: r.u32(), index: r.u32(), total: r.u32(), data: r.bytes() };
    case 5: return { kind: "streamHeader" };
    default: return { kind: "other" };
  }
}

// ErrorKind variant names, by index.
const ERROR_KINDS = ["ChannelClosed", "DeserializationError", "Disconnect", "IncorrectState", "NodeUnavailable",
  "TransportProtocolDisconnect", "Unhandled", "UnknownClient", "RequestError", "OperationError", "FailedOperation",
  "Shutdown", "EmptyRing", "PeerNotJoined"];

/**
 * ClientError { kind: ErrorKind } -> { kind, message, cause?, contract?, delegate? }.
 * `kind` names the node's variant; ids are base58 as Freenet prints them.
 */
function parseClientError(r) {
  const tag = r.u32();
  let info = { kind: ERROR_KINDS[tag] ?? "Unknown" };
  if (tag === 1 || tag === 6 || tag === 9) info.cause = r.text();         // { cause }
  else if (tag === 3) info.contract = base58Encode(r.contractKey().id);  // IncorrectState(ContractKey)
  else if (tag === 8) info = parseRequestError(r);
  const subject = info.contract ?? info.delegate;
  info.message = info.kind === "DelegateExecutionError" ? info.cause // the delegate's own message
    : `${info.kind}${subject ? ` ${subject}` : ""}${info.cause ? `: ${info.cause}` : ""}`;
  return info;
}

function parseRequestError(r) {
  const delegateKey = () => { const k = base58Encode(r.raw(32)); r.raw(32); return k; };
  switch (r.u32()) {
    case 0: { // ContractError
      const v = r.u32();
      if (v <= 3) { // Get / Put / Update / Subscribe { key: ContractKey, cause }
        const contract = base58Encode(r.contractKey().id);
        return { kind: ["Get", "Put", "Update", "Subscribe"][v], contract, cause: r.text() };
      }
      const kind = ["ContractStackOverflow", "MissingRelated", "MissingContract"][v - 4];
      return kind ? { kind, contract: base58Encode(r.raw(32)) } : { kind: "ContractError" };
    }
    case 1: switch (r.u32()) { // DelegateError
      case 0: return { kind: "RegisterError", delegate: delegateKey() };
      case 1: return { kind: "DelegateExecutionError", cause: r.text() };
      case 2: return { kind: "MissingDelegate", delegate: delegateKey() };
      case 3: { const delegate = delegateKey(); return { kind: "MissingSecret", delegate, cause: r.text() }; }
      case 4: return { kind: "ForbiddenSecretAccess" };
      default: return { kind: "DelegateError" };
    }
    case 2: return { kind: "Disconnect" };
    case 3: return { kind: "Timeout" };
    default: return { kind: "RequestError" };
  }
}

/** Refusals from the node: `err.kind` names the node's error variant. */
class FreenetError extends Error {
  constructor(info) {
    super(info.message);
    this.name = "FreenetError";
    Object.assign(this, info);
  }
}

function parseContractResponse(r) {
  switch (r.u32()) {
    case 0: { // GetResponse { key, contract: Option<ContractContainer>, state }
      const key = r.contractKey();
      if (r.u8() === 1) { // skip ContractContainer::Wasm(V1(WrappedContract { data, params, key }))
        r.u32(); r.u32(); r.bytes(); r.raw(32); r.bytes(); r.raw(64);
      }
      return { kind: "get", key, state: r.bytes().slice() };
    }
    case 1: return { kind: "put", key: r.contractKey() };
    case 2: { // UpdateNotification { key, update: UpdateData }
      const key = r.contractKey();
      const update = {};
      switch (r.u32()) {
        case 0: update.state = r.bytes().slice(); break;
        case 1: update.delta = r.bytes().slice(); break;
        case 2: update.state = r.bytes().slice(); update.delta = r.bytes().slice(); break;
        default: update.related = true; // related-contract updates: not decoded
      }
      return { kind: "notification", key, update };
    }
    case 3: return { kind: "updated", key: r.contractKey(), summary: r.bytes().slice() };
    case 4: return { kind: "subscribed", key: r.contractKey(), subscribed: r.u8() === 1 };
    case 5: return { kind: "notFound", id: r.raw(32).slice() };
    default: return { kind: "other" };
  }
}

function isNotFound(err, idString) {
  if (!(err instanceof FreenetError) || (err.contract && err.contract !== idString)) return false;
  return err.kind === "MissingContract" || (err.kind === "Get" && /not found/i.test(err.cause ?? ""));
}

// ---- bytes, text, base58 ----

/** A string (UTF-8 encoded), Uint8Array, other typed array view or ArrayBuffer, as a Uint8Array. */
function toBytes(v) {
  if (typeof v === "string") return new TextEncoder().encode(v);
  if (v instanceof Uint8Array) return v;
  if (ArrayBuffer.isView(v)) return new Uint8Array(v.buffer, v.byteOffset, v.byteLength);
  if (v instanceof ArrayBuffer) return new Uint8Array(v);
  throw new TypeError(`expected a string, Uint8Array or ArrayBuffer, got ${Object.prototype.toString.call(v)}`);
}
/** A 32-byte id: base58 or 64-char hex string, or bytes. */
function bytes32(v, what) {
  const b = typeof v === "string" ? (/^[0-9a-f]{64}$/i.test(v) ? hexToBytes(v) : base58Decode(v)) : toBytes(v);
  if (b.length !== 32) throw new TypeError(`${what} must be 32 bytes, got ${b.length}`);
  return b;
}
function bytesToText(b) { return new TextDecoder().decode(b); }
function b64ToBytes(s) { return Uint8Array.from(atob(s), (c) => c.charCodeAt(0)); }
function hexToBytes(h) {
  if (!/^(?:[0-9a-f]{2})*$/i.test(h)) throw new TypeError(`invalid hex: ${h}`);
  return Uint8Array.from(h.match(/../g) ?? [], (b) => parseInt(b, 16));
}
function bytesToHex(b) { return Array.from(b, (x) => x.toString(16).padStart(2, "0")).join(""); }
function equalBytes(a, b) { return a.length === b.length && a.every((v, i) => v === b[i]); }
function concatBytes(...parts) {
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let o = 0;
  for (const p of parts) { out.set(p, o); o += p.length; }
  return out;
}

const B58 = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";
function base58Encode(bytes) {
  let n = 0n;
  for (const b of bytes) n = n * 256n + BigInt(b);
  let s = "";
  while (n > 0n) { s = B58[Number(n % 58n)] + s; n /= 58n; }
  for (const b of bytes) { if (b !== 0) break; s = "1" + s; }
  return s;
}
function base58Decode(s) {
  let n = 0n;
  for (const c of s) {
    const v = B58.indexOf(c);
    if (v < 0) throw new TypeError(`invalid base58: ${s}`);
    n = n * 58n + BigInt(v);
  }
  const out = [];
  while (n > 0n) { out.unshift(Number(n % 256n)); n /= 256n; }
  for (const c of s) { if (c !== "1") break; out.unshift(0); }
  return Uint8Array.from(out);
}

// ---- BLAKE3 (hash mode, 32-byte output), for contract instance ids ----
// https://github.com/BLAKE3-team/BLAKE3-specs

const B3_IV = new Uint32Array([0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]);
const B3_PERM = [2, 6, 3, 10, 7, 0, 4, 13, 1, 11, 12, 5, 9, 14, 15, 8];
const B3_CHUNK_START = 1, B3_CHUNK_END = 2, B3_PARENT = 4, B3_ROOT = 8;

function b3Compress(cv, block, counter, blockLen, flags) {
  const s = new Uint32Array(16);
  s.set(cv, 0); s.set(B3_IV.subarray(0, 4), 8);
  s[12] = counter % 0x100000000; s[13] = Math.floor(counter / 0x100000000);
  s[14] = blockLen; s[15] = flags;
  let m = block.slice();
  const g = (a, b, c, d, x, y) => {
    s[a] = s[a] + s[b] + x; s[d] = ((s[d] ^ s[a]) >>> 16) | ((s[d] ^ s[a]) << 16);
    s[c] = s[c] + s[d];     s[b] = ((s[b] ^ s[c]) >>> 12) | ((s[b] ^ s[c]) << 20);
    s[a] = s[a] + s[b] + y; s[d] = ((s[d] ^ s[a]) >>> 8) | ((s[d] ^ s[a]) << 24);
    s[c] = s[c] + s[d];     s[b] = ((s[b] ^ s[c]) >>> 7) | ((s[b] ^ s[c]) << 25);
  };
  for (let round = 0; round < 7; round++) {
    g(0, 4, 8, 12, m[0], m[1]); g(1, 5, 9, 13, m[2], m[3]);
    g(2, 6, 10, 14, m[4], m[5]); g(3, 7, 11, 15, m[6], m[7]);
    g(0, 5, 10, 15, m[8], m[9]); g(1, 6, 11, 12, m[10], m[11]);
    g(2, 7, 8, 13, m[12], m[13]); g(3, 4, 9, 14, m[14], m[15]);
    if (round < 6) { const p = new Uint32Array(16); for (let i = 0; i < 16; i++) p[i] = m[B3_PERM[i]]; m = p; }
  }
  for (let i = 0; i < 8; i++) { s[i] ^= s[i + 8]; s[i + 8] ^= cv[i]; }
  return s;
}

function b3Words(bytes, off, len) {
  const w = new Uint32Array(16);
  for (let i = 0; i < len; i++) w[i >> 2] |= bytes[off + i] << ((i & 3) * 8);
  return w;
}

function b3Parent(left, right, flags) {
  const w = new Uint32Array(16); w.set(left, 0); w.set(right, 8);
  return b3Compress(B3_IV, w, 0, 64, B3_PARENT | flags);
}

function blake3(data) {
  const chunks = Math.max(1, Math.ceil(data.length / 1024));
  const stack = []; // chaining values of completed subtrees
  let root;
  for (let c = 0; c < chunks; c++) {
    const start = c * 1024, end = Math.min(start + 1024, data.length);
    const blocks = Math.max(1, Math.ceil((end - start) / 64));
    let cv = B3_IV, out;
    for (let b = 0; b < blocks; b++) {
      const off = start + b * 64, len = Math.max(0, Math.min(64, end - off));
      let flags = (b === 0 ? B3_CHUNK_START : 0) | (b === blocks - 1 ? B3_CHUNK_END : 0);
      if (chunks === 1 && b === blocks - 1) flags |= B3_ROOT;
      out = b3Compress(cv, b3Words(data, off, len), c, len, flags);
      cv = out.subarray(0, 8);
    }
    if (chunks === 1) { root = out; break; }
    let node = cv.slice();
    if (c < chunks - 1) {
      for (let total = c + 1; (total & 1) === 0; total >>= 1) node = b3Parent(stack.pop(), node, 0).slice(0, 8);
      stack.push(node);
    } else {
      while (stack.length > 1) node = b3Parent(stack.pop(), node, 0).slice(0, 8);
      root = b3Parent(stack.pop(), node, B3_ROOT);
    }
  }
  const outBytes = new Uint8Array(32);
  for (let i = 0; i < 32; i++) outBytes[i] = (root[i >> 2] >>> ((i & 3) * 8)) & 0xff;
  return outBytes;
}

FreenetClient.Error = FreenetError;
FreenetClient.util = { blake3, base58Encode, base58Decode, hexToBytes, bytesToHex, concatBytes };
globalThis.FreenetClient = FreenetClient;
})();
