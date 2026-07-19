param(
  [Parameter(Mandatory = $true)]
  [string] $Source,

  [Parameter(Mandatory = $true)]
  [string] $Target
)

$text = [IO.File]::ReadAllText($Source)
$pattern = '  caml_release_runtime_system\(\);\r?\n  CAMLdrop;'
$matches = [regex]::Matches($text, $pattern)

if ($matches.Count -ne 2) {
  throw "Expected exactly two unsafe runtime-release/CAMLdrop sequences, found $($matches.Count)"
}

$replacement = "  CAMLdrop;`n  caml_release_runtime_system();"
$patched = [regex]::Replace($text, $pattern, $replacement)
[IO.File]::WriteAllText($Target, $patched, [Text.UTF8Encoding]::new($false))