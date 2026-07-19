param(
  [Parameter(Mandatory = $true)]
  [string] $Source,

  [Parameter(Mandatory = $true)]
  [string] $Target
)

function Replace-Exactly {
  param(
    [string] $Text,
    [string] $Pattern,
    [string] $Replacement,
    [int] $ExpectedCount,
    [string] $Label
  )

  $count = [regex]::Matches($Text, $Pattern).Count
  if ($count -ne $ExpectedCount) {
    throw "Expected $ExpectedCount matches for $Label, found $count"
  }
  return [regex]::Replace($Text, $Pattern, $Replacement)
}

$text = [IO.File]::ReadAllText($Source)

$text = Replace-Exactly $text `
  '  caml_release_runtime_system\(\);\r?\n  CAMLdrop;' `
  "  CAMLdrop;`n  caml_release_runtime_system();" 2 'cleanup order'

$text = Replace-Exactly $text `
  '#include <cstdint>' `
  "#include <atomic>`n#include <cstdint>" 1 'atomic include'

$dispatchStructWithCounter = @'
struct ocaml_dispatch {
  value closure; /* registered global root */
};

static std::atomic<int> g_dispatch_roots{0};
'@
$text = Replace-Exactly $text `
  'struct ocaml_dispatch \{\r?\n  value closure; /\* registered global root \*/\r?\n\};' `
  $dispatchStructWithCounter.Trim() 1 'dispatch root counter'

$text = Replace-Exactly $text `
  '  caml_register_generational_global_root\(&d->closure\);' `
  "  caml_register_generational_global_root(&d->closure);`n  g_dispatch_roots.fetch_add(1, std::memory_order_relaxed);" `
  1 'dispatch root increment'

$text = Replace-Exactly $text `
  '  caml_remove_generational_global_root\(&d->closure\);' `
  "  caml_remove_generational_global_root(&d->closure);`n  g_dispatch_roots.fetch_sub(1, std::memory_order_relaxed);" `
  2 'dispatch root decrement'

$debugFunctions = @'

CAMLprim value ocaml_webview_debug_binding_root_count(value vunit) {
  CAMLparam1(vunit);
  CAMLreturn(Val_long(static_cast<intnat>(g_bindings.size())));
}

CAMLprim value ocaml_webview_debug_dispatch_root_count(value vunit) {
  CAMLparam1(vunit);
  CAMLreturn(Val_long(g_dispatch_roots.load(std::memory_order_relaxed)));
}

} /* extern "C" */
'@
$text = Replace-Exactly $text `
  '} /\* extern "C" \*/\s*$' $debugFunctions.Trim() 1 'debug functions'

[IO.File]::WriteAllText($Target, $text, [Text.UTF8Encoding]::new($false))

