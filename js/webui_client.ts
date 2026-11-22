/**
 * webui_client.ts — typed client for the ocaml-webui bridge (protocol v1).
 *
 * This file is emitted by `ocaml-webui.command-gen --emit-client` and is the
 * canonical JS-side counterpart of the OCaml bridge. Do not edit a generated
 * copy; customize by writing your own client against the raw
 * `__ocaml_webui_invoke` envelope (documented in docs/commands-manifest).
 *
 * Protocol v1 envelope:
 *   request:  { protocol: 1, requestId, traceId, command, payload }
 *   response: { protocol: 1, requestId, traceId, command, ok, value? | error? }
 *   cancel:   { protocol: 1, kind: "cancel", requestId, traceId,
 *               targetRequestId }
 */

declare global {
  // eslint-disable-next-line no-var
  var __ocaml_webui_invoke: (request: unknown) => Promise<unknown>;
}

/** Wire protocol version this client speaks. */
export const PROTOCOL_VERSION = 1;

/** Native response envelope from the OCaml bridge. */
export interface NativeResponse {
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
  readonly category: string;
  readonly retryable: boolean;

  constructor(response: NativeResponse) {
    const err = response.error ?? {
      code: "unknown",
      message: "no error field",
      category: "protocol",
      retryable: false,
    };
    super(err.message);
    this.name = "ProtocolError";
    this.requestId = response.requestId;
    this.traceId = response.traceId;
    this.code = err.code;
    this.category = err.category;
    this.retryable = err.retryable;
  }
}

/** Application error — wraps the typed error decoded by the codec. */
export class ApplicationError<E> extends Error {
  readonly requestId: string | null;
  readonly traceId: string | null;
  readonly typedError: E;

  constructor(response: NativeResponse, typedError: E) {
    super("application error");
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

/** Send a cooperative-cancel envelope for an in-flight request. */
export function cancelCommand(requestId: string, traceId: string): void {
  // eslint-disable-next-line @typescript-eslint/no-floating-promises
  void globalThis.__ocaml_webui_invoke({
    protocol: PROTOCOL_VERSION,
    kind: "cancel",
    requestId: generateId("request"),
    traceId,
    targetRequestId: requestId,
  });
}

/** Typed invoke: encodes the request, sends it, decodes the response. */
export async function invokeCommand<I, O, E>(
  descriptor: CommandDescriptor<I, O, E>,
  input: I,
  options: InvokeOptions = {},
): Promise<O> {
  const payload = descriptor.writeRequest(input);
  let response: NativeResponse;
  try {
    response = (await globalThis.__ocaml_webui_invoke({
      protocol: PROTOCOL_VERSION,
      requestId: options.requestId ?? generateId("request"),
      traceId: options.traceId ?? generateId("trace"),
      command: descriptor.name,
      payload,
    })) as NativeResponse;
  } catch (rejection: unknown) {
    response = rejection as NativeResponse;
  }

  if (response.protocol !== undefined && response.protocol !== PROTOCOL_VERSION) {
    throw new ProtocolError({
      protocol: response.protocol,
      requestId: response.requestId ?? null,
      traceId: response.traceId ?? null,
      command: descriptor.name,
      ok: false,
      error: {
        code: "protocol_version_mismatch",
        message: `expected protocol ${PROTOCOL_VERSION}, got ${response.protocol}`,
        retryable: false,
        category: "protocol",
      },
    });
  }

  if (response.ok) {
    return descriptor.readResult(response.value);
  }

  const category = response.error?.category;
  if (
    category === "protocol" ||
    category === "internal" ||
    category === "cancelled" ||
    category === "timeout"
  ) {
    throw new ProtocolError(response);
  }

  try {
    const typedError = descriptor.readError(response.error);
    throw new ApplicationError<E>(response, typedError);
  } catch (e) {
    if (e instanceof ApplicationError) throw e;
  }

  throw new ProtocolError(response);
}

/** Define a typed command from its name and generated codec functions. */
export function defineCommand<I, O, E>(
  name: string,
  writeRequest: (input: I) => unknown,
  readResult: (json: unknown) => O,
  readError: (json: unknown) => E,
): CommandDescriptor<I, O, E> {
  return { name, writeRequest, readResult, readError };
}

let sequence = 0;
function generateId(prefix: string): string {
  sequence += 1;
  if (
    globalThis.crypto &&
    typeof globalThis.crypto.randomUUID === "function"
  ) {
    return `${prefix}-${globalThis.crypto.randomUUID()}`;
  }
  return `${prefix}-${Date.now().toString(36)}-${sequence.toString(36)}`;
}
