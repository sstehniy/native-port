#include <metal_stdlib>
using namespace metal;

kernel void mask_indirect(device const uchar *source [[buffer(0)]],device uchar *target [[buffer(1)]],device const uint *counter [[buffer(2)]],constant uint2 &shape [[buffer(3)]],uint i [[thread_position_in_grid]]) {
    if (i<shape.x*shape.y) target[i]=i/shape.y<min(counter[0],shape.x)?source[i]:0;
}
kernel void fill_pattern(device uchar *target [[buffer(0)]],constant uchar *pattern [[buffer(1)]],constant uint4 &shape [[buffer(2)]],uint i [[thread_position_in_grid]]) {
    if (i<shape.x) target[shape.z+i]=pattern[i%shape.y];
}
struct ClearRegion { uint4 origin;uint4 size;float4 value; };
kernel void clear_2d(texture2d_array<float,access::write> target [[texture(0)]],constant ClearRegion &r [[buffer(0)]],uint3 i [[thread_position_in_grid]]) {
    if (all(i<r.size.xyz)) target.write(r.value,r.origin.xy+i.xy,i.z);
}
kernel void clear_3d(texture3d<float,access::write> target [[texture(0)]],constant ClearRegion &r [[buffer(0)]],uint3 i [[thread_position_in_grid]]) {
    if (all(i<r.size.xyz)) target.write(r.value,r.origin.xyz+i);
}
kernel void clear_buffer(texture_buffer<float,access::write> target [[texture(0)]],constant ClearRegion &r [[buffer(0)]],uint i [[thread_position_in_grid]]) {
    if (i<r.size.x) target.write(r.value,r.origin.x+i);
}
struct ClearVertex { float4 position [[position]]; };
vertex ClearVertex clear_vertex(uint index [[vertex_id]],constant float &depth [[buffer(0)]]) {
    const float2 positions[]={float2(-1,-1),float2(3,-1),float2(-1,3)};
    return {float4(positions[index],depth,1)};
}
fragment float4 clear_color(constant float4 &color [[buffer(0)]]) { return color; }
fragment uint4 clear_uint_color(constant float4 &color [[buffer(0)]]) {
    uint4 result;
    for (uint i=0;i<4;++i) {
        if (isnan(color[i]) || color[i]<=0) result[i]=0;
        else if (color[i]>=4294967295.0f) result[i]=0xffffffff;
        else result[i]=uint(color[i]);
    }
    return result;
}
fragment int4 clear_int_color(constant float4 &color [[buffer(0)]]) {
    int4 result;
    for (uint i=0;i<4;++i) {
        if (isnan(color[i])) result[i]=0;
        else if (color[i]>=2147483647.0f) result[i]=0x7fffffff;
        else if (color[i]<=-2147483648.0f) result[i]=int(0x80000000u);
        else result[i]=int(color[i]);
    }
    return result;
}
