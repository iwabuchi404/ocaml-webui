import {
  TextAnalyzeRequest,
  TextAnalyzeResult,
  TextAnalyzeError,
  writeTextAnalyzeRequest,
  readTextAnalyzeResult,
  readTextAnalyzeError,
} from "./text_analyze.js";

declare global {
  // eslint-disable-next-line no-var
  var __ocaml_webui_invoke: (request: unknown) => Promise<unknown>;
}

/** Native response envelope from the OCaml bridge. */
interface NativeResponse {
  protocol: number;
  requestId: string | null;
  traceId: string | null;
  command: string | null;
  ok: boolean;
  value?: unknown;
  error?: {
    code: string;
    message: string;
    retryable: boolean;
    category: string;
  };
}

/** Protocol-level error (not an application error). */
export class ProtocolError extends Error {
  readonly requestId: string | null;
  readonly traceId: string | null;
  readonly code: string;
  readonly message: string;
  readonly category: string;
  readonly retryable: boolean;

  constructor(response: NativeResponse) {
    const err = response.error ?? { code: "unknown", message: "no error field", category: "protocol", retryable: false };
    super(err.message);
    this.name = "ProtocolError";
    this.requestId = response.requestId;
    this.traceId = response.traceId;
    this.code = err.code;
    this.message = err.message;
    this.category = err.category;
    this.retryable = err.retryable;
  }
}

/** Application error — wraps the ATD-generated typed error. */
export class ApplicationError<E> extends Error {
  readonly requestId: string | null;
  readonly traceId: string | null;
  readonly typedError: E;

  constructor(response: NativeResponse, typedError: E) {
    super(`application error`);
    this.name = "ApplicationError";
    this.requestId = response.requestId;
    this.traceId = response.traceId;
    this.typedError = typedError;
  }
}

/** A Command descriptor linking the command name to its typed codec. */
export interface CommandDescriptor<I, O, E> {
  name: string;
  writeRequest: (input: I) => unknown;
  readResult: (json: unknown) => O;
  readError: (json: unknown) => E;
}

/** Invoke options for request identity. */
export interface InvokeOptions {
  requestId?: string;
  traceId?: string;
}

/** Typed invoke: encodes the request, sends it, decodes the response. */
export async function invokeCommand<I, O, E>(
  descriptor: CommandDescriptor<I, O, E>,
  input: I,
  options: InvokeOptions = {}
): Promise<O> {
  const payload = descriptor.writeRequest(input);
  let response: NativeResponse;
  try {
    response = await globalThis.__ocaml_webui_invoke({
      protocol: 1,
      requestId: options.requestId ?? generateId("request"),
      traceId: options.traceId ?? generateId("trace"),
      command: descriptor.name,
      payload,
    }) as NativeResponse;
  } catch (rejection: unknown) {
    // __ocaml_webui_invoke rejects with the response object when ok=false
    response = rejection as NativeResponse;
  }

  if (response.ok) {
    return descriptor.readResult(response.value);
  }

  // Protocol/internal errors must not be decoded as application errors,
  // even if the error code happens to match a valid application error variant
  // (e.g. "invalid_payload" exists in both protocol and application error spaces).
  const category = response.error?.category;
  if (category === "protocol" || category === "internal") {
    throw new ProtocolError(response);
  }

  // Try to decode as application error
  try {
    const typedError = descriptor.readError(response.error);
    throw new ApplicationError<E>(response, typedError);
  } catch (e) {
    if (e instanceof ApplicationError) throw e;
    // Not an application error — treat as protocol error
  }

  throw new ProtocolError(response);
}

/** Define a typed command from its name and ATD-generated codec functions. */
export function defineCommand<I, O, E>(
  name: string,
  writeRequest: (input: I) => unknown,
  readResult: (json: unknown) => O,
  readError: (json: unknown) => E,
): CommandDescriptor<I, O, E> {
  return { name, writeRequest, readResult, readError };
}

/** The text.analyze command descriptor. */
export const textAnalyze: CommandDescriptor<TextAnalyzeRequest, TextAnalyzeResult, TextAnalyzeError> =
  defineCommand(
    "text.analyze",
    writeTextAnalyzeRequest,
    readTextAnalyzeResult,
    readTextAnalyzeError,
  );

let sequence = 0;
function generateId(prefix: string): string {
  sequence += 1;
  if (globalThis.crypto && typeof globalThis.crypto.randomUUID === "function") {
    return `${prefix}-${globalThis.crypto.randomUUID()}`;
  }
  return `${prefix}-${Date.now().toString(36)}-${sequence.toString(36)}`;
}
