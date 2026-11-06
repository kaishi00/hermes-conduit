// Conduit's Bot Screen viewer: noVNC's RFB client, fed by the app.
// The app opens /api/display/ws itself (with the connection's own headers)
// and passes the bytes through; this page only draws and sends input.
import RFB from '@novnc/novnc';

const post = (message) => {
  try { window.webkit.messageHandlers.screen.postMessage(message); } catch (e) {}
};

function toBase64(bytes) {
  let binary = '';
  const chunk = 0x8000;
  for (let i = 0; i < bytes.length; i += chunk) {
    binary += String.fromCharCode.apply(null, bytes.subarray(i, i + chunk));
  }
  return btoa(binary);
}

function fromBase64(text) {
  const binary = atob(text);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes.buffer;
}

// A WebSocket as noVNC's Websock reads one; the app is the other end. Its
// messages carry the stream tag the app started it with, so a stopped
// stream's late close never ends the one that replaced it.
class AppChannel {
  constructor(tag) {
    this.tag = tag;
    this.binaryType = 'arraybuffer';
    this.protocol = '';
    this.readyState = 0;
    this.onopen = null;
    this.onmessage = null;
    this.onclose = null;
    this.onerror = null;
  }
  send(data) {
    if (this.readyState !== 1) return;
    const bytes = data instanceof ArrayBuffer ? new Uint8Array(data) : new Uint8Array(data.buffer, data.byteOffset, data.byteLength);
    post({ type: 'send', stream: this.tag, data: toBase64(bytes) });
  }
  close() {
    if (this.readyState >= 2) return;
    this.readyState = 2;
    post({ type: 'close', stream: this.tag });
  }
}

let channel = null;
let rfb = null;
let viewOnly = true;

window.conduitScreen = {
  start(options) {
    window.conduitScreen.stop();
    const tag = options && typeof options.stream === 'number' ? options.stream : null;
    channel = new AppChannel(tag);
    viewOnly = options && options.viewOnly !== undefined ? !!options.viewOnly : true;
    const target = document.getElementById('screen');
    rfb = new RFB(target, channel, { shared: true });
    rfb.scaleViewport = true;
    rfb.resizeSession = false;
    rfb.focusOnClick = true;
    rfb.background = 'transparent';
    rfb.qualityLevel = 7;
    rfb.viewOnly = viewOnly;
    rfb.addEventListener('connect', () => post({ type: 'connected', stream: tag }));
    rfb.addEventListener('disconnect', (event) => {
      post({ type: 'disconnected', stream: tag, clean: !!(event.detail && event.detail.clean) });
    });
    rfb.addEventListener('securityfailure', (event) => {
      post({ type: 'failed', stream: tag, reason: String((event.detail && event.detail.reason) || '') });
    });
  },
  opened() {
    if (!channel) return;
    channel.readyState = 1;
    if (channel.onopen) channel.onopen({});
  },
  data(text) {
    if (!channel || channel.readyState !== 1 || !channel.onmessage) return;
    channel.onmessage({ data: fromBase64(text) });
  },
  closed(code, reason) {
    if (!channel || channel.readyState === 3) return;
    channel.readyState = 3;
    if (channel.onclose) channel.onclose({ code: code || 1006, reason: reason || '', wasClean: code === 1000 });
  },
  setViewOnly(value) {
    viewOnly = !!value;
    if (rfb) {
      rfb.viewOnly = viewOnly;
      if (!viewOnly) rfb.focus();
    }
  },
  paste(text) {
    if (rfb && !viewOnly && typeof text === 'string' && text.length <= 65536) rfb.clipboardPasteFrom(text);
  },
  // Typed on the app's type bar: each keysym pressed and let go.
  keysyms(list) {
    if (!rfb || viewOnly || !Array.isArray(list)) return;
    for (const keysym of list.slice(0, 4096)) {
      if (typeof keysym !== 'number') continue;
      rfb.sendKey(keysym, null, true);
      rfb.sendKey(keysym, null, false);
    }
  },
  stop() {
    if (rfb) {
      try { rfb.disconnect(); } catch (e) {}
    }
    rfb = null;
    channel = null;
  },
};

post({ type: 'ready' });
