#include <metal_stdlib>
using namespace metal;

static float deckHash(float n) {
    return fract(sin(n * 127.1f + 19.7f) * 43758.5453f);
}

static float deckBox(float2 p, float2 halfSize) {
    float2 q = abs(p) - halfSize;
    return length(max(q, 0.0f)) + min(max(q.x, q.y), 0.0f);
}

static float4 deckLight(float distance, float3 tint, float energy, float bloom) {
    float core = 1.0f - smoothstep(-0.25f, 0.65f, distance);
    float outside = max(distance, 0.0f);
    return float4(tint, 1) * energy * (core + exp(-outside * outside * 0.09f) * bloom);
}

// A stylized waveform with two luminous lobes. Its smoothly changing envelope
// is decorative ambience, never sampled audio, model tokens, or task progress.
static float deckEnvelope(float x, float time) {
    float a = (x - (0.24f + 0.035f * sin(time * 0.8f))) / 0.10f;
    float b = (x - (0.73f + 0.025f * cos(time * 0.65f))) / 0.085f;
    return exp(-a * a) * (0.76f + 0.20f * sin(time * 1.4f))
         + exp(-b * b) * (0.78f + 0.18f * cos(time * 1.1f));
}

/// SwiftUI shape fill; all coordinates are points. The host pauses time when
/// invisible, inactive, or Reduce Motion is enabled. No GPU feedback
/// loop or random per-frame regeneration is needed to maintain the light field.
[[ stitchable ]] half4 agentCyberdeck(float2 position, float2 size, float time,
                                     float energy, float highContrast, float lightAppearance) {
    float2 uv = position / max(size, float2(1));
    // Transparent light must also be legible on a light inspector. Use inkier
    // cyan/amber there, retaining luminous highlights in the dark appearance.
    float3 cyan = mix(float3(0.10f, 0.78f, 0.98f), float3(0.0f, 0.42f, 0.56f), lightAppearance);
    float3 ice = mix(float3(0.65f, 0.95f, 1.0f), float3(0.05f, 0.32f, 0.40f), lightAppearance);
    float3 amber = mix(float3(1.0f, 0.64f, 0.25f), float3(0.68f, 0.31f, 0.05f), lightAppearance);
    float3 warmCore = mix(float3(1, 0.94f, 0.78f), float3(0.52f, 0.23f, 0.03f), lightAppearance);
    float4 color = float4(0);
    float bloom = mix(0.65f, 0.18f, highContrast);
    float fieldWidth = max(size.x - 24, 1.0f);
    float baseline = size.y * 0.62f;
    float nx = position.x / fieldWidth;
    float fieldMask = 1 - smoothstep(fieldWidth - 8, fieldWidth + 3, position.x);
    float tintMix = smoothstep(0.48f, 0.83f, nx);
    float3 tint = mix(cyan, amber, tintMix);

    // Faint haze behind the central signal gives bloom room to breathe.
    float fogY = (position.y - baseline) / 22;
    float fogX = (nx - 0.46f) / 0.60f;
    color += float4(tint, 1) * exp(-fogY * fogY - fogX * fogX) * 0.052f * fieldMask;

    // Drifting, deterministic dust: tiny squares at different depths, with a
    // few larger hollow fragments. No flashes, invented text, or fake metrics.
    for (int depth = 0; depth < 2; ++depth) {
        float pitch = depth == 0 ? 13.0f : 29.0f;
        float2 flow = float2(time * (depth == 0 ? 3.0f : -4.0f), time * 0.7f);
        float2 cell = floor((position + flow) / pitch);
        float seed = cell.x + cell.y * 83 + float(depth) * 317;
        float hash = deckHash(seed);
        float2 local = fract((position + flow) / pitch) * pitch;
        float2 center = float2(0.24f + deckHash(seed + 3) * 0.52f,
                               0.24f + deckHash(seed + 9) * 0.52f) * pitch;
        float visibility = smoothstep(0.50f, 0.98f, hash);
        float radius = depth == 0 ? 0.35f : (hash > 0.92f ? 1.5f : 0.55f);
        float d = deckBox(local - center, float2(radius));
        if (depth == 1 && hash > 0.92f) d = abs(d) - 0.3f;
        float3 dustTint = hash > 0.85f ? amber : cyan;
        color += deckLight(d, dustTint, visibility * (depth == 0 ? 0.12f : 0.32f), bloom * 0.30f);
    }

    if (fieldMask > 0) {
        // Hairline filaments converge into the bars, like optical data streams.
        for (int strand = 0; strand < 5; ++strand) {
            float spread = (float(strand) - 2) * 4;
            float entrance = exp(-max(nx, 0.0f) * 10);
            float ripple = sin(nx * 13 - time * 0.75f + float(strand) * 0.7f);
            float y = baseline + spread * entrance * 2.2f
                    + ripple * (2 + 5 * pow(sin(nx * 3.14159f), 2.0f));
            float d = abs(position.y - y);
            float light = exp(-d * d * 2) * 0.24f + exp(-d * d * 0.10f) * 0.028f;
            color += float4(mix(tint, ice, 0.25f), 1) * light * fieldMask * energy;
        }

        // Neighbor bars contribute their own halos, so the glow is spatially
        // integrated instead of looking like a flat colored stroke.
        const float pitch = 5.5f;
        float bar = floor(position.x / pitch);
        for (int neighbour = -2; neighbour <= 2; ++neighbour) {
            float x = (bar + float(neighbour) + 0.5f) * pitch;
            float fraction = x / fieldWidth;
            if (fraction < 0.07f || fraction > 0.97f) continue;
            float envelope = deckEnvelope(fraction, time);
            float halfHeight = 0.7f + envelope * size.y * 0.18f;
            float taper = smoothstep(0.07f, 0.15f, fraction)
                        * (1 - smoothstep(0.87f, 0.97f, fraction));
            float distance = deckBox(position - float2(x, baseline), float2(0.65f, halfHeight));
            float3 barTint = mix(cyan, amber, smoothstep(0.50f, 0.79f, fraction));
            color += deckLight(distance, barTint, energy * taper * 0.72f, bloom);
            // A thin pale core creates the photographic neon appearance.
            color += deckLight(distance + 0.35f, mix(ice, warmCore,
                               smoothstep(0.5f, 0.8f, fraction)),
                               energy * taper * envelope * 0.50f, bloom * 0.10f);
        }
    }

    // Retain the cyan terminal marker, reclaiming the former mascot space for
    // the waveform while keeping a little breathing room at the trailing edge.
    float dividerX = size.x - 14;
    float dividerY = abs(position.y - size.y * 0.62f);
    float divider = exp(-pow(position.x - dividerX, 2) * 2)
                  * (1 - smoothstep(size.y * 0.23f, size.y * 0.31f, dividerY));
    color += float4(cyan, 1) * divider * 0.26f;
    // Texture attenuates the signal itself; empty pixels have zero coverage.
    // Completed frames retain their composition over the inspector background.
    color *= 0.975f + 0.025f * sin(position.y * 3.14159f);
    float edge = smoothstep(0.0f, 0.055f, uv.x) * smoothstep(0.0f, 0.055f, 1 - uv.x);
    color *= mix(0.6f, 1.0f, edge);
    // SwiftUI requires premultiplied RGBA. Accumulate coverage independently of
    // hue, then normalize overlaps to preserve saturated cores without an
    // opaque dark plate or black fringes around the transparent bloom.
    float alpha = saturate(color.a);
    float3 rgb = color.rgb / max(color.a, 0.00001f);
    return half4(half3(saturate(rgb) * alpha), half(alpha));
}
