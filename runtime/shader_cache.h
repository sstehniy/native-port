#pragma once

HRESULT rt_load_shader(void *metal, const void *root, SIZE_T root_size, const void *code, SIZE_T code_size,
                       UINT unorm8_mask, D3DMShader *shader);
const char *rt_pipeline_archive_path();
bool rt_spatial_upscale_source(const D3D12_GRAPHICS_PIPELINE_STATE_DESC *desc, UINT *parameter, UINT *index);
