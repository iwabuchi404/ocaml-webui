import {
  defineCommand,
  invokeCommandHandle,
  ProtocolError,
} from "./client.js";
import {
  writeTextAnalyzeRequest,
  readTextAnalyzeResult,
  readTextAnalyzeError,
} from "./text_analyze.js";
import type {
  TextAnalyzeRequest,
  TextAnalyzeResult,
  TextAnalyzeError,
} from "./text_analyze.js";

declare global {
  // eslint-disable-next-line no-var
  var __async_report: (result: string) => Promise<unknown>;
}

/** Async command descriptors — same payload codec as text.analyze,
    different command names registered via define_async on the OCaml side. */
const asyncAnalyze = defineCommand<
  TextAnalyzeRequest,
  TextAnalyzeResult,
  TextAnalyzeError
>("async.analyze", writeTextAnalyzeRequest, readTextAnalyzeResult, readTextAnalyzeError);

const slowAnalyze = defineCommand<
  TextAnalyzeRequest,
  TextAnalyzeResult,
  TextAnalyzeError
>("async.slow", writeTextAnalyzeRequest, readTextAnalyzeResult, readTextAnalyzeError);

const sleep = (ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms));

function assert(condition: boolean, message: string): void {
  if (!condition) {
    throw new Error(`async probe assertion failed: ${message}`);
  }
}

async function runProbe(): Promise<void> {
  // 1. Async resolve — worker completes and the typed result comes back.
  const hResolve = invokeCommandHandle(
    asyncAnalyze,
    { text: "hello async world", delay_ms: 300 },
    { requestId: "request-async-resolve", traceId: "trace-async-resolve" },
  );
  const result = await hResolve.promise;
  assert(result.bytes === 17, `resolve bytes: ${result.bytes}`);
  assert(result.words === 3, `resolve words: ${result.words}`);
  assert(
    result.observed_trace_id === "trace-async-resolve",
    `resolve observed_trace_id: ${result.observed_trace_id}`,
  );

  // 2. Cancel on an already-completed request — ack reports cancelled=false.
  const lateAck = await hResolve.cancel();
  assert(lateAck.cancelled === false, `late cancel ack: ${JSON.stringify(lateAck)}`);
  assert(
    lateAck.targetRequestId === "request-async-resolve",
    `late cancel target: ${lateAck.targetRequestId}`,
  );

  // 3. JS cancel — ack cancelled=true and the promise rejects as
  //    ProtocolError (category "cancelled"), not an application error.
  const hCancel = invokeCommandHandle(
    asyncAnalyze,
    { text: "cancel me", delay_ms: 2000 },
    { requestId: "request-js-cancel", traceId: "trace-js-cancel" },
  );
  await sleep(150);
  const ack = await hCancel.cancel();
  assert(ack.cancelled === true, `cancel ack: ${JSON.stringify(ack)}`);
  assert(
    ack.targetRequestId === "request-js-cancel",
    `cancel target: ${ack.targetRequestId}`,
  );
  try {
    await hCancel.promise;
    throw new Error("cancelled request unexpectedly resolved");
  } catch (e) {
    assert(e instanceof ProtocolError, `cancel: expected ProtocolError, got ${e}`);
    const pe = e as ProtocolError;
    assert(pe.category === "cancelled", `cancel category: ${pe.category}`);
    assert(pe.code === "cancelled", `cancel code: ${pe.code}`);
    assert(pe.retryable === false, `cancel retryable: ${pe.retryable}`);
    assert(pe.requestId === "request-js-cancel", `cancel requestId: ${pe.requestId}`);
    assert(pe.traceId === "trace-js-cancel", `cancel traceId: ${pe.traceId}`);
  }

  // 4. OCaml timeout watchdog — async.slow is installed with
  //    timeout_ms:400, so a 1500ms request must reject as timeout.
  const hTimeout = invokeCommandHandle(
    slowAnalyze,
    { text: "time me out", delay_ms: 1500 },
    { requestId: "request-ocaml-timeout", traceId: "trace-ocaml-timeout" },
  );
  try {
    await hTimeout.promise;
    throw new Error("timed-out request unexpectedly resolved");
  } catch (e) {
    assert(e instanceof ProtocolError, `timeout: expected ProtocolError, got ${e}`);
    const pe = e as ProtocolError;
    assert(pe.category === "timeout", `timeout category: ${pe.category}`);
    assert(pe.code === "timeout", `timeout code: ${pe.code}`);
    assert(pe.retryable === true, `timeout retryable: ${pe.retryable}`);
    assert(pe.requestId === "request-ocaml-timeout", `timeout requestId: ${pe.requestId}`);
  }

  // 5. JS-side timeoutMs on the untyped ocamlWebui.invokeHandle —
  //    client-side reject with category "timeout" plus a cancel to OCaml.
  const raw = (globalThis as any).ocamlWebui.invokeHandle(
    asyncAnalyze.name,
    { text: "x", delayMs: 1500 },
    {
      requestId: "request-js-timeout",
      traceId: "trace-js-timeout",
      timeoutMs: 150,
    },
  );
  try {
    await raw.promise;
    throw new Error("js-timeout request unexpectedly resolved");
  } catch (e: any) {
    assert(e?.category === "timeout", `js timeout category: ${e?.category}`);
    assert(e?.retryable === true, `js timeout retryable: ${e?.retryable}`);
  }

  await globalThis.__async_report("pass");
}

// Self-execute when bundled as IIFE in WebView
(async () => {
  try {
    await runProbe();
  } catch (error) {
    await globalThis.__async_report(
      "fail:" + ((error as Error)?.stack || JSON.stringify(error)),
    );
  }
})();
