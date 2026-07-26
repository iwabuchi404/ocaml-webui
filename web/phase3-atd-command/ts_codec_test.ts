import {
  TextAnalyzeRequest,
  TextAnalyzeResult,
  TextAnalyzeError,
  TextAnalyzeErrorCode,
  readTextAnalyzeRequest,
  writeTextAnalyzeRequest,
  readTextAnalyzeResult,
  writeTextAnalyzeResult,
  readTextAnalyzeError,
  writeTextAnalyzeError,
  readTextAnalyzeErrorCode,
  writeTextAnalyzeErrorCode,
} from "./text_analyze.js";

let failures = 0;

function assert(condition: boolean, message: string): void {
  if (!condition) {
    console.error("FAIL: " + message);
    failures++;
  }
}

function expectThrow(fn: () => void, label: string): void {
  try {
    fn();
    console.error("FAIL: " + label + " — expected throw");
    failures++;
  } catch {
    // expected
  }
}

// Round-trip: request
const requestJson = '{"text":"hello typed bridge","delayMs":50}';
const request = readTextAnalyzeRequest(JSON.parse(requestJson));
assert(request.text === "hello typed bridge", "request.text");
assert(request.delay_ms === 50, "request.delay_ms");
const requestRewritten = writeTextAnalyzeRequest(request);
const requestReparsed = readTextAnalyzeRequest(requestRewritten);
assert(requestReparsed.text === request.text, "request round-trip text");
assert(requestReparsed.delay_ms === request.delay_ms, "request round-trip delay_ms");

// Round-trip: result
const resultJson = '{"bytes":18,"words":3,"observedTraceId":"trace-success"}';
const result = readTextAnalyzeResult(JSON.parse(resultJson));
assert(result.bytes === 18, "result.bytes");
assert(result.words === 3, "result.words");
assert(result.observed_trace_id === "trace-success", "result.observed_trace_id");
const resultRewritten = writeTextAnalyzeResult(result);
const resultReparsed = readTextAnalyzeResult(resultRewritten);
assert(resultReparsed.bytes === result.bytes, "result round-trip bytes");
assert(resultReparsed.words === result.words, "result round-trip words");
assert(resultReparsed.observed_trace_id === result.observed_trace_id, "result round-trip observedTraceId");

// Round-trip: error
const errorJson = '{"code":"empty_text","message":"text must not be empty","retryable":false,"category":"validation"}';
const error = readTextAnalyzeError(JSON.parse(errorJson));
assert(error.code.kind === "Empty_text", "error.code.kind");
assert(error.message === "text must not be empty", "error.message");
assert(error.retryable === false, "error.retryable");
assert(error.category === "validation", "error.category");
const errorRewritten = writeTextAnalyzeError(error);
const errorReparsed = readTextAnalyzeError(errorRewritten);
assert(errorReparsed.code.kind === "Empty_text", "error round-trip code");
assert(errorReparsed.message === error.message, "error round-trip message");

// Variant wire strings
assert(writeTextAnalyzeErrorCode({ kind: "Empty_text" }) === "empty_text", "variant empty_text wire");
assert(writeTextAnalyzeErrorCode({ kind: "Invalid_delay" }) === "invalid_delay", "variant invalid_delay wire");
assert(writeTextAnalyzeErrorCode({ kind: "Invalid_text" }) === "invalid_text", "variant invalid_text wire");
assert(writeTextAnalyzeErrorCode({ kind: "Invalid_payload" }) === "invalid_payload", "variant invalid_payload wire");

assert(readTextAnalyzeErrorCode("empty_text").kind === "Empty_text", "read variant empty_text");
assert(readTextAnalyzeErrorCode("invalid_delay").kind === "Invalid_delay", "read variant invalid_delay");
assert(readTextAnalyzeErrorCode("invalid_text").kind === "Invalid_text", "read variant invalid_text");
assert(readTextAnalyzeErrorCode("invalid_payload").kind === "Invalid_payload", "read variant invalid_payload");

// Decode failures
expectThrow(() => readTextAnalyzeRequest({ text: "hi" }), "missing delayMs");
expectThrow(() => readTextAnalyzeRequest({ delayMs: 50 }), "missing text");
expectThrow(() => readTextAnalyzeRequest({ text: 123, delayMs: 50 }), "wrong text type");
expectThrow(() => readTextAnalyzeRequest({ text: "hi", delayMs: "50" }), "wrong delayMs type");
expectThrow(() => readTextAnalyzeErrorCode("unknown_code"), "unknown error code");
expectThrow(() => readTextAnalyzeResult({ bytes: 1, words: 2 }), "missing observedTraceId");

// Unknown field tolerance
const extra = readTextAnalyzeRequest({ text: "hi", delayMs: 10, extra: "ignored", more: 42 });
assert(extra.text === "hi", "unknown field tolerance text");
assert(extra.delay_ms === 10, "unknown field tolerance delayMs");

// Malformed native result rejection
expectThrow(() => readTextAnalyzeResult(null), "malformed result: null");
expectThrow(() => readTextAnalyzeResult("string"), "malformed result: string");
expectThrow(() => readTextAnalyzeResult({ bytes: "x", words: 2, observedTraceId: "t" }), "malformed result: wrong bytes type");
expectThrow(() => readTextAnalyzeResult({ bytes: 1, words: 2, observedTraceId: 123 }), "malformed result: wrong observedTraceId type");

// Malformed native error rejection
expectThrow(() => readTextAnalyzeError(null), "malformed error: null");
expectThrow(() => readTextAnalyzeError({ code: "unknown", message: "x", retryable: false, category: "x" }), "malformed error: unknown code");
expectThrow(() => readTextAnalyzeError({ code: "empty_text", message: 123, retryable: false, category: "x" }), "malformed error: wrong message type");

// Error classification: protocol error must not be misclassified as application error
{
  const { textAnalyze, invokeCommand, ProtocolError, ApplicationError } = await import("./client.js");

  // Mock __ocaml_webui_invoke to return a protocol error with invalid_payload code
  const originalInvoke = (globalThis as any).__ocaml_webui_invoke;
  (globalThis as any).__ocaml_webui_invoke = async () => {
    throw {
      protocol: 1,
      requestId: "test-proto",
      traceId: "test-proto",
      command: "text.analyze",
      ok: false,
      error: { code: "invalid_payload", message: "payload decode failed", retryable: false, category: "protocol" },
    };
  };
  try {
    await invokeCommand(textAnalyze, { text: "hi", delay_ms: 0 });
    assert(false, "protocol error should throw");
  } catch (e: any) {
    assert(e instanceof ProtocolError, `protocol error: expected ProtocolError, got ${e?.constructor?.name}`);
    assert(e.code === "invalid_payload", `protocol error code: ${e.code}`);
    assert(e.category === "protocol", `protocol error category: ${e.category}`);
  }
  (globalThis as any).__ocaml_webui_invoke = originalInvoke;

  // Mock __ocaml_webui_invoke to return an application error with validation category
  (globalThis as any).__ocaml_webui_invoke = async () => {
    throw {
      protocol: 1,
      requestId: "test-app",
      traceId: "test-app",
      command: "text.analyze",
      ok: false,
      error: { code: "empty_text", message: "text must not be empty", retryable: false, category: "validation" },
    };
  };
  try {
    await invokeCommand(textAnalyze, { text: "hi", delay_ms: 0 });
    assert(false, "application error should throw");
  } catch (e: any) {
    assert(e instanceof ApplicationError, `app error: expected ApplicationError, got ${e?.constructor?.name}`);
    assert(e.typedError.code.kind === "Empty_text", `app error code kind: ${e.typedError.code.kind}`);
    assert(e.typedError.category === "validation", `app error category: ${e.typedError.category}`);
  }
  (globalThis as any).__ocaml_webui_invoke = originalInvoke;

  // Mock __ocaml_webui_invoke to return an internal error
  (globalThis as any).__ocaml_webui_invoke = async () => {
    throw {
      protocol: 1,
      requestId: "test-internal",
      traceId: "test-internal",
      command: "text.analyze",
      ok: false,
      error: { code: "internal_error", message: "command handler raised", retryable: false, category: "internal" },
    };
  };
  try {
    await invokeCommand(textAnalyze, { text: "hi", delay_ms: 0 });
    assert(false, "internal error should throw");
  } catch (e: any) {
    assert(e instanceof ProtocolError, `internal error: expected ProtocolError, got ${e?.constructor?.name}`);
    assert(e.code === "internal_error", `internal error code: ${e.code}`);
    assert(e.category === "internal", `internal error category: ${e.category}`);
  }
  (globalThis as any).__ocaml_webui_invoke = originalInvoke;
}

if (failures > 0) {
  console.error(`${failures} test(s) failed`);
  process.exit(1);
} else {
  console.log("ts_codec_test: passed round-trip decode variant unknown-field malformed error-classification");
}
