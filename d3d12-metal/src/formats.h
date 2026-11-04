#pragma once
#include "common.h"

namespace d3dm {
struct FormatInfo {
    MTLPixelFormat metal = MTLPixelFormatInvalid;
    DXGI_FORMAT family = DXGI_FORMAT_UNKNOWN;
    unsigned bytes = 0;
    unsigned block = 1;
    unsigned planes = 1;
    bool typeless = false;
    bool depth = false;
    bool view_only = false;
};
FormatInfo format_info(DXGI_FORMAT format);
bool format_needs_pixel_format_view(DXGI_FORMAT format);
}
