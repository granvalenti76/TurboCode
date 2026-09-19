#include <metal_stdlib>
using namespace metal;

static float routingBox(float2 point, float2 halfSize) {
    float2 offset = abs(point) - halfSize;
    return length(max(offset, 0.0f)) + min(max(offset.x, offset.y), 0.0f);
}

static float routingSmoothstep(float edge0, float edge1, float value) {
    float x = saturate((value - edge0) / max(edge1 - edge0, 0.0001f));
    return x * x * (3.0f - 2.0f * x);
}

static float2 routingBezier(float2 start, float2 control, float2 end, float progress) {
    float inverse = 1.0f - progress;
    return inverse * inverse * start
         + 2.0f * inverse * progress * control
         + progress * progress * end;
}

static void routingAddLight(thread float4 &color, float strength, float3 tint) {
    color.rgb += tint * strength;
    color.a += strength;
}

/// Continuous visual field behind the AnchorSignal routing procedure. SwiftUI
/// supplies real package labels; this shader draws only scan light, trajectories,
/// payload echoes, and system-prompt impact. Output stays transparent so light
/// and dark application appearances retain their native inspector background.
[[ stitchable ]] half4 anchorSignalRouting(float2 position, float2 size,
                                           float time, float scanProgress,
                                           float routeProgress, float coreY,
                                           float lightAppearance,
                                           float highContrast) {
    float2 safeSize = max(size, float2(1));
    float2 uv = position / safeSize;
    float4 color = float4(0);

    float3 cyan = mix(float3(0.10f, 0.88f, 1.0f),
                      float3(0.00f, 0.34f, 0.46f), lightAppearance);
    float3 violet = mix(float3(0.68f, 0.42f, 1.0f),
                        float3(0.38f, 0.16f, 0.62f), lightAppearance);
    float3 orange = mix(float3(1.0f, 0.56f, 0.16f),
                        float3(0.72f, 0.27f, 0.02f), lightAppearance);
    float3 green = mix(float3(0.22f, 1.0f, 0.58f),
                       float3(0.02f, 0.46f, 0.22f), lightAppearance);
    float contrastScale = mix(1.0f, 1.35f, highContrast);

    // A restrained moving grid ties the full inspector into one surface.
    float gridPitch = 24.0f;
    float gx = abs(fract((position.x + time * 3.0f) / gridPitch) - 0.5f) * gridPitch;
    float gy = abs(fract(position.y / gridPitch) - 0.5f) * gridPitch;
    float grid = 1.0f - smoothstep(0.32f, 0.82f, min(gx, gy));
    float edgeFade = smoothstep(0.0f, 0.08f, uv.x)
                   * smoothstep(0.0f, 0.08f, 1.0f - uv.x);
    routingAddLight(color, grid * 0.018f * edgeFade, mix(cyan, violet, uv.y));

    // The scanner is a GPU light sheet rather than a SwiftUI rectangle. It
    // traverses both ways because scanProgress is a ping-pong phase from Swift.
    float scanX = mix(0.055f, 0.945f, scanProgress);
    float scanDistance = abs(uv.x - scanX) * safeSize.x;
    float promptMask = smoothstep(0.055f, 0.085f, uv.y)
                     * (1.0f - smoothstep(0.235f, 0.275f, uv.y));
    float scanCore = exp(-scanDistance * scanDistance * 0.75f) * promptMask;
    float scanBloom = exp(-scanDistance * scanDistance * 0.012f) * promptMask;
    float scanVisibility = 1.0f - routingSmoothstep(0.0f, 0.18f, routeProgress);
    routingAddLight(color, scanCore * 0.72f * scanVisibility, cyan);
    routingAddLight(color, scanBloom * 0.11f * scanVisibility, violet);

    // One flowing optical route replaces discrete connector segments. The path
    // bends gently while pulses move continuously toward the prompt dock.
    float routeStartY = 0.31f;
    float routeEndY = max(routeStartY + 0.08f, coreY - 0.105f);
    float routeMask = smoothstep(routeStartY, routeStartY + 0.035f, uv.y)
                    * (1.0f - smoothstep(routeEndY - 0.025f, routeEndY, uv.y));
    float routeUnit = saturate((uv.y - routeStartY) / max(routeEndY - routeStartY, 0.01f));
    float routeX = 0.5f + sin(routeUnit * 3.14159f) * 0.055f;
    float routeDistance = abs(uv.x - routeX) * safeSize.x;
    float routeReveal = routingSmoothstep(0.02f, 0.22f, routeProgress);
    float routeRetire = 1.0f - routingSmoothstep(0.88f, 1.0f, routeProgress);
    float filament = exp(-routeDistance * routeDistance * 0.42f) * routeMask;
    float trail = exp(-routeDistance * routeDistance * 0.025f) * routeMask;
    routingAddLight(color, filament * 0.33f * routeReveal * routeRetire, orange);
    routingAddLight(color, trail * 0.045f * routeReveal * routeRetire, cyan);

    float pulsePhase = fract(routeUnit * 3.2f - time * 0.85f);
    float pulse = exp(-pow((pulsePhase - 0.5f) * 11.0f, 2.0f));
    routingAddLight(color, pulse * filament * 0.78f * routeReveal * routeRetire, orange);

    // Payload echoes follow quadratic curves matching the readable SwiftUI
    // package cards. Metal bloom makes their movement feel continuous at 60 fps.
    const float starts[8] = {-0.28f, -0.19f, -0.10f, 0.10f, 0.19f, 0.28f, 0.0f, 0.0f};
    for (int index = 0; index < 8; ++index) {
        float begin = 0.18f + float(index) * 0.035f;
        float local = routingSmoothstep(begin, min(0.82f, begin + 0.48f), routeProgress);
        if (routeProgress < begin || local >= 0.995f) continue;

        float2 start = float2(0.5f + starts[index], 0.36f + float(index % 2) * 0.022f);
        float2 control = float2(0.5f + (index % 2 == 0 ? -0.12f : 0.12f),
                                mix(start.y, routeEndY, 0.48f));
        float2 end = float2(0.5f + float((index % 5) - 2) * 0.035f, routeEndY);
        float2 packet = routingBezier(start, control, end, local);
        float2 delta = (uv - packet) * safeSize;
        float box = routingBox(delta, float2(13.0f, 5.0f));
        float core = 1.0f - smoothstep(-0.4f, 0.8f, box);
        float bloom = exp(-max(box, 0.0f) * max(box, 0.0f) * 0.035f);
        routingAddLight(color, core * 0.22f + bloom * 0.055f, orange);
    }

    // A single expanding impact around the system prompt closes the procedure.
    float completion = routingSmoothstep(0.84f, 0.93f, routeProgress);
    float impactLifetime = completion
                         * (1.0f - routingSmoothstep(0.94f, 1.0f, routeProgress));
    float2 impactDelta = float2((uv.x - 0.5f) * safeSize.x,
                                (uv.y - (coreY - 0.105f)) * safeSize.y);
    float impactRadius = length(impactDelta);
    float ringRadius = mix(8.0f, min(safeSize.x * 0.42f, 150.0f), completion);
    float ring = exp(-pow((impactRadius - ringRadius) * 0.16f, 2.0f));
    routingAddLight(color, ring * 0.18f * impactLifetime, green);

    color *= contrastScale;
    float alpha = saturate(color.a);
    float3 straightRGB = color.rgb / max(color.a, 0.00001f);
    return half4(half3(saturate(straightRGB) * alpha), half(alpha));
}
