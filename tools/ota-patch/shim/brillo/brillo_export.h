// Build shim for libbrillo's export macro.
#pragma once
#define BRILLO_EXPORT __attribute__((__visibility__("default")))
