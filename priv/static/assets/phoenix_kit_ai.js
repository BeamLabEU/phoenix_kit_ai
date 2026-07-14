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
  const XaiVoiceStream = {
    mounted() {
      this.audioContext = null;
      this.nextStartTime = 0;

      this.handleEvent("xai-audio-chunk", ({ data }) => {
        this.enqueueChunk(data);
      });
    },

    destroyed() {
      if (this.audioContext) {
        this.audioContext.close();
      }
    },

    ensureContext() {
      if (!this.audioContext) {
        const Ctx = window.AudioContext || window.webkitAudioContext;
        this.audioContext = new Ctx({ sampleRate: SAMPLE_RATE });
        this.nextStartTime = this.audioContext.currentTime;
      }

      return this.audioContext;
    },

    enqueueChunk(base64Data) {
      const context = this.ensureContext();
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
