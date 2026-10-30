// PLAN-VOICEUI §4.8 (web/voice_worklets.js): the two AudioWorklet processors
// behind the browser voice call. Fixed 16 kHz mono s16le on the wire (§3.1);
// the AudioContext runs at the device rate and the worklets resample here,
// NOT in an AudioContext forced to 16000 (Firefox refuses MediaStream
// sources into a differently-sampled context — §4.1 point 3).
//
// vg-capture: input block → linear-interpolated 16 kHz → 320-sample frames
// posted as transferred Int16Array buffers (640 bytes, 20 ms apart).
// vg-playback: 16 kHz frames → upsampled into a 2 s ring buffer, output
// only once 60 ms is prebuffered (gateway lead_ms, D10); a {type:'flush'}
// message drops the buffer the INSTANT a barge-in lands (§3.1 stop row),
// and {type:'drained'} fires when the buffer goes non-empty → empty so the
// UI speech indicator follows the LOCAL buffer (§4.7 audio_end row).

const TARGET_RATE = 16000;
const FRAME_SAMPLES = 320; // 20 ms at 16 kHz

class VgCapture extends AudioWorkletProcessor {
  constructor() {
    super();
    this.ratio = sampleRate / TARGET_RATE;
    this.phase = 0;
    this.acc = new Float32Array(FRAME_SAMPLES);
    this.filled = 0;
  }

  process(inputs) {
    const input = inputs[0] && inputs[0][0];
    if (!input || input.length === 0) return true;
    let pos = this.phase;
    const n = input.length;
    while (pos < n) {
      const i = Math.floor(pos);
      const f = pos - i;
      const a = input[i];
      const b = i + 1 < n ? input[i + 1] : a;
      this.acc[this.filled++] = a + (b - a) * f;
      if (this.filled === FRAME_SAMPLES) {
        const out = new Int16Array(FRAME_SAMPLES);
        for (let k = 0; k < FRAME_SAMPLES; k++) {
          const s = Math.max(-1, Math.min(1, this.acc[k]));
          out[k] = Math.max(-32767, Math.min(32767, Math.round(s * 32767)));
        }
        this.port.postMessage(out.buffer, [out.buffer]);
        this.filled = 0;
      }
      pos += this.ratio;
    }
    this.phase = pos - n;
    return true;
  }
}

class VgPlayback extends AudioWorkletProcessor {
  constructor() {
    super();
    this.capacity = Math.max(1, Math.floor(sampleRate * 2)); // 2 s ring
    this.buf = new Float32Array(this.capacity);
    this.head = 0;
    this.tail = 0;
    this.count = 0;
    this.prebuffer = Math.max(1, Math.floor(sampleRate * 0.06)); // 60 ms
    this.started = false;
    this.step = sampleRate / TARGET_RATE;
    this.last = 0; // continuity across 20 ms blocks (no edge clicks)
    this.port.onmessage = (e) => {
      const m = e.data;
      if (!m) return;
      if (m.type === 'pcm') {
        this.push(m.data instanceof Int16Array ? m.data : new Int16Array(m.data));
      } else if (m.type === 'flush') {
        this.head = this.tail = this.count = 0;
        this.started = false;
        this.last = 0;
      }
    };
  }

  push(i16) {
    let pos = 0;
    const n = i16.length;
    while (pos < n) {
      const i = Math.floor(pos);
      const f = pos - i;
      const cur = i16[Math.min(i, n - 1)] / 32768;
      const prev = i === 0 ? this.last : i16[i - 1] / 32768;
      const s = f === 0 ? cur : prev + (cur - prev) * f;
      if (this.count < this.capacity) {
        this.buf[this.tail] = s;
        this.tail = (this.tail + 1) % this.capacity;
        this.count++;
      } // overflow: drop the sample; a stalled consumer must not wedge us
      pos += this.step;
    }
    if (n > 0) this.last = i16[n - 1] / 32768;
  }

  process(inputs, outputs) {
    const out = outputs[0];
    if (!out || out.length === 0) return true;
    if (!this.started) {
      if (this.count < this.prebuffer) {
        for (let c = 0; c < out.length; c++) out[c].fill(0);
        return true;
      }
      this.started = true;
    }
    const n = out[0].length;
    for (let k = 0; k < n; k++) {
      let s = 0;
      if (this.count > 0) {
        s = this.buf[this.head];
        this.head = (this.head + 1) % this.capacity;
        this.count--;
      }
      for (let c = 0; c < out.length; c++) out[c][k] = s;
    }
    if (this.count === 0) {
      this.started = false;
      this.last = 0;
      this.port.postMessage({ type: 'drained' });
    }
    return true;
  }
}

registerProcessor('vg-capture', VgCapture);
registerProcessor('vg-playback', VgPlayback);
