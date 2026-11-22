// GENERATED FILE — do not edit. Source: command manifest.

import {
  writeEchoRequest,
  readEchoResponse,
  readEchoError,
  type EchoRequest,
  type EchoResponse,
  type EchoError,
} from "./echo.js";

import {
  writeWorkRequest,
  readWorkResult,
  readWorkError,
  type WorkRequest,
  type WorkResult,
  type WorkError,
} from "./work.js";

import { defineCommand, type CommandDescriptor } from "./client.js";

export const echoPing: CommandDescriptor<EchoRequest, EchoResponse, EchoError> =
  defineCommand(
    "echo.ping",
    writeEchoRequest,
    readEchoResponse,
    readEchoError,
  );

export const workSlow: CommandDescriptor<WorkRequest, WorkResult, WorkError> =
  defineCommand(
    "work.slow",
    writeWorkRequest,
    readWorkResult,
    readWorkError,
  );

export interface TraceRecentResult { events: unknown[] }

export const traceRecent: CommandDescriptor<null, TraceRecentResult, never> =
  defineCommand(
    "trace.recent",
    () => null,
    (json) => json as TraceRecentResult,
    (json) => json as never,
  );

