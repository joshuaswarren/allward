enum ShaderSource {
    static let metal = #"""
    #include <metal_stdlib>
    using namespace metal;

    struct Uniforms {
        float2 viewportSize;
    };

    struct RectInstance {
        float4 rect;
        float4 color;
    };

    struct GlyphInstance {
        float4 rect;
        float4 uv;
        float4 color;
    };

    struct VertexOutput {
        float4 position [[position]];
        float2 uv;
        float4 color;
    };

    constant float2 unitQuad[4] = {
        float2(0.0, 0.0),
        float2(1.0, 0.0),
        float2(0.0, 1.0),
        float2(1.0, 1.0)
    };

    vertex VertexOutput rectangleVertex(
        uint vertexID [[vertex_id]],
        uint instanceID [[instance_id]],
        constant RectInstance *instances [[buffer(1)]],
        constant Uniforms &uniforms [[buffer(2)]]
    ) {
        const float2 unit = unitQuad[vertexID];
        const RectInstance instance = instances[instanceID];
        const float2 point = instance.rect.xy + unit * instance.rect.zw;
        const float2 clip = float2(
            point.x / uniforms.viewportSize.x * 2.0 - 1.0,
            1.0 - point.y / uniforms.viewportSize.y * 2.0
        );
        VertexOutput output;
        output.position = float4(clip, 0.0, 1.0);
        output.uv = unit;
        output.color = instance.color;
        return output;
    }

    fragment float4 solidFragment(VertexOutput input [[stage_in]]) {
        return input.color;
    }

    vertex VertexOutput glyphVertex(
        uint vertexID [[vertex_id]],
        uint instanceID [[instance_id]],
        constant GlyphInstance *instances [[buffer(1)]],
        constant Uniforms &uniforms [[buffer(2)]]
    ) {
        const float2 unit = unitQuad[vertexID];
        const GlyphInstance instance = instances[instanceID];
        const float2 point = instance.rect.xy + unit * instance.rect.zw;
        const float2 clip = float2(
            point.x / uniforms.viewportSize.x * 2.0 - 1.0,
            1.0 - point.y / uniforms.viewportSize.y * 2.0
        );
        VertexOutput output;
        output.position = float4(clip, 0.0, 1.0);
        output.uv = float2(
            mix(instance.uv.x, instance.uv.z, unit.x),
            mix(instance.uv.y, instance.uv.w, unit.y)
        );
        output.color = instance.color;
        return output;
    }

    fragment float4 monochromeGlyphFragment(
        VertexOutput input [[stage_in]],
        texture2d<float> atlas [[texture(0)]],
        sampler atlasSampler [[sampler(0)]]
    ) {
        const float coverage = atlas.sample(atlasSampler, input.uv).r;
        return float4(input.color.rgb, input.color.a * coverage);
    }

    fragment float4 colorGlyphFragment(
        VertexOutput input [[stage_in]],
        texture2d<float> atlas [[texture(0)]],
        sampler atlasSampler [[sampler(0)]]
    ) {
        return atlas.sample(atlasSampler, input.uv) * input.color.a;
    }
    """#
}
