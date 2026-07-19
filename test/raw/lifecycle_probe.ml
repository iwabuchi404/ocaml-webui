open Webui_raw.Window

let fail_error error = failwith (Webui_raw.Error.to_string error)

let require = function Ok value -> value | Error error -> fail_error error

let expect_state window expected label =
  let actual = Webui_raw.Window.state window in
  if actual <> expected then
    failwith
      (Printf.sprintf "%s: unexpected state" label)

let html =
  {html|<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><title>Webui_raw lifecycle probe</title></head>
<body style="font-family:system-ui;background:#101728;color:#eef;padding:32px">
  <h1>Webui_raw lifecycle probe</h1>
  <p>The native loop will stop automatically.</p>
</body>
</html>|html}

let run () =
  Printf.printf "webview_version=%s\n%!" (Webui_raw.version ());
  let window = require (Webui_raw.Window.create { debug = true }) in
  expect_state window Created "after create";
  require (Webui_raw.Window.set_title window "Webui_raw lifecycle probe");
  require
    (Webui_raw.Window.set_size window ~width:640 ~height:420 Initial);
  require (Webui_raw.Window.set_html window html);

  let closer =
    Thread.create
      (fun () ->
        Unix.sleepf 0.75;
        require (Webui_raw.Window.request_close window);
        Printf.printf "close_requested state=closing\n%!")
      ()
  in

  require (Webui_raw.Window.run window);
  Thread.join closer;
  expect_state window Stopped "after run";
  require (Webui_raw.Window.destroy window);
  expect_state window Destroyed "after destroy";
  require (Webui_raw.Window.destroy window);

  (match Webui_raw.Window.set_title window "invalid" with
  | Error { code = Webui_raw.Error.Invalid_state; _ } -> ()
  | Ok () -> failwith "set_title unexpectedly succeeded after destroy"
  | Error error -> fail_error error);
  Printf.printf "lifecycle_probe: passed state=destroyed\n%!"

let () =
  Printexc.record_backtrace true;
  try run ()
  with exn ->
    Printf.eprintf "lifecycle_probe: failed: %s\n%s\n%!"
      (Printexc.to_string exn) (Printexc.get_backtrace ());
    exit 1
