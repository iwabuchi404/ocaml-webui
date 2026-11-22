/**
 * examples/typed-hello — manifest駆動Command + 生成client の最小UI。
 *
 * 生成物:
 *   ./hello.js        — atdts生成 codec (schema/hello.atd)
 *   ./commands_gen.js — command-gen生成 descriptor (bin/commands.json)
 *   ./client.js       — command-gen --emit-client 生成 runtime client
 */
import {
  invokeCommand,
  cancelCommand,
  ProtocolError,
  ApplicationError,
  type InvokeOptions,
} from "./client.js";
import { helloPing, workCount, traceRecent } from "./commands_gen.js";

const out = (msg: string) => {
  const el = document.getElementById("out")!;
  el.textContent += msg + "\n";
};

const describeError = (e: unknown): string => {
  if (e instanceof ApplicationError) {
    return `ApplicationError: ${JSON.stringify(e.typedError)} (traceId=${e.traceId})`;
  }
  if (e instanceof ProtocolError) {
    return `ProtocolError ${e.code} [${e.category}] retryable=${e.retryable}: ${e.message}`;
  }
  return String(e);
};

let nextId = 0;
const invokeOpts = (): InvokeOptions & { requestId: string; traceId: string } => {
  nextId += 1;
  return {
    requestId: `request-${nextId}`,
    traceId: `trace-${nextId}`,
  };
};

const byId = <T extends HTMLElement = HTMLElement>(id: string): T =>
  document.getElementById(id) as T;

function buildUi() {
  const root = byId("app");
  root.innerHTML = `
    <h1>ocaml-webui — typed-hello</h1>

    <h2>hello.ping (sync, typed error)</h2>
    <input id="pingMessage" placeholder="message" value="hello">
    <button id="ping">invoke hello.ping</button>

    <h2>work.count (async, cancel)</h2>
    <input id="workTarget" type="number" value="5" min="1" max="100">
    <input id="workDelay" type="number" value="500" step="100">
    <button id="work">invoke work.count</button>
    <button id="cancel">cancel in-flight</button>

    <h2>trace.recent (raw_json)</h2>
    <button id="trace">show trace</button>

    <pre id="out"></pre>`;

  byId<HTMLButtonElement>("ping").onclick = async () => {
    const message = byId<HTMLInputElement>("pingMessage").value;
    try {
      const r = await invokeCommand(helloPing, { message }, invokeOpts());
      out(`hello.ping -> ${JSON.stringify(r)}`);
    } catch (e) {
      out(`hello.ping error -> ${describeError(e)}`);
    }
  };

  let lastWork: { requestId: string; traceId: string } | null = null;
  byId<HTMLButtonElement>("work").onclick = async () => {
    const target = Number(byId<HTMLInputElement>("workTarget").value);
    const delayMs = Number(byId<HTMLInputElement>("workDelay").value);
    const opts = invokeOpts();
    lastWork = opts;
    out(`work.count (${target} x ${delayMs}ms) requestId=${opts.requestId} ...`);
    try {
      const r = await invokeCommand(
        workCount,
        { target, delay_ms: delayMs },
        opts,
      );
      out(`work.count -> ${JSON.stringify(r)}`);
    } catch (e) {
      out(`work.count error -> ${describeError(e)}`);
    }
  };

  byId<HTMLButtonElement>("cancel").onclick = () => {
    if (lastWork) {
      cancelCommand(lastWork.requestId, lastWork.traceId);
      out(`cancel sent for ${lastWork.requestId}`);
    } else {
      out("no in-flight work.count");
    }
  };

  byId<HTMLButtonElement>("trace").onclick = async () => {
    try {
      const r = await invokeCommand(traceRecent, null, invokeOpts());
      out(`trace.recent -> ${r.events.length} events`);
      for (const ev of r.events.slice(-10)) {
        out(`  ${ev.name} cmd=${ev.command} trace=${ev.trace_id}`);
      }
    } catch (e) {
      out(`trace.recent error -> ${describeError(e)}`);
    }
  };
}

buildUi();
