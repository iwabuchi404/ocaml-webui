module Async = Webui_async

let fail msg = failwith msg

let expect_spawn_await () =
  let task = Async.spawn (fun () -> 40 + 2) in
  if Async.await task <> 42 then fail "spawn/await mismatch"

let expect_parallel () =
  let results =
    Async.parallel [ (fun () -> 1); (fun () -> 2); (fun () -> 3) ]
  in
  if results <> [ 1; 2; 3 ] then fail "parallel order/values mismatch"

let expect_parallel_results_partial () =
  let results =
    Async.parallel_results
      [ (fun () -> 1); (fun () -> failwith "boom"); (fun () -> 3) ]
  in
  match results with
  | [ Ok 1; Error _; Ok 3 ] -> ()
  | _ -> fail "parallel_results partial failure mismatch"

exception Test_boom

let expect_parallel_rethrows () =
  match
    Async.parallel [ (fun () -> 1); (fun () -> raise Test_boom) ]
  with
  | exception Test_boom -> ()
  | _ -> fail "parallel should re-raise worker exception"

let expect_parallel_rethrow_joins_all () =
  let joined = Atomic.make false in
  (match
     Async.parallel
       [
         (fun () -> raise Test_boom);
         (fun () ->
           Async.sleep_ms 30;
           Atomic.set joined true);
       ]
   with
  | exception Test_boom -> ()
  | _ -> fail "parallel should re-raise worker exception");
  if not (Atomic.get joined) then
    fail "parallel re-raised before joining remaining domains"

let expect_token () =
  let token = Async.token () in
  if Async.is_cancelled token then fail "fresh token is cancelled";
  if Async.cancel_reason token <> None then fail "fresh token has reason";
  Async.cancel token `Js_cancel;
  if not (Async.is_cancelled token) then fail "cancel not reflected";
  match Async.cancel_reason token with
  | Some `Js_cancel -> ()
  | _ -> fail "cancel reason mismatch"

let expect_external_check () =
  let flag = Atomic.make false in
  let token =
    Async.token
      ~external_check:(fun () ->
        if Atomic.get flag then Some `Window_close else None)
      ()
  in
  if Async.is_cancelled token then fail "external check fired early";
  Atomic.set flag true;
  if not (Async.is_cancelled token) then fail "external check not honored";
  match Async.cancel_reason token with
  | Some `Window_close -> ()
  | _ -> fail "external cancel reason mismatch"

let expect_sleep_ms () =
  let start = Unix.gettimeofday () in
  Async.sleep_ms 30;
  if Unix.gettimeofday () -. start < 0.02 then fail "sleep_ms returned early"

let () =
  expect_spawn_await ();
  expect_parallel ();
  expect_parallel_results_partial ();
  expect_parallel_rethrows ();
  expect_parallel_rethrow_joins_all ();
  expect_token ();
  expect_external_check ();
  expect_sleep_ms ();
  Printf.printf
    "webui_async_test: passed spawn parallel results token external sleep\n%!"
