#include <stdbool.h>
#include <stdint.h>

typedef void* ghostty_surface_t;

__attribute__((weak)) float ghostty_surface_font_size(ghostty_surface_t surface) {
    (void)surface;
    return 0.0f;
}
