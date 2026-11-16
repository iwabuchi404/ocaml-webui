type scope = App | Named of string | Window of Webui_raw.Window.t

type resource = {
  id : int;
  kind : string;
  name : string;
  scope : scope;
  registered_at : float;
  release : unit -> unit;
  mutable released : bool;
}

type scope_info = [ `App | `Named of string | `Window ]

type info = {
  id : int;
  kind : string;
  name : string;
  scope : scope_info;
  registered_at : float;
}

let mutex = Mutex.create ()
let resources : (int, resource) Hashtbl.t = Hashtbl.create 16
let next_id = ref 0
let trace_sink : Webui_trace.sink option ref = ref None

let set_trace sink = trace_sink := sink

let emit ~name data =
  match !trace_sink with
  | None -> ()
  | Some sink -> sink (Webui_trace.make ~name ~data ())

let scope_info_of = function
  | App -> `App
  | Named s -> `Named s
  | Window _ -> `Window

let same_scope a b =
  match (a, b) with
  | App, App -> true
  | Named x, Named y -> String.equal x y
  | Window x, Window y -> x == y
  | _ -> false

let release r =
  let run =
    Mutex.protect mutex (fun () ->
        if r.released then None
        else (
          r.released <- true;
          Hashtbl.remove resources r.id;
          Some ()))
  in
  match run with
  | None -> ()
  | Some () ->
      emit ~name:"resource_released"
        [
          ("id", `Int r.id);
          ("kind", `String r.kind);
          ("name", `String r.name);
        ];
      (try r.release () with _ -> ())

(* [release] bound under a distinct name so [register]'s [~release]
   parameter does not shadow the module-level function inside the
   [Window.on_destroy] callback. *)
let release_resource = release

let register ~kind ~name ?(scope = App) ~release () =
  let r =
    Mutex.protect mutex (fun () ->
        let id = !next_id in
        incr next_id;
        let r =
          {
            id;
            kind;
            name;
            scope;
            registered_at = Unix.gettimeofday ();
            release;
            released = false;
          }
        in
        Hashtbl.replace resources id r;
        r)
  in
  emit ~name:"resource_registered"
    [
      ("id", `Int r.id);
      ("kind", `String kind);
      ("name", `String name);
      ("scope",
        `String
          (match scope with
          | App -> "app"
          | Named s -> "named:" ^ s
          | Window _ -> "window"));
    ];
  (match scope with
   | Window w -> Webui_raw.Window.on_destroy w (fun () -> release_resource r)
   | _ -> ());
  r

let revoke_scope scope =
  let targets =
    Mutex.protect mutex (fun () ->
        let matching =
          Hashtbl.fold
            (fun _ r acc ->
              if (not r.released) && same_scope r.scope scope then r :: acc
              else acc)
            resources []
        in
        (* reverse registration order *)
        let ordered =
          List.sort
            (fun (a : resource) (b : resource) -> compare b.id a.id)
            matching
        in
        List.iter
          (fun r ->
            r.released <- true;
            Hashtbl.remove resources r.id)
          ordered;
        ordered)
  in
  List.iter
    (fun (r : resource) ->
      emit ~name:"resource_revoked"
        [
          ("id", `Int r.id);
          ("kind", `String r.kind);
          ("name", `String r.name);
        ];
      try r.release () with _ -> ())
    targets;
  List.length targets

let snapshot () =
  Mutex.protect mutex (fun () ->
      Hashtbl.fold
        (fun _ (r : resource) acc ->
          {
            id = r.id;
            kind = r.kind;
            name = r.name;
            scope = scope_info_of r.scope;
            registered_at = r.registered_at;
          }
          :: acc)
        resources []
      |> List.sort (fun a b -> compare a.id b.id))

let leak_count () = Mutex.protect mutex (fun () -> Hashtbl.length resources)
