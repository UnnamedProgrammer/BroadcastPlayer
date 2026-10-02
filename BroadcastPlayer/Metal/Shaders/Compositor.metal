#include <metal_stdlib>
using namespace metal;

struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

struct FitParameters {
    float2 scale;
    float2 offset;
};

struct BiplanarParameters {
    float yScale;
    float yOffset;
    float rCr;
    float gCb;
    float gCr;
    float bCb;
    float chromaOffset;
};

vertex VertexOut compositor_vertex(uint vertexID [[vertex_id]],
                                   constant FitParameters &fit [[buffer(0)]]) {
    float2 position = float2((vertexID & 1) == 1 ? 1.0 : -1.0,
                             (vertexID & 2) == 2 ? 1.0 : -1.0);
    float2 uv = float2((vertexID & 1) == 1 ? 1.0 : 0.0,
                       (vertexID & 2) == 2 ? 0.0 : 1.0);

    VertexOut out;
    out.position = float4(position * fit.scale + fit.offset, 0.0, 1.0);
    out.uv = uv;
    return out;
}

// Monotone, hue-preserving lift restricted to dark pixels. Exact black and
// pixels with a component >= 0.5 are unchanged; no invented highlight detail.
float3 lift_shadows(float3 rgb, float amount) {
    float peak = max(max(rgb.r, rgb.g), rgb.b);
    float fade = max(1.0 - peak * 2.0, 0.0);
    return rgb * (1.0 + 1.5 * saturate(amount) * fade * fade);
}

fragment float4 compositor_fragment_bgra(VertexOut in [[stage_in]],
                                         texture2d<float> source [[texture(0)]],
                                         constant float &shadowLift [[buffer(1)]]) {
    constexpr sampler sampleFilter(mag_filter::linear,
                                   min_filter::linear,
                                   address::clamp_to_edge);
    return float4(lift_shadows(source.sample(sampleFilter, in.uv).rgb, shadowLift), 1.0);
}

fragment float4 compositor_fragment_biplanar(VertexOut in [[stage_in]],
                                             texture2d<float> luma [[texture(0)]],
                                             texture2d<float> chroma [[texture(1)]],
                                             constant BiplanarParameters &params [[buffer(0)]],
                                             constant float &shadowLift [[buffer(1)]]) {
    constexpr sampler sampleFilter(mag_filter::linear,
                                   min_filter::linear,
                                   address::clamp_to_edge);

    float y = (luma.sample(sampleFilter, in.uv).r - params.yOffset) * params.yScale;
    float2 cbcr = chroma.sample(sampleFilter, in.uv).rg - params.chromaOffset;

    float3 rgb = float3(y + params.rCr * cbcr.y,
                        y + params.gCb * cbcr.x + params.gCr * cbcr.y,
                        y + params.bCb * cbcr.x);

    return float4(lift_shadows(saturate(rgb), shadowLift), 1.0);
}
// Fallback for devices without MetalFX. Mitchell–Netravali (B = C = 1/3):
// gentle filtering rather
// than a sharpen pass. Clamp to the nearest four source pixels to suppress
// overshoot and dark/bright halos around text and high-contrast edges.
float natural_cubic(float distance) {
    float x = abs(distance);
    if (x < 1.0) {
        return ((7.0 * x - 12.0) * x * x + 16.0 / 3.0) / 6.0;
    }
    if (x < 2.0) {
        return (((-7.0 / 3.0 * x + 12.0) * x - 20.0) * x + 32.0 / 3.0) / 6.0;
    }
    return 0.0;
}

kernel void natural_4k_upscale(texture2d<float, access::read> source [[texture(0)]],
                               texture2d<float, access::write> destination [[texture(1)]],
                               uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= destination.get_width() || gid.y >= destination.get_height()) { return; }
    float2 sourceSize = float2(source.get_width(), source.get_height());
    float2 outputSize = float2(destination.get_width(), destination.get_height());
    float2 position = (float2(gid) + 0.5) * sourceSize / outputSize - 0.5;
    int2 base = int2(floor(position));
    float2 fraction = position - float2(base);
    int2 limit = int2(source.get_width() - 1, source.get_height() - 1);
    float3 color = float3(0.0);
    float totalWeight = 0.0;
    float3 localMin = float3(1.0);
    float3 localMax = float3(0.0);
    for (int y = -1; y <= 2; ++y) {
        float wy = natural_cubic(float(y) - fraction.y);
        for (int x = -1; x <= 2; ++x) {
            float3 sample = source.read(uint2(clamp(base + int2(x, y), int2(0), limit))).rgb;
            float weight = wy * natural_cubic(float(x) - fraction.x);
            color += sample * weight;
            totalWeight += weight;
            if (x >= 0 && x <= 1 && y >= 0 && y <= 1) {
                localMin = min(localMin, sample);
                localMax = max(localMax, sample);
            }
        }
    }
    float3 natural = clamp(color / max(totalWeight, 0.0001), localMin, localMax);
    destination.write(float4(natural, 1.0), gid);
}

// Copyright (c) 2017-2019 Advanced Micro Devices, Inc. All rights reserved.
// -------
// Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation
// files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy,
// modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the
// Software is furnished to do so, subject to the following conditions:
// -------
// The above copyright notice and this permission notice shall be included in all copies or substantial portions of the
// Software.
// -------
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE
// WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.  IN NO EVENT SHALL THE AUTHORS OR
// COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE,
// ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
//------------------------------------------------------------------------------------------------------------------------------

// Adapted CAS sharpen-only filter: a shared green weight preserves hue, with
// local range limiting and a small noise gate. Work in approximately linear
// light (gamma 2), then sharpen on the final display pixel grid.
struct ClarityParameters {
    float strength;
    float compare;
    float drawableWidth;
    float shadowLift;
};

fragment float4 compositor_fragment_clarity(VertexOut in [[stage_in]],
    texture2d<float> source [[texture(0)]],
    texture2d<float> original [[texture(1)]],
    constant ClarityParameters &params [[buffer(0)]]) {
    constexpr sampler filter(mag_filter::linear, min_filter::linear, address::clamp_to_edge);
    // Derivatives must be evaluated before the comparison branch. Both halves
    // use identical UVs, including when full screen crops the image.
    float2 dx = dfdx(in.uv), dy = dfdy(in.uv);
    if (params.compare > 0.5 && in.position.x < params.drawableWidth * 0.5) {
        return float4(original.sample(filter, in.uv).rgb, 1.0);
    }
    float3 encoded = source.sample(filter, in.uv).rgb;
    if (params.strength <= 0.0) { return float4(lift_shadows(encoded, params.shadowLift), 1.0); }
    float3 e = encoded * encoded;
    float3 b = source.sample(filter, in.uv - dy).rgb; b *= b;
    float3 d = source.sample(filter, in.uv - dx).rgb; d *= d;
    float3 f = source.sample(filter, in.uv + dx).rgb; f *= f;
    float3 h = source.sample(filter, in.uv + dy).rgb; h *= h;
    float3 lo = min(min(min(b, d), min(f, h)), e);
    float3 hi = max(max(max(b, d), max(f, h)), e);
    float amplitude = sqrt(saturate(min(lo.g, 1.0 - hi.g) / max(hi.g, 0.00001)));
    float contrast = max(max(hi.r - lo.r, hi.g - lo.g), hi.b - lo.b);
    float strength = saturate(params.strength);
    float w = -amplitude / mix(8.0, 5.0, strength);
    w *= strength * smoothstep(0.002, 0.015, contrast);
    float3 result = (e + (b + d + f + h) * w) / (1.0 + 4.0 * w);
    // Do not invent brighter/darker outlines beyond this local neighborhood.
    return float4(lift_shadows(sqrt(clamp(result, lo, hi)), params.shadowLift), 1.0);
}
