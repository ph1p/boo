import Foundation

let metalShaderSource = """
#include <metal_stdlib>
using namespace metal;

struct CellInstance {
    float2 position;
    float2 size;
    float2 uvOrigin;
    float2 uvSize;
    float4 fgColor;
    float4 bgColor;
    uint flags;
    float3 _pad;
};

struct Uniforms {
    float2 viewportSize;
};

struct VertexOut {
    float4 position [[position]];
    float2 texCoord;
    float4 fgColor;
    float4 bgColor;
    uint flags;
};

constant float2 quadVertices[] = {
    float2(0, 0), float2(1, 0), float2(0, 1),
    float2(1, 0), float2(1, 1), float2(0, 1),
};

vertex VertexOut cellVertex(
    uint vertexID [[vertex_id]],
    uint instanceID [[instance_id]],
    const device CellInstance *instances [[buffer(0)]],
    constant Uniforms &uniforms [[buffer(1)]]
) {
    CellInstance cell = instances[instanceID];
    float2 quadPos = quadVertices[vertexID];

    float2 pixelPos = cell.position + quadPos * cell.size;

    float2 ndc;
    ndc.x = (pixelPos.x / uniforms.viewportSize.x) * 2.0 - 1.0;
    ndc.y = 1.0 - (pixelPos.y / uniforms.viewportSize.y) * 2.0;

    VertexOut out;
    out.position = float4(ndc, 0.0, 1.0);
    out.texCoord = cell.uvOrigin + quadPos * cell.uvSize;
    out.fgColor = cell.fgColor;
    out.bgColor = cell.bgColor;
    out.flags = cell.flags;
    return out;
}

fragment float4 cellFragment(
    VertexOut in [[stage_in]],
    texture2d<float> glyphAtlas [[texture(0)]]
) {
    float4 color = in.bgColor;

    bool hasGlyph = (in.flags & 1u) != 0;
    bool isCursor = (in.flags & 2u) != 0;
    bool isUnderline = (in.flags & 4u) != 0;

    if (isCursor) {
        color = in.fgColor;
    }

    if (hasGlyph) {
        constexpr sampler s(mag_filter::linear, min_filter::linear);
        float4 glyphSample = glyphAtlas.sample(s, in.texCoord);
        float alpha = glyphSample.r;

        float4 textColor = isCursor ? in.bgColor : in.fgColor;
        color = mix(color, textColor, alpha);
    }

    if (isUnderline && in.texCoord.y > 0.9375) {
        color = in.fgColor;
    }

    return color;
}
"""
