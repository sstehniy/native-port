#pragma once
#include "common.h"

namespace d3dm {
id<MTLFunction> utility_function(id<MTLDevice> metal,NSString *name);
id<MTLComputePipelineState> utility_compute(id<MTLDevice> metal,NSString *name);
id<MTLRenderPipelineState> utility_clear(id<MTLDevice> metal,MTLPixelFormat color,MTLPixelFormat depth,NSUInteger samples);
}
