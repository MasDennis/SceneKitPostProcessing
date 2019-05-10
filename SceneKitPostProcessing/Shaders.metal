#include <metal_stdlib>
using namespace metal;
#include <SceneKit/scn_metal>

struct QuadVertex
{
    packed_float3 position;
    packed_float2 texCoords;
};

struct QuadVertexOut
{
    float4 position [[position]];
    float2 texCoords;
};

vertex QuadVertexOut quad_vertex(device QuadVertex *vertices [[buffer(0)]],
                                 uint vid [[vertex_id]])
{
    QuadVertex vertexIn = vertices[vid];
    QuadVertexOut vertexOut;
    vertexOut.position = float4(vertexIn.position, 1.0);
    vertexOut.texCoords = float2(vertexIn.texCoords);
    return vertexOut;
}

fragment float4 quad_fragment(QuadVertexOut inVertex [[stage_in]],
                              texture2d<float> texture1 [[texture(0)]],
                              texture2d<float> texture2 [[texture(1)]],
                              texture2d<float> texture3 [[texture(2)]])
{
    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
    
    float4 color1 = texture1.sample(s, inVertex.texCoords);
    float4 color2 = texture2.sample(s, inVertex.texCoords);
    float4 color3 = texture3.sample(s, inVertex.texCoords);
    
    float4 outColor = color1;
    
    if(color2.b > 0.0 && color3.r < 1.0) {
        outColor = mix(color1, float4(1.0, 1.0, 0.0, 1.0), 0.5);
    }
    
    return outColor;
}

fragment float4 quad_fragment_full(QuadVertexOut inVertex [[stage_in]],
                                   float4 color0 [[color(0)]],
                                   texture2d<float, access::write> texture1 [[texture(0)]],
                                   constant float2 &viewportSize [[ buffer(0) ]])
{
    texture1.write(color0, uint2(inVertex.texCoords.x * viewportSize.x, inVertex.texCoords.y * viewportSize.y), 0);
    
    return color0;
}

struct VertexIn {
    float4 position [[attribute(SCNVertexSemanticPosition)]];
    float2 texCoord0 [[attribute(SCNVertexSemanticTexcoord0)]];
};

struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

constexpr sampler s = sampler(coord::normalized,
                              r_address::clamp_to_edge,
                              t_address::repeat,
                              filter::linear);

vertex VertexOut hudVertex(VertexIn in [[stage_in]]) {
    VertexOut vert;
    vert.position = float4(in.position.xyz, 1.0);
    vert.uv = in.texCoord0;
    
    return vert;
}

fragment half4 hudFragment(VertexOut in [[stage_in]],
                           texture2d<float, access::sample> diffuseTexture [[texture(0)]]) {
    return half4(diffuseTexture.sample(s, in.uv));
}
