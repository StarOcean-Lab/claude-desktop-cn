"use strict";
(() => {
  var __defProp = Object.defineProperty;
  var __defNormalProp = (obj, key, value) => key in obj ? __defProp(obj, key, { enumerable: true, configurable: true, writable: true, value }) : obj[key] = value;
  var __publicField = (obj, key, value) => __defNormalProp(obj, typeof key !== "symbol" ? key + "" : key, value);

  // components/voice/audio/ringbuf.ts
  var RD = 0;
  var WR = 1;
  var UNDERRUNS = 2;
  var PLAYED = 3;
  var HEADER_SLOTS = 4;
  var HEADER_BYTES = HEADER_SLOTS * Uint32Array.BYTES_PER_ELEMENT;
  var RingBuffer = class {
    constructor(sab) {
      __publicField(this, "capacity");
      __publicField(this, "storage");
      __publicField(this, "indices");
      this.indices = new Uint32Array(sab, 0, HEADER_SLOTS);
      this.storage = new Float32Array(sab, HEADER_BYTES);
      this.capacity = this.storage.length;
    }
    /** Allocate a backing buffer sized for `capacity` Float32 samples + header. */
    static allocate(capacity) {
      const bytes = HEADER_BYTES + capacity * Float32Array.BYTES_PER_ELEMENT;
      const Ctor = typeof SharedArrayBuffer !== "undefined" ? SharedArrayBuffer : ArrayBuffer;
      return new Ctor(bytes);
    }
    /** Producer-side. Writes up to input.length samples; returns count written. */
    push(input) {
      const wr = Atomics.load(this.indices, WR);
      const rd = Atomics.load(this.indices, RD);
      const n = Math.min(input.length, this._availableWrite(rd, wr));
      if (n === 0) {
        return 0;
      }
      const tail = this.capacity - wr;
      if (n <= tail) {
        this.storage.set(input.subarray(0, n), wr);
      } else {
        this.storage.set(input.subarray(0, tail), wr);
        this.storage.set(input.subarray(tail, n), 0);
      }
      Atomics.store(this.indices, WR, (wr + n) % this.capacity);
      return n;
    }
    /** Consumer-side. Reads up to output.length samples; returns count read. */
    pop(output) {
      const rd = Atomics.load(this.indices, RD);
      const wr = Atomics.load(this.indices, WR);
      const n = Math.min(output.length, this._availableRead(rd, wr));
      if (n === 0) {
        return 0;
      }
      const tail = this.capacity - rd;
      if (n <= tail) {
        output.set(this.storage.subarray(rd, rd + n));
      } else {
        output.set(this.storage.subarray(rd, this.capacity));
        output.set(this.storage.subarray(0, n - tail), tail);
      }
      Atomics.store(this.indices, RD, (rd + n) % this.capacity);
      return n;
    }
    /** Reset both heads. Only safe when neither side is concurrently active. */
    clear() {
      Atomics.store(this.indices, RD, 0);
      Atomics.store(this.indices, WR, 0);
    }
    /** Consumer-side discard: fast-forward rd to wr. Safe while producer pushes. */
    drainAll() {
      const wr = Atomics.load(this.indices, WR);
      Atomics.store(this.indices, RD, wr);
    }
    availableRead() {
      const rd = Atomics.load(this.indices, RD);
      const wr = Atomics.load(this.indices, WR);
      return this._availableRead(rd, wr);
    }
    availableWrite() {
      const rd = Atomics.load(this.indices, RD);
      const wr = Atomics.load(this.indices, WR);
      return this._availableWrite(rd, wr);
    }
    isEmpty() {
      return this.availableRead() === 0;
    }
    isFull() {
      return this.availableWrite() === 0;
    }
    /** capacity − 1 (one slot reserved to distinguish full/empty). */
    usableCapacity() {
      return this.capacity - 1;
    }
    incrementUnderrun() {
      Atomics.add(this.indices, UNDERRUNS, 1);
    }
    underrunCount() {
      return Atomics.load(this.indices, UNDERRUNS);
    }
    resetUnderruns() {
      Atomics.store(this.indices, UNDERRUNS, 0);
    }
    /** Consumer increments after writing samples to the destination. */
    addPlayedSamples(n) {
      Atomics.add(this.indices, PLAYED, n);
    }
    playedSamples() {
      return Atomics.load(this.indices, PLAYED);
    }
    resetPlayed() {
      Atomics.store(this.indices, PLAYED, 0);
    }
    _availableRead(rd, wr) {
      return (wr - rd + this.capacity) % this.capacity;
    }
    _availableWrite(rd, wr) {
      return this.capacity - 1 - this._availableRead(rd, wr);
    }
  };

  // components/voice/audio/audioSinkWorklet.ts
  var AUDIO_SINK_PROCESSOR_NAME = "audio-sink-processor";
  var AudioSinkProcessor = class extends AudioWorkletProcessor {
    constructor(opts) {
      super();
      __publicField(this, "ring");
      // Gate underrun counting: process() runs at ~375/sec from the moment the
      // worklet connects, long before any TTS audio arrives. Counting those
      // empty-ring quanta as underruns inflates the dev-tools badge by hundreds
      // before playback even starts. Only count after the first non-empty read.
      __publicField(this, "hasStarted", false);
      // One-shot drain notification: post "drained" to the main thread on the
      // playing→empty transition so AudioPlayer can fire onPlaybackComplete.
      // Without this, the worklet sink never signals completion — only the
      // legacy buffersource sink does (via source.onended). Reset on new data
      // and on flush so each turn gets exactly one drain signal.
      __publicField(this, "drainPosted", false);
      this.ring = new RingBuffer(opts.processorOptions.sab);
      this.port.onmessage = (ev) => {
        if (ev.data.type === "flush") {
          this.ring.drainAll();
          this.hasStarted = false;
          this.drainPosted = false;
        } else if (ev.data.type === "turn_end") {
          this.hasStarted = false;
          this.drainPosted = false;
        }
      };
    }
    process(_inputs, outputs, _params) {
      const channel = outputs[0]?.[0];
      if (!channel) {
        return true;
      }
      const read = this.ring.pop(channel);
      if (read > 0) {
        this.hasStarted = true;
        this.drainPosted = false;
        this.ring.addPlayedSamples(read);
      }
      if (read < channel.length) {
        channel.fill(0, read);
        if (this.hasStarted && !this.drainPosted) {
          this.ring.incrementUnderrun();
          if (read === 0) {
            this.drainPosted = true;
            this.port.postMessage({ type: "drained" });
          }
        }
      }
      return true;
    }
  };
  registerProcessor(AUDIO_SINK_PROCESSOR_NAME, AudioSinkProcessor);
})();
