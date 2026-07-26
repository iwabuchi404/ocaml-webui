import { textAnalyze, invokeCommand, defineCommand, ApplicationError, ProtocolError } from "./client.js";
import type { TextAnalyzeRequest, TextAnalyzeResult, TextAnalyzeError, TextAnalyzeErrorCode } from "./text_analyze.js";
import { writeTextAnalyzeRequest, readTextAnalyzeResult, readTextAnalyzeError } from "./text_analyze.js";

// This file verifies that the TypeScript type system catches wrong inputs
// at compile time. It uses @ts-expect-error to assert that incorrect usage
// is rejected by tsc.

// Correct usage compiles
const _valid: Promise<TextAnalyzeResult> = invokeCommand(
  textAnalyze,
  { text: "hello", delay_ms: 50 },
);

// Wrong field name — should not compile
// @ts-expect-error: 'delay' is not a field of TextAnalyzeRequest
const _wrongField: TextAnalyzeRequest = { text: "hi", delay: 50 };

// Wrong type for text — should not compile
// @ts-expect-error: text must be string, not number
const _wrongType: TextAnalyzeRequest = { text: 123, delay_ms: 50 };

// Missing required field — should not compile
// @ts-expect-error: delay_ms is required
const _missingField: TextAnalyzeRequest = { text: "hi" };

// Extra unknown field — should not compile in strict mode
// @ts-expect-error: 'extra' is not a known field
const _extraField: TextAnalyzeRequest = { text: "hi", delay_ms: 50, extra: "no" };

// Wrong input type to writeTextAnalyzeRequest
// @ts-expect-error: string is not TextAnalyzeRequest
const _wrongInput = writeTextAnalyzeRequest("not a request");

// ApplicationError carries typed error
async function _checkAppError(): Promise<void> {
  try {
    await invokeCommand(textAnalyze, { text: "", delay_ms: 0 });
  } catch (e) {
    if (e instanceof ApplicationError) {
      // typedError is TextAnalyzeError (inferred from the descriptor)
      const _err: TextAnalyzeError = e.typedError;
      const _kind: string = _err.code.kind;
      // @ts-expect-error: 'Unknown' is not assignable to the variant union
      const _badKind: "Unknown" = _err.code.kind;
    }
  }
}

// ProtocolError has code as string
async function _checkProtoError(): Promise<void> {
  try {
    await invokeCommand(textAnalyze, { text: "hi", delay_ms: 50 });
  } catch (e) {
    if (e instanceof ProtocolError) {
      const _code: string = e.code;
      // @ts-expect-error: code is string, not number
      const _badCode: number = e.code;
    }
  }
}

// defineCommand with mismatched types should not compile
const _badDescriptor = defineCommand<TextAnalyzeRequest, TextAnalyzeResult, TextAnalyzeError>(
  "bad",
  // @ts-expect-error: writeRequest expects (input: TextAnalyzeRequest) => unknown but we pass (x: number) => number
  (x: number) => x,
  (json: unknown) => json as TextAnalyzeResult,
  (json: unknown) => json as TextAnalyzeError,
);

// readTextAnalyzeResult returns TextAnalyzeResult, assigning to wrong type should not compile
// @ts-expect-error: TextAnalyzeResult is not a string
const _badResult: string = readTextAnalyzeResult({ bytes: 1, words: 2, observedTraceId: "x" });

// Export to ensure the file is not tree-shaken
export {};
