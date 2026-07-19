#define WIN32_LEAN_AND_MEAN
#include <windows.h>

#include <cstdint>

#define CAML_NAME_SPACE
#include <caml/memory.h>
#include <caml/mlvalues.h>

extern "C" CAMLprim value ocaml_post_window_close(value vhandle) {
  CAMLparam1(vhandle);
  HWND hwnd = reinterpret_cast<HWND>(
      static_cast<intptr_t>(Nativeint_val(vhandle)));
  if (hwnd == nullptr || !IsWindow(hwnd)) {
    CAMLreturn(Val_false);
  }
  CAMLreturn(Val_bool(PostMessageW(hwnd, WM_CLOSE, 0, 0)));
}

