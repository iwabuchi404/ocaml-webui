(lang dune 3.18)
(name ocaml-webui)

(generate_opam_files true)

(package
 (name ocaml-webui)
 (synopsis "Typed, traceable WebView boundary for OCaml applications")
 (description
  "An OCaml application runtime that owns the WebView boundary, lifecycle,\ndispatch, typed commands, structured errors, and tracing.")
 (license MIT)
 (authors "iwabuchi404")
 (maintainers "iwabuchi404")
 (source (github iwabuchi404/ocaml-webui))
 (documentation "https://github.com/iwabuchi404/ocaml-webui/tree/main/docs")
 (depends
  (ocaml (and (>= "5.4") (< "5.5")))
  dune
  (yojson (>= "3.0"))
  (atd (and (>= "4.2") :build))
  (atdml (and (>= "4.2") :build))
  (atdts (and (>= "4.2") :build))
  conf-c++
  (conf-mingw-w64-g++-x86_64 (and (= :os "win32") (= :arch "x86_64")))))
