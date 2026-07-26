import { textAnalyze, invokeCommand, ApplicationError } from "./client.js";
import type { TextAnalyzeRequest, TextAnalyzeResult, TextAnalyzeError } from "./text_analyze.js";

/** Probe application: uses the typed client to invoke text.analyze. */
export async function runProbe(): Promise<void> {
  // Valid request
  const result = await invokeCommand(
    textAnalyze,
    { text: "hello typed bridge", delay_ms: 50 },
    { requestId: "request-success", traceId: "trace-success" },
  );
  assert(result.bytes === 18, `result.bytes: ${result.bytes}`);
  assert(result.words === 3, `result.words: ${result.words}`);
  assert(result.observed_trace_id === "trace-success", `observed_trace_id: ${result.observed_trace_id}`);

  // Empty text validation error
  try {
    await invokeCommand(
      textAnalyze,
      { text: "", delay_ms: 0 },
      { requestId: "request-empty", traceId: "trace-empty" },
    );
    throw new Error("empty text unexpectedly resolved");
  } catch (e) {
    assert(e instanceof ApplicationError, `empty text: expected ApplicationError, got ${e}`);
    const appErr = e as ApplicationError<TextAnalyzeError>;
    assert(appErr.requestId === "request-empty", `empty text requestId: ${appErr.requestId}`);
    assert(appErr.typedError.code.kind === "Empty_text", `empty text code: ${appErr.typedError.code.kind}`);
    assert(appErr.typedError.category === "validation", `empty text category: ${appErr.typedError.category}`);
  }

  // Invalid delay validation error
  try {
    await invokeCommand(
      textAnalyze,
      { text: "valid", delay_ms: -1 },
      { requestId: "request-invalid-delay", traceId: "trace-invalid-delay" },
    );
    throw new Error("invalid delay unexpectedly resolved");
  } catch (e) {
    assert(e instanceof ApplicationError, `invalid delay: expected ApplicationError, got ${e}`);
    const appErr = e as ApplicationError<TextAnalyzeError>;
    assert(appErr.requestId === "request-invalid-delay", `invalid delay requestId: ${appErr.requestId}`);
    assert(appErr.typedError.code.kind === "Invalid_delay", `invalid delay code: ${appErr.typedError.code.kind}`);
  }

  // Unknown command — protocol error
  try {
    await (globalThis as any).__ocaml_webui_invoke({
      protocol: 1,
      requestId: "request-unknown",
      traceId: "trace-unknown",
      command: "missing.command",
      payload: null,
    });
    throw new Error("unknown command unexpectedly resolved");
  } catch (e: any) {
    assert(e?.requestId === "request-unknown", `unknown requestId: ${e?.requestId}`);
    assert(e?.traceId === "trace-unknown", `unknown traceId: ${e?.traceId}`);
    assert(e?.error?.code === "unknown_command", `unknown code: ${e?.error?.code}`);
  }

  // Malformed payload — protocol error (ATD decode failure on native side)
  // Note: typed client validates input before sending, so this must use raw binding.
  // The error classification (ProtocolError vs ApplicationError) is tested in ts_codec_test.
  try {
    await (globalThis as any).__ocaml_webui_invoke({
      protocol: 1,
      requestId: "request-malformed",
      traceId: "trace-malformed",
      command: "text.analyze",
      payload: { text: 123, delayMs: 50 },
    });
    throw new Error("malformed payload unexpectedly resolved");
  } catch (e: any) {
    assert(e?.requestId === "request-malformed", `malformed requestId: ${e?.requestId}`);
    assert(e?.traceId === "trace-malformed", `malformed traceId: ${e?.traceId}`);
    assert(e?.error?.code === "invalid_payload", `malformed code: ${e?.error?.code}`);
    assert(e?.error?.category === "protocol", `malformed category: ${e?.error?.category}`);
  }

  // Handler exception — protocol error
  try {
    await (globalThis as any).__ocaml_webui_invoke({
      protocol: 1,
      requestId: "request-handler-error",
      traceId: "trace-handler-error",
      command: "text.analyze",
      payload: { text: "handler error", delayMs: 0 },
    });
    throw new Error("handler exception unexpectedly resolved");
  } catch (e: any) {
    assert(e?.requestId === "request-handler-error", `handler requestId: ${e?.requestId}`);
    assert(e?.traceId === "trace-handler-error", `handler traceId: ${e?.traceId}`);
    assert(e?.error?.code === "internal_error", `handler code: ${e?.error?.code}`);
    assert(e?.error?.message === "command handler raised", `handler message: ${e?.error?.message}`);
  }

  // Handler raises Exit — must be caught as internal_error, not swallowed
  try {
    await (globalThis as any).__ocaml_webui_invoke({
      protocol: 1,
      requestId: "request-handler-exit",
      traceId: "trace-handler-exit",
      command: "text.analyze",
      payload: { text: "exit test", delayMs: 0 },
    });
    throw new Error("handler exit unexpectedly resolved");
  } catch (e: any) {
    assert(e?.requestId === "request-handler-exit", `exit requestId: ${e?.requestId}`);
    assert(e?.error?.code === "internal_error", `exit code: ${e?.error?.code}`);
    assert(e?.error?.message === "command handler raised", `exit message: ${e?.error?.message}`);
  }

  await (globalThis as any).__baseline_report("pass");
}

function assert(condition: boolean, message: string): void {
  if (!condition) {
    throw new Error(`probe assertion failed: ${message}`);
  }
}

// Self-execute when bundled as IIFE in WebView
(async () => {
  try {
    await runProbe();
  } catch (error) {
    await (globalThis as any).__baseline_report(
      "fail:" + ((error as Error)?.stack || JSON.stringify(error)),
    );
  }
})();
