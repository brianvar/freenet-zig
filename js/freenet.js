// freenet.js: minimal browser client for Freenet web apps (no dependencies).
//
// In your page, load it with a script tag whose src is "freenet.js".
// `freenet-pack` replaces that exact tag with this file plus your embedded
// delegates and contracts, so the published page is one self-contained file.
//
//   const client = await FreenetClient.connect();
//
//   // delegates: private logic on the user's node
//   const random = await client.delegate("random");
//   const [n] = await random.sendText("random");
//
//   // contracts: shared state on the network
//   const room = client.contract("chat", ownerKeyBytes);   // parameters
//   await room.put(initialState);                           // create (once)
//   await room.subscribe((u) => render(u.state ?? u.delta));
//   await room.update(delta);
//
// Speaks the node's WebSocket API with ?encodingProtocol=native (bincode).
"use strict";

class FreenetClient {
  /** Filled in by freenet-pack: { name: { wasm: base64, key: hex, codeHash: hex } } */
  static embedded = {};
  /** Filled in by freenet-pack: { name: { wasm: base64, codeHash: hex } } */
  static contracts = {};

  /**
   * Connect to the local node (the page's own host when served by Freenet).
   * Options: url, reconnect (default true), onStatus(status) with status one
   * of "connecting" | "open" | "closed".
   */
  static connect(options = {}) {
    const client = new FreenetClient(options);
    return client._open().then(() => client);
  }

  constructor({ url, reconnect = true, onStatus = () => {} } = {}) {
    this.url = url ?? FreenetClient.defaultUrl();
    this.reconnect = reconnect;
    this.onStatus = onStatus;
    this._pending = [];              // requests awaiting an answer (at most one)
    this._queue = Promise.resolve(); // serializes requests
    this._registered = new Map();    // delegate name -> handle (re-registered on reconnect)
    this._listeners = new Map();     // contract id hex -> Set of callbacks
    this._streams = new Map();       // stream id -> chunks of a large response
    this._closing = false;
  }

  static defaultUrl() {
    const proto = location.protocol === "https:" ? "wss" : "ws";
    return `${proto}://${location.host}/v1/contract/command?encodingProtocol=native`;
  }

  // ---- delegates ----

  /** Register an embedded delegate (once) and return a handle to message it. */
  async delegate(name) {
    if (this._registered.has(name)) return this._registered.get(name);
    const spec = FreenetClient.embedded[name];
    if (!spec) throw new Error(`no embedded delegate named "${name}" (check addWebApp's delegates)`);
    const handle = new DelegateHandle(this, name, {
      wasm: b64ToBytes(spec.wasm), key: hexToBytes(spec.key), codeHash: hexToBytes(spec.codeHash),
    });
    await this._register(handle);
    this._registered.set(name, handle);
    return handle;
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
      id: typeof id === "string" ? base58Decode(id) : id,
      codeHash: codeHash == null ? null : typeof codeHash === "string"
        ? (/^[0-9a-f]{64}$/i.test(codeHash) ? hexToBytes(codeHash) : base58Decode(codeHash)) : codeHash,
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
        try {
          for (const handle of this._registered.values()) await this._register(handle);
          for (const [idHex, entry] of this._listeners) {
            if (entry.size > 0) await this._subscribe(hexToBytes(idHex));
          }
          this.onStatus("open");
          resolve();
        } catch (err) { reject(err); }
      };
      ws.onmessage = (event) => this._onMessage(event.data);
      ws.onclose = () => {
        this._pending.forEach((p) => { clearTimeout(p.timer); p.reject(new Error("connection closed")); });
        this._pending = [];
        this._streams.clear();
        this.onStatus("closed");
        if (!opened) reject(new Error(`cannot connect to ${this.url}`));
        if (this.reconnect && !this._closing) setTimeout(() => this._open().catch(() => {}), 2000);
      };
    });
  }

  async _onMessage(data) {
    if (data instanceof Blob) data = await data.arrayBuffer();
    this._handle(new Uint8Array(data));
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
    const entry = this._pending[0];
    if (!entry) return;
    if (res.kind !== "error" && !entry.expects(res)) return; // unsolicited (e.g. an extra SubscribeResponse)
    this._pending.shift();
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
  // request is sent only after the previous one was answered (or failed).
  _request(bytes, expects, timeoutMs = 30000) {
    const run = () => new Promise((resolve, reject) => {
      if (!this.ws || this.ws.readyState !== WebSocket.OPEN) return reject(new Error("not connected"));
      const entry = { resolve, reject, expects };
      entry.timer = setTimeout(() => {
        this._pending = this._pending.filter((p) => p !== entry);
        reject(new Error("timed out waiting for the node"));
      }, timeoutMs);
      this._pending.push(entry);
      this.ws.send(bytes);
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
      // A refusal (e.g. already registered) is not fatal; messages will tell.
      if (!/timed out|not connected|closed/.test(err.message)) console.warn(`freenet.js: RegisterDelegate(${handle.name}):`, err.message);
      else throw err;
    }
  }

  _subscribe(id, summary = null) {
    // ClientRequest::ContractOp(ContractRequest::Subscribe { key, summary })
    const w = new Writer().u32(1).u32(3).raw(id);
    if (summary) w.u8(1).bytes(summary); else w.u8(0);
    return this._request(w.finish(), (r) => r.kind === "subscribed" && equalBytes(r.key.id, id));
  }
}

class DelegateHandle {
  constructor(client, name, { wasm, key, codeHash, parameters = new Uint8Array(0) }) {
    Object.assign(this, { client, name, wasm, key, codeHash, parameters });
  }

  /** Send a payload (Uint8Array or string); resolves to the reply payloads (Uint8Array[]). */
  async send(payload) {
    // ClientRequest::DelegateOp(DelegateRequest::ApplicationMessages { key, params, inbound })
    const req = new Writer()
      .u32(0).u32(0)            // DelegateOp, ApplicationMessages
      .raw(this.key).raw(this.codeHash)
      .bytes(this.parameters)
      .u64(1)                   // inbound: one message
      .u32(0)                   // InboundDelegateMsg::ApplicationMessage
      .bytes(toBytes(payload))
      .bytes(new Uint8Array(0)) // context
      .u8(0)                    // processed = false
      .finish();
    const res = await this.client._request(req, (r) => r.kind === "delegate" && equalBytes(r.key, this.key));
    return res.payloads;
  }

  /** Like send, but decodes replies as UTF-8 text. */
  async sendText(text) {
    return (await this.send(text)).map(bytesToText);
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
   * changes. Resolves to a function that removes the callback. Subscriptions
   * are renewed automatically after reconnects.
   */
  async subscribe(onUpdate) {
    const idHex = bytesToHex(this.id);
    let set = this.client._listeners.get(idHex);
    const first = !set || set.size === 0;
    if (!set) this.client._listeners.set(idHex, set = new Set());
    set.add(onUpdate);
    if (first) {
      try { await this.client._subscribe(this.id); } catch (err) { set.delete(onUpdate); throw err; }
    }
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
  contractKey() { return { id: this.raw(32).slice(), codeHash: this.raw(32).slice() }; }
}

/** Result<HostResponse, ClientError> -> { kind, ... } */
function parseHostResponse(buf) {
  const r = new Reader(buf);
  if (r.u32() !== 0) {
    let info;
    try { info = parseClientError(r); } catch { info = { kind: "Unknown", message: "the node returned an error" }; }
    return { kind: "error", error: info };
  }
  switch (r.u32()) {
    case 0: return parseContractResponse(r); // HostResponse::ContractResponse
    case 1: { // HostResponse::DelegateResponse { key: DelegateKey, values: Vec<OutboundDelegateMsg> }
      const key = r.raw(32).slice(); r.raw(32);
      const payloads = [];
      for (let i = 0, n = r.u64(); i < n; i++) {
        if (r.u32() !== 0) break; // only ApplicationMessage carries a reply payload
        const payload = r.bytes(); r.bytes(); r.u8();
        payloads.push(payload.slice());
      }
      return { kind: "delegate", key, payloads };
    }
    case 3: return { kind: "ok" }; // HostResponse::Ok
    case 4: return { kind: "chunk", streamId: r.u32(), index: r.u32(), total: r.u32(), data: r.bytes() };
    case 5: return { kind: "streamHeader" };
    default: return { kind: "other" };
  }
}

/** ClientError { kind: ErrorKind } -> { kind: "MissingContract" | ..., message, contract?, cause? } */
function parseClientError(r) {
  const key = () => base58Encode(r.contractKey().id);      // ContractKey: shown by its instance id
  const instance = () => base58Encode(r.raw(32));          // ContractInstanceId
  const delegateKey = () => { const k = base58Encode(r.raw(32)); r.raw(32); return k; };
  const str = () => bytesToText(r.bytes());
  switch (r.u32()) {                                       // ErrorKind
    case 0: return { kind: "ChannelClosed", message: "comm channel between client/host closed" };
    case 1: { const cause = str(); return { kind: "DeserializationError", cause, message: `error while deserializing: ${cause}` }; }
    case 2: return { kind: "Disconnect", message: "client disconnected" };
    case 3: { const contract = key(); return { kind: "IncorrectState", contract, message: `failed while trying to unpack state for ${contract}` }; }
    case 4: return { kind: "NodeUnavailable", message: "node not available" };
    case 5: return { kind: "TransportProtocolDisconnect", message: "lost the connection with the protocol handling connections" };
    case 6: { const cause = str(); return { kind: "Unhandled", cause, message: `unhandled error: ${cause}` }; }
    case 7: return { kind: "UnknownClient", message: `unknown client id: ${r.u64()}` };
    case 8: switch (r.u32()) {                             // RequestError
      case 0: {                                            // ContractError
        const v = r.u32();
        if (v <= 3) {                                      // Get / Put / Update / Subscribe { key, cause }
          const contract = key(), cause = str();
          const [kind, what] = [["Get", "failed to get contract"], ["Put", "put error for contract"],
            ["Update", "update error for contract"], ["Subscribe", "failed to subscribe for contract"]][v];
          return { kind, contract, cause, message: `${what} ${contract}, reason: ${cause}` };
        }
        const contract = instance();
        if (v === 4) return { kind: "ContractStackOverflow", contract, message: `dependency contract stack overflow: ${contract}` };
        if (v === 5) return { kind: "MissingRelated", contract, message: `missing related contract: ${contract}` };
        if (v === 6) return { kind: "MissingContract", contract, message: `missing contract: ${contract}` };
        return { kind: "ContractError", message: "contract error" };
      }
      case 1: switch (r.u32()) {                           // DelegateError
        case 0: { const delegate = delegateKey(); return { kind: "RegisterError", delegate, message: `error while registering delegate ${delegate}` }; }
        case 1: { const cause = str(); return { kind: "DelegateExecutionError", cause, message: cause }; }
        case 2: { const delegate = delegateKey(); return { kind: "MissingDelegate", delegate, message: `missing delegate ${delegate}` }; }
        case 3: { const delegate = delegateKey(); const secret = str(); r.raw(32); return { kind: "MissingSecret", delegate, message: `missing secret \`${secret}\` for delegate ${delegate}` }; }
        case 4: return { kind: "ForbiddenSecretAccess", message: "forbidden access to secret" };
        default: return { kind: "DelegateError", message: "delegate error" };
      }
      case 2: return { kind: "Disconnect", message: "client disconnect" };
      case 3: return { kind: "Timeout", message: "operation timed out" };
      default: return { kind: "RequestError", message: "request error" };
    }
    case 9: { const cause = str(); return { kind: "OperationError", cause, message: `error while executing operation in the network: ${cause}` }; }
    case 10: return { kind: "FailedOperation", message: "operation timed out" };
    case 11: return { kind: "Shutdown", message: "peer should shutdown" };
    case 12: return { kind: "EmptyRing", message: "no ring connections found" };
    case 13: return { kind: "PeerNotJoined", message: "peer has not joined the network yet" };
    default: return { kind: "Unknown", message: "the node returned an error" };
  }
}

/** Errors from the node: `err.kind` names the node's error variant. */
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

function toBytes(v) { return typeof v === "string" ? new TextEncoder().encode(v) : v; }
function bytesToText(b) { return new TextDecoder().decode(b); }
function b64ToBytes(s) { return Uint8Array.from(atob(s), (c) => c.charCodeAt(0)); }
function hexToBytes(h) { return Uint8Array.from(h.match(/../g) ?? [], (b) => parseInt(b, 16)); }
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
    if (v < 0) throw new Error(`invalid base58: ${s}`);
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
