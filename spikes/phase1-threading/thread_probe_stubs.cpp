#define WIN32_LEAN_AND_MEAN
#include <windows.h>

#define CAML_NAME_SPACE
#include <caml/memory.h>
#include <caml/mlvalues.h>

extern "C" CAMLprim value ocaml_current_thread_id(value unit) {
  CAMLparam1(unit);
  CAMLreturn(Val_long(GetCurrentThreadId()));
}

