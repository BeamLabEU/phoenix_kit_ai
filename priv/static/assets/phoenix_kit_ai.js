// phoenix_kit_ai's LiveView JS hook bundle. Wired into the host's
// LiveSocket via `PhoenixKitAI.js_sources/0` -> folded into
// `window.PhoenixKitHooks` by the `:phoenix_kit_js_sources` compiler (see
// PhoenixKit.Module.js_sources/0 docs). Hook names are prefixed to stay
// unique across every module's bundle.
window.PhoenixKitAIHooks = (function () {
  // Must match PhoenixKitAI.Realtime.Session's `sample_rate` (currently
  // hardcoded to 24_000 in lib/phoenix_kit_ai/web/playground.ex) and the
  // `codec: "pcm"` it requests from Xai.Realtime.connect_tts/1 — xAI's
  // realtime PCM is 16-bit signed little-endian, mono, matching the
  // convention used by comparable streaming TTS/voice APIs.
  const SAMPLE_RATE = 24000;

  // Streams base64-encoded 16-bit PCM chunks (pushed via the
  // "xai-audio-chunk" event) into a running AudioContext, scheduling each
  // chunk back-to-back for gapless playback. Raw PCM + Web Audio scheduling
  // is used instead of MediaSource + a compressed codec (e.g. mp3) because
  // MediaSource's incremental-append support for compressed formats is
  // unreliable across browsers, while scheduling PCM buffers needs no
  // format-specific demuxing at all.
  //
  // This hook also renders its own status line (chunk counts, AudioContext
  // state) directly into its otherwise-empty div (`phx-update="ignore"`, so
  // LiveView never fights it for control of this content) — audio played
  // via the Web Audio API has no visible player at all, so without this
  // there's no way to tell "silently not working" apart from "actually
  // playing" short of trusting your ears.
  const XaiVoiceStream = {
    mounted() {
      this.audioContext = null;
      this.nextStartTime = 0;
      this.chunksReceived = 0;
      this.chunksScheduled = 0;

      // Browser autoplay policy requires the AudioContext to be created
      // (or at least resumed) synchronously inside a real user-gesture
      // handler — audio chunks arrive later, asynchronously, via
      // push_event over the LiveView socket, which does NOT count as a
      // gesture. Without this, the context is silently created
      // `suspended` on first chunk arrival and nothing ever plays: no
      // error, no console warning, just silence. `this.el` is this
      // hook's own div, not the Connect/Speak buttons elsewhere in the
      // form, so listen document-wide for the first click instead.
      this._unlockAudio = () => this.ensureContext().resume();
      document.addEventListener("click", this._unlockAudio, { once: true });

      this.handleEvent("xai-audio-chunk", ({ data }) => {
        this.chunksReceived += 1;
        this.enqueueChunk(data);
        this.renderStatus();
      });

      this.renderStatus();
    },

    destroyed() {
      document.removeEventListener("click", this._unlockAudio);

      if (this.audioContext) {
        this.audioContext.close();
      }
    },

    ensureContext() {
      if (!this.audioContext) {
        const Ctx = window.AudioContext || window.webkitAudioContext;
        this.audioContext = new Ctx({ sampleRate: SAMPLE_RATE });
        this.nextStartTime = this.audioContext.currentTime;
        this.audioContext.onstatechange = () => this.renderStatus();
      }

      return this.audioContext;
    },

    enqueueChunk(base64Data) {
      const context = this.ensureContext();

      // Defensive resume — covers e.g. a browser re-suspending the
      // context after the tab was backgrounded between chunks. A no-op
      // (resolved immediately) when already running.
      if (context.state !== "running") {
        context.resume();
      }

      const pcm16 = base64ToInt16Array(base64Data);
      if (pcm16.length === 0) return;

      const buffer = context.createBuffer(1, pcm16.length, SAMPLE_RATE);
      const channel = buffer.getChannelData(0);
      for (let i = 0; i < pcm16.length; i++) {
        channel[i] = pcm16[i] / 32768;
      }

      const source = context.createBufferSource();
      source.buffer = buffer;
      source.connect(context.destination);

      // Schedule back-to-back rather than "now" — chunks can arrive
      // faster than they play, and starting each one immediately would
      // overlap/garble audio instead of queuing it.
      const startAt = Math.max(this.nextStartTime, context.currentTime);
      source.start(startAt);
      this.nextStartTime = startAt + buffer.duration;
      this.chunksScheduled += 1;

      source.onended = () => this.renderStatus();
    },

    // Plays a short 440Hz tone directly via Web Audio, with no dependency
    // on xAI at all — isolates "is Web Audio output broken on this
    // browser/device" (wrong output device, muted tab, OS-level block)
    // from "is the xAI realtime pipeline broken."
    playTestTone() {
      const context = this.ensureContext();
      context.resume();

      const osc = context.createOscillator();
      const gain = context.createGain();
      osc.frequency.value = 440;
      gain.gain.value = 0.2;
      osc.connect(gain);
      gain.connect(context.destination);
      osc.start();
      osc.stop(context.currentTime + 0.3);
    },

    renderStatus() {
      const state = this.audioContext ? this.audioContext.state : "not created yet";

      this.el.innerHTML =
        '<div class="flex items-center gap-3 text-xs text-base-content/60 mt-2">' +
        "<span>Audio context: <strong>" +
        state +
        "</strong></span>" +
        "<span>Chunks: " +
        this.chunksReceived +
        " received / " +
        this.chunksScheduled +
        " scheduled</span>" +
        '<button type="button" data-role="test-tone" class="btn btn-xs btn-outline">Test speaker</button>' +
        "</div>";

      this.el.querySelector('[data-role="test-tone"]').addEventListener("click", () => {
        this.playTestTone();
      });
    },
  };

  function base64ToInt16Array(base64Data) {
    const binary = atob(base64Data);
    const bytes = new Uint8Array(binary.length);
    for (let i = 0; i < binary.length; i++) {
      bytes[i] = binary.charCodeAt(i);
    }
    // Int16Array requires an even byte length and 2-byte alignment;
    // Uint8Array.buffer is freshly allocated here, so both hold.
    return new Int16Array(bytes.buffer);
  }

  return { XaiVoiceStream };
})();
