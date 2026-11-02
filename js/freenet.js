// freenet.js: minimal browser client for Freenet web apps (no dependencies).
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
//   await room.update(delta);
//
// Speaks the node's WebSocket API with ?encodingProtocol=native (bincode).
// Only `FreenetClient` is added to the page's globals. `FreenetClient.Error`
// is the error class for refusals from the node, and `FreenetClient.util` has
// the helpers pages need to work with ids: blake3, base58Encode, base58Decode,
// hexToBytes, bytesToHex, concatBytes.
(() => {
"use strict";

class FreenetClient {
  /** Filled in by freenet-pack: { name: { wasm: base64, key: hex, codeHash: hex, parameters: hex } } */
  static embedded = {};
  /** Filled in by freenet-pack: this web app's contract id (hex), the parameters of its delegates. */
  static appId = null;
  /** Filled in by freenet-pack: { name: { wasm: base64, codeHash: hex } } */
  static contracts = {};

  /**
   * Connect to the local node (the page's own host when served by Freenet).
   * Options: url, reconnect (default true: after the connection is lost, or
   * after a request times out, reconnect every 2 s), onStatus(status) with
   * status one of "connecting" | "open" | "closed".
   */
  static connect(options = {}) {
    const client = new FreenetClient(options);
    return client._open().then(() => client);
  }

  constructor({ url, reconnect = true, onStatus = () => {} } = {}) {
    this.url = url ?? FreenetClient.defaultUrl();
    this.reconnect = reconnect;
    this.onStatus = onStatus;
    this._inflight = null;           // the request awaiting an answer (one at a time)
    this._queue = Promise.resolve(); // serializes requests
    this._registered = new Map();    // delegate name -> Promise<DelegateHandle>
    this._listeners = new Map();     // contract id hex -> Set of callbacks
    this._subscribed = new Map();    // contract id hex -> Promise (subscription on this connection)
    this._streams = new Map();       // stream id -> chunks of a large response
    this._everOpened = false;
    this._closing = false;
  }

  static defaultUrl() {
    const proto = location.protocol === "https:" ? "wss" : "ws";
    return `${proto}://${location.host}/v1/contract/command?encodingProtocol=native`;
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
    const entry = this._inflight;
    if (!entry) return;
    // Replies carry no request id. An error can't be matched to a request,
    // so it goes to the one in flight; other replies must look like the
    // answer we expect (e.g. not an extra SubscribeResponse).
    if (res.kind !== "error" && !entry.expects(res)) return;
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

  // Requests go out one at a time: replies carry no request id, so the next
  // request is sent only after the previous one was answered or failed. A
  // timed-out request may still be answered later, which would then look
  // like the answer to the next one, so a timeout drops the connection (and
  // reconnects, if enabled) instead of carrying on.
  _request(bytes, expects, timeoutMs = 30000) {
    const run = () => new Promise((resolve, reject) => {
      const ws = this.ws;
      if (!ws || ws.readyState !== WebSocket.OPEN) return reject(new Error("not connected"));
      const entry = { resolve, reject, expects };
      entry.timer = setTimeout(() => {
        if (this._inflight !== entry) return;
        this._inflight = null;
        reject(new Error("timed out waiting for the node"));
        ws.close();
      }, timeoutMs);
      this._inflight = entry;
      ws.send(bytes);
    });
    const result = this._queue.then(run, run);
    this._queue = result.catch(() => {});
    return result;
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
  _ensureSubscribed(id, idHex) {
    let pending = this._subscribed.get(idHex);
    if (!pending) {
      // ClientRequest::ContractOp(ContractRequest::Subscribe { key, summary: None })
      const req = new Writer().u32(1).u32(3).raw(id).u8(0).finish();
      pending = this._request(req, (r) => r.kind === "subscribed" && equalBytes(r.key.id, id));
      this._subscribed.set(idHex, pending);
      pending.catch(() => { if (this._subscribed.get(idHex) === pending) this._subscribed.delete(idHex); });
    }
    return pending;
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
   * go out one at a time, so everything else this client sends waits too.
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
   * for embedded contracts (it needs the code). Options: subscribe.
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
    await this.client._request(req, (r) => r.kind === "put" && equalBytes(r.key.id, this.id));
    return this;
  }

  /** The current state (Uint8Array), or null if the network doesn't have it. Options: subscribe. */
  async get({ subscribe = false } = {}) {
    // ClientRequest::ContractOp(ContractRequest::Get { key, return_contract_code, subscribe, blocking_subscribe })
    const req = new Writer().u32(1).u32(2).raw(this.id).u8(0).u8(subscribe ? 1 : 0).u8(0).finish();
    let res;
    try {
      res = await this.client._request(req, (r) =>
        (r.kind === "get" && equalBytes(r.key.id, this.id)) || (r.kind === "notFound" && equalBytes(r.id, this.id)));
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
    const res = await this.client._request(req, (r) => r.kind === "updated" && equalBytes(r.key.id, this.id));
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
