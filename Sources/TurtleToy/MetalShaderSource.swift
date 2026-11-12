import Foundation

public enum MetalShaderSource {
    public static let source = #"""
    #include <metal_stdlib>
    using namespace metal;

    // MARK: - Shared Uniforms & GPU Structs

    struct FrameUniforms {
        float2 viewportSize;
        float2 cameraPan;
        float cameraZoom;
        float time;
        uint backdropKind;
        uint showGrid;
        float bloomIntensity;
        float partialStepFraction; // 0..1 fraction of the last visible step
        uint activeStepIndex;      // step index currently being animated
        uint isAnimatingStep;      // 1 if partial interpolation is active
        float4 rippleData[4];      // xy = worldPos, z = age, w = maxRadius
    };

    struct StrokeInstanceGPU {
        float2 start;
        float2 end;
        float4 colorStart;
        float4 colorEnd;
        float widthStart;
        float widthEnd;
        float glow;
        uint brushKind;
        float cumulativeDistStart;
        float cumulativeDistEnd;
        float seed;
        uint stepIndex;
    };

    struct FillVertexGPU {
        float2 position;
        float4 color;
        float glow;
        uint stepIndex;
    };

    struct ParticleGPU {
        float2 position;
        float2 velocity;
        float4 color;
        float size;
        float age;
        float lifetime;
        uint kind;
    };

    struct TurtleAvatarUniforms {
        float2 position;
        float headingRadians;
        float scale;
        float4 penColor;
        uint penDown;
        uint brushKind;
        float time;
        float pad;
    };

    // MARK: - Procedural Noise & Math Helpers

    static inline float hash21(float2 p) {
        p = fract(p * float2(123.34, 456.21));
        p += dot(p, p + 45.32);
        return fract(p.x * p.y);
    }

    static inline float noise2D(float2 p) {
        float2 i = floor(p);
        float2 f = fract(p);
        float2 u = f * f * (3.0 - 2.0 * f);
        float a = hash21(i);
        float b = hash21(i + float2(1.0, 0.0));
        float c = hash21(i + float2(0.0, 1.0));
        float d = hash21(i + float2(1.0, 1.0));
        return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
    }

    static inline float fbm(float2 p) {
        float v = 0.0;
        float a = 0.5;
        float2x2 rot = float2x2(0.8, 0.6, -0.6, 0.8);
        for (int i = 0; i < 4; ++i) {
            v += a * noise2D(p);
            p = rot * p * 2.02 + float2(17.1, 31.7);
            a *= 0.5;
        }
        return v;
    }

    static inline float3 hsl2rgb(float3 c) {
        float3 rgb = clamp(abs(fmod(c.x * 6.0 + float3(0.0, 4.0, 2.0), 6.0) - 3.0) - 1.0, 0.0, 1.0);
        return c.z + c.y * (rgb - 0.5) * (1.0 - abs(2.0 * c.z - 1.0));
    }

    static inline float2 worldToNDC(float2 worldPos, constant FrameUniforms &u) {
        float2 viewPos = (worldPos + u.cameraPan) * u.cameraZoom;
        return viewPos / (u.viewportSize * 0.5);
    }

    static inline float2 ndcToWorld(float2 ndc, constant FrameUniforms &u) {
        float2 viewPos = ndc * (u.viewportSize * 0.5);
        return (viewPos / max(u.cameraZoom, 0.001)) - u.cameraPan;
    }

    // MARK: - 1. Fullscreen Backdrop & Grid Shader

    struct FullscreenOut {
        float4 position [[position]];
        float2 uv;
        float2 ndc;
    };

    vertex FullscreenOut fullscreen_vertex(uint vid [[vertex_id]]) {
        float2 pos[3] = {
            float2(-1.0, -1.0),
            float2( 3.0, -1.0),
            float2(-1.0,  3.0)
        };
        FullscreenOut out;
        out.position = float4(pos[vid], 0.0, 1.0);
        out.ndc = pos[vid];
        out.uv = pos[vid] * 0.5 + 0.5;
        out.uv.y = 1.0 - out.uv.y;
        return out;
    }

    fragment float4 backdrop_fragment(
        FullscreenOut in [[stage_in]],
        constant FrameUniforms &u [[buffer(0)]]
    ) {
        float2 worldPos = ndcToWorld(in.ndc, u);
        float2 aspectNDC = in.ndc * float2(u.viewportSize.x / max(u.viewportSize.y, 1.0), 1.0);
        float r = length(aspectNDC);
        float3 col = float3(0.02, 0.025, 0.045);

        if (u.backdropKind == 0) {
            // Cosmic Void: deep space indigo + subtle twinkling starfield
            col = mix(float3(0.035, 0.04, 0.085), float3(0.01, 0.012, 0.028), clamp(r * 0.75, 0.0, 1.0));
            float2 starCell = floor(worldPos * 0.035);
            float2 starLocal = fract(worldPos * 0.035) - 0.5;
            float rnd = hash21(starCell);
            if (rnd > 0.93) {
                float d = length(starLocal);
                float twinkle = 0.55 + 0.45 * sin(u.time * (2.0 + rnd * 4.0) + rnd * 60.0);
                float star = smoothstep(0.16, 0.0, d) * twinkle * (rnd - 0.92) * 10.0;
                col += star * mix(float3(0.5, 0.85, 1.0), float3(1.0, 0.75, 0.9), fract(rnd * 13.7));
            }
        } else if (u.backdropKind == 1) {
            // Synthwave Grid: outrun horizon glow + perspective cyber grid
            float grad = clamp(in.ndc.y * 0.5 + 0.5, 0.0, 1.0);
            col = mix(float3(0.11, 0.02, 0.18), float3(0.02, 0.015, 0.06), grad);
            float2 gp = abs(fract(worldPos / 60.0 - 0.5) - 0.5) / fwidth(worldPos / 60.0);
            float line = min(gp.x, gp.y);
            float gridFactor = 1.0 - min(line, 1.0);
            col += gridFactor * float3(0.28, 0.05, 0.42) * 0.45;
            float horizonGlow = exp(-abs(worldPos.y) * 0.0035);
            col += horizonGlow * float3(0.18, 0.03, 0.25) * 0.5;
        } else if (u.backdropKind == 2) {
            // Warm Parchment: tactile watercolor paper grain
            float grain = fbm(worldPos * 0.025);
            float fine = noise2D(worldPos * 0.18);
            col = float3(0.95, 0.91, 0.83) - grain * 0.06 - fine * 0.025;
            col *= (1.0 - r * 0.12);
        } else if (u.backdropKind == 3) {
            // Bioluminescent Deep Ocean: caustic light rays & abyssal teal
            float n1 = fbm(worldPos * 0.004 + float2(u.time * 0.08, u.time * 0.05));
            float n2 = fbm(worldPos * 0.008 - float2(u.time * 0.06, -u.time * 0.04));
            float caustic = smoothstep(0.35, 0.85, n1 * n2 * 2.4);
            col = mix(float3(0.008, 0.045, 0.085), float3(0.02, 0.14, 0.22), n1);
            col += caustic * float3(0.04, 0.35, 0.42) * 0.45;
        } else if (u.backdropKind == 4) {
            // Aurora Nebula: swirling magenta/teal cosmic clouds
            float n1 = fbm(worldPos * 0.003 + float2(u.time * 0.03, 0.0));
            float n2 = fbm(worldPos * 0.005 + float2(n1 * 1.5, u.time * 0.02));
            col = float3(0.025, 0.018, 0.06);
            col += smoothstep(0.25, 0.85, n1) * float3(0.16, 0.03, 0.22);
            col += smoothstep(0.35, 0.9, n2) * float3(0.02, 0.18, 0.20);
        } else {
            // Architect Blueprint
            col = mix(float3(0.04, 0.12, 0.26), float3(0.02, 0.07, 0.17), clamp(r * 0.65, 0.0, 1.0));
            float2 sub = abs(fract(worldPos / 20.0 - 0.5) - 0.5) / fwidth(worldPos / 20.0);
            float subLine = 1.0 - min(min(sub.x, sub.y), 1.0);
            col += subLine * float3(0.08, 0.24, 0.45) * 0.28;
        }

        // Optional precision coordinate grid & axes
        if (u.showGrid != 0) {
            float gridStep = 50.0;
            float2 gridUV = worldPos / gridStep;
            float2 distToGrid = abs(fract(gridUV - 0.5) - 0.5) / fwidth(gridUV);
            float gridLine = 1.0 - min(min(distToGrid.x, distToGrid.y), 1.0);

            float2 axisDist = abs(worldPos) / fwidth(worldPos);
            float xAxis = 1.0 - min(axisDist.y, 1.0);
            float yAxis = 1.0 - min(axisDist.x, 1.0);

            bool isLight = (u.backdropKind == 2);
            float3 gridCol = isLight ? float3(0.35, 0.30, 0.25) : float3(0.30, 0.55, 0.85);
            col = mix(col, gridCol, gridLine * 0.16);
            col = mix(col, float3(0.95, 0.30, 0.45), xAxis * 0.45);
            col = mix(col, float3(0.25, 0.90, 0.55), yAxis * 0.45);
        }

        // Interactive & programmatic ripples
        for (int i = 0; i < 4; ++i) {
            float4 rp = u.rippleData[i];
            if (rp.w > 0.0 && rp.z >= 0.0 && rp.z < 1.0) {
                float d = length(worldPos - rp.xy);
                float curR = rp.z * rp.w;
                float ring = exp(-pow((d - curR) / max(6.0, rp.w * 0.06), 2.0));
                float fade = (1.0 - rp.z) * (1.0 - rp.z);
                col += ring * fade * float3(0.35, 0.95, 1.0) * 0.85;
            }
        }

        return float4(col, 1.0);
    }

    // MARK: - 2. Polygon Fill Shader

    struct FillOut {
        float4 position [[position]];
        float4 color;
        float glow;
        float2 worldPos;
    };

    vertex FillOut fill_vertex(
        uint vid [[vertex_id]],
        constant FillVertexGPU *vertices [[buffer(0)]],
        constant FrameUniforms &u [[buffer(1)]]
    ) {
        FillVertexGPU v = vertices[vid];
        FillOut out;
        out.position = float4(worldToNDC(v.position, u), 0.0, 1.0);
        out.color = v.color;
        out.glow = v.glow;
        out.worldPos = v.position;
        return out;
    }

    fragment float4 fill_fragment(
        FillOut in [[stage_in]],
        constant FrameUniforms &u [[buffer(0)]]
    ) {
        float n = fbm(in.worldPos * 0.035);
        float3 hdrColor = in.color.rgb * (1.0 + in.glow * 0.55) * (0.92 + 0.16 * n);
        return float4(hdrColor, in.color.a);
    }

    // MARK: - 3. Instanced SDF Capsule Stroke Shader (8 Procedural Brushes)

    struct StrokeOut {
        float4 position [[position]];
        float2 localPos;    // x along segment [0..len], y perpendicular [-halfExtent..+halfExtent]
        float2 worldPos;
        float segmentLen;
        float widthStart;
        float widthEnd;
        float4 colorStart;
        float4 colorEnd;
        float glow;
        uint brushKind;
        float distStart;
        float distEnd;
        float seed;
        float headingAngle;
    };

    vertex StrokeOut stroke_vertex(
        uint vid [[vertex_id]],
        uint iid [[instance_id]],
        constant StrokeInstanceGPU *strokes [[buffer(0)]],
        constant FrameUniforms &u [[buffer(1)]]
    ) {
        StrokeInstanceGPU s = strokes[iid];

        float2 p0 = s.start;
        float2 p1 = s.end;
        float wEnd = s.widthEnd;
        float dEnd = s.cumulativeDistEnd;

        // Smooth sub-step interpolation when scrubbing or animating the active step!
        if (u.isAnimatingStep != 0 && s.stepIndex == u.activeStepIndex) {
            float t = clamp(u.partialStepFraction, 0.0, 1.0);
            p1 = mix(s.start, s.end, t);
            wEnd = mix(s.widthStart, s.widthEnd, t);
            dEnd = mix(s.cumulativeDistStart, s.cumulativeDistEnd, t);
        }

        float2 delta = p1 - p0;
        float segLen = length(delta);
        float2 dir = (segLen > 0.0001) ? (delta / segLen) : float2(1.0, 0.0);
        float2 normal = float2(-dir.y, dir.x);

        float maxRadius = max(s.widthStart, wEnd) * 0.5;
        // Expand quad generously for glow halos, watercolor bleed, and electric arcs
        float padMultiplier = (s.brushKind == 5) ? 3.6 : ((s.brushKind == 2) ? 2.4 : 2.1);
        float pad = max(maxRadius * padMultiplier, 4.0 / max(u.cameraZoom, 0.1));

        // 6 vertices forming a quad around the capsule from -pad to segLen + pad
        float2 quadCorners[6] = {
            float2(-pad,          -pad),
            float2(segLen + pad,  -pad),
            float2(-pad,           pad),
            float2(-pad,           pad),
            float2(segLen + pad,  -pad),
            float2(segLen + pad,   pad)
        };

        float2 local = quadCorners[vid];
        float2 world = p0 + dir * local.x + normal * local.y;

        StrokeOut out;
        out.position = float4(worldToNDC(world, u), 0.0, 1.0);
        out.localPos = local;
        out.worldPos = world;
        out.segmentLen = segLen;
        out.widthStart = s.widthStart;
        out.widthEnd = wEnd;
        out.colorStart = s.colorStart;
        out.colorEnd = s.colorEnd;
        out.glow = s.glow;
        out.brushKind = s.brushKind;
        out.distStart = s.cumulativeDistStart;
        out.distEnd = dEnd;
        out.seed = s.seed;
        out.headingAngle = atan2(dir.y, dir.x);
        return out;
    }

    fragment float4 stroke_fragment(
        StrokeOut in [[stage_in]],
        constant FrameUniforms &u [[buffer(0)]]
    ) {
        float clampedX = clamp(in.localPos.x, 0.0, max(in.segmentLen, 0.0001));
        float tAlong = (in.segmentLen > 0.0001) ? clamp(in.localPos.x / in.segmentLen, 0.0, 1.0) : 0.0;

        float radius = mix(in.widthStart, in.widthEnd, tAlong) * 0.5;
        float4 baseCol = mix(in.colorStart, in.colorEnd, tAlong);
        float pathDist = mix(in.distStart, in.distEnd, tAlong);

        float2 closestPt = float2(clampedX, 0.0);
        float distToAxis = length(in.localPos - closestPt);
        float aa = max(fwidth(distToAxis), 0.65 / max(u.cameraZoom, 0.25));

        float3 finalRGB = baseCol.rgb;
        float finalAlpha = 0.0;
        float hdrBoost = 1.0 + in.glow * 0.95;

        if (in.brushKind == 0) {
            // 0: NEON PLASMA — intense white-hot inner core + saturated HDR outer aura
            float coreSDF = distToAxis - radius * 0.62;
            float coreMask = 1.0 - smoothstep(-aa, aa, coreSDF);
            float haloMask = exp(-max(distToAxis - radius * 0.25, 0.0) / max(radius * 0.72, 0.8));
            finalRGB = mix(baseCol.rgb * hdrBoost, float3(1.0, 1.0, 1.0) * (hdrBoost * 1.15), coreMask * 0.58);
            finalAlpha = clamp(coreMask + haloMask * 0.75, 0.0, 1.0) * baseCol.a;
        } else if (in.brushKind == 1) {
            // 1: COHERENT LASER — razor-sharp core + subtle chromatic edge fringe
            float sdf = distToAxis - radius * 0.75;
            float body = 1.0 - smoothstep(-aa * 0.8, aa * 0.8, sdf);
            float hotLine = 1.0 - smoothstep(0.0, max(aa * 1.2, radius * 0.35), distToAxis);
            float fringe = exp(-abs(sdf) / max(radius * 0.35, 0.6));
            finalRGB = baseCol.rgb * (hdrBoost * 1.2) + float3(0.95, 0.98, 1.0) * hotLine * 1.3;
            finalRGB += float3(0.2, 0.5, 1.0) * fringe * 0.35;
            finalAlpha = clamp(body + fringe * 0.45, 0.0, 1.0) * baseCol.a;
        } else if (in.brushKind == 2) {
            // 2: WATERCOLOR BLEED — organic FBM paper-edge deckle + pigment edge pooling
            float n = fbm(in.worldPos * 0.09 + float2(in.seed * 11.3, in.seed * 7.1));
            float2 paperGrain = float2(noise2D(in.worldPos * 0.25), noise2D(in.worldPos * 0.55));
            float warpedRadius = radius * (0.85 + 0.42 * n);
            float sdf = distToAxis - warpedRadius;
            float body = 1.0 - smoothstep(-aa * 2.2, aa * 2.2, sdf);
            // Watercolor coffee-ring effect: pigment concentrates near the outer boundary
            float edgeRing = smoothstep(warpedRadius * 0.25, warpedRadius * 0.95, distToAxis) * body;
            finalRGB = baseCol.rgb * (0.88 + 0.22 * paperGrain.x - 0.18 * edgeRing);
            finalRGB *= (1.0 + in.glow * 0.25);
            finalAlpha = body * (0.52 + 0.38 * edgeRing + 0.12 * paperGrain.y) * baseCol.a;
        } else if (in.brushKind == 3) {
            // 3: CALLIGRAPHY INK — nib angle modulates stroke thickness + brush bristle texture
            float nibAngle = 0.65; // ~37 degree chisel nib
            float angleFactor = 0.32 + 0.68 * abs(sin(in.headingAngle - nibAngle));
            float nibRadius = radius * angleFactor;
            float bristle = noise2D(float2(pathDist * 0.12, in.localPos.y * 1.8));
            float sdf = distToAxis - nibRadius;
            float body = 1.0 - smoothstep(-aa, aa, sdf);
            finalRGB = baseCol.rgb * (1.0 + in.glow * 0.55) * (0.90 + 0.15 * bristle);
            finalAlpha = body * baseCol.a;
        } else if (in.brushKind == 4) {
            // 4: RAINBOW PRISM — continuous spectral shift along cumulative path + cross-section dispersion
            float hue = fract(pathDist * 0.0018 - u.time * 0.15 + (in.localPos.y / max(radius * 2.0, 1.0)) * 0.15);
            float3 prismRGB = hsl2rgb(float3(hue, 0.92, 0.58));
            float sdf = distToAxis - radius * 0.85;
            float body = 1.0 - smoothstep(-aa, aa, sdf);
            float halo = exp(-max(distToAxis - radius * 0.4, 0.0) / max(radius * 0.65, 0.8));
            finalRGB = mix(prismRGB * hdrBoost, float3(1.0), body * 0.32);
            finalAlpha = clamp(body + halo * 0.65, 0.0, 1.0) * baseCol.a;
        } else if (in.brushKind == 5) {
            // 5: ELECTRIC ARC — animated multi-strand high-voltage lightning between segment endpoints
            float endPinch = sin(tAlong * 3.14159265);
            float wave1 = (noise2D(float2(pathDist * 0.08 + u.time * 16.0, in.seed * 19.0)) - 0.5) * 2.0;
            float wave2 = (noise2D(float2(pathDist * 0.22 - u.time * 24.0, in.seed * 37.0 + 4.2)) - 0.5) * 2.0;
            float offset1 = (wave1 * 0.85 + wave2 * 0.45) * radius * 1.45 * endPinch;
            float offset2 = (-wave1 * 0.55 + wave2 * 0.75) * radius * 1.15 * endPinch;

            float d1 = length(float2(in.localPos.x - clampedX, in.localPos.y - offset1));
            float d2 = length(float2(in.localPos.x - clampedX, in.localPos.y - offset2));

            float bolt1 = 1.0 - smoothstep(0.0, max(aa * 1.4, radius * 0.38), d1);
            float bolt2 = (1.0 - smoothstep(0.0, max(aa * 1.2, radius * 0.26), d2)) * 0.75;
            float aura = exp(-min(d1, d2) / max(radius * 0.85, 1.0));

            finalRGB = mix(baseCol.rgb * (hdrBoost * 1.35), float3(0.92, 0.98, 1.0) * (hdrBoost * 1.6), clamp(bolt1 + bolt2, 0.0, 1.0));
            finalAlpha = clamp(bolt1 + bolt2 + aura * 0.68, 0.0, 1.0) * baseCol.a;
        } else if (in.brushKind == 6) {
            // 6: STARDUST TRAIL — glowing constellation beads + 4-point star glints
            float sdf = distToAxis - radius;
            float softTrail = exp(-distToAxis / max(radius * 0.7, 0.8)) * 0.45;
            float cell = floor(pathDist / max(radius * 1.6, 4.0));
            float cellPhase = fract(pathDist / max(radius * 1.6, 4.0)) - 0.5;
            float2 starPos = float2(cellPhase * max(radius * 1.6, 4.0), in.localPos.y);
            float starDist = length(starPos);
            float cross = exp(-abs(starPos.x) / max(radius * 0.16, 0.4)) * exp(-abs(starPos.y) / max(radius * 0.7, 1.0))
                        + exp(-abs(starPos.y) / max(radius * 0.16, 0.4)) * exp(-abs(starPos.x) / max(radius * 0.7, 1.0));
            float twinkle = 0.65 + 0.35 * sin(u.time * 6.0 + cell * 2.7 + in.seed * 10.0);
            float sparkleMask = clamp((1.0 - smoothstep(0.0, radius * 0.55, starDist)) + cross * 0.75, 0.0, 1.0) * twinkle;
            float endCap = 1.0 - smoothstep(-aa, aa, sdf);
            finalRGB = mix(baseCol.rgb * hdrBoost, float3(1.0, 0.98, 0.9) * (hdrBoost * 1.3), sparkleMask * 0.65);
            finalAlpha = clamp((softTrail + sparkleMask * 0.95) * endCap, 0.0, 1.0) * baseCol.a;
        } else {
            // 7: SATIN RIBBON — 3D cylindrical normal shading + iridescent edge rim
            float sdf = distToAxis - radius;
            float body = 1.0 - smoothstep(-aa, aa, sdf);
            float normY = clamp(in.localPos.y / max(radius, 0.001), -1.0, 1.0);
            float z = sqrt(max(0.0, 1.0 - normY * normY));
            float spec = pow(max(0.0, z), 5.0);
            float rim = pow(1.0 - z, 2.2);
            float waveStripe = 0.5 + 0.5 * sin(pathDist * 0.12 - normY * 3.0);
            finalRGB = baseCol.rgb * (0.65 + 0.55 * z + 0.15 * waveStripe) * hdrBoost
                     + float3(1.0) * spec * 0.55
                     + baseCol.bgr * rim * 0.55;
            finalAlpha = body * baseCol.a;
        }

        if (finalAlpha < 0.002) {
            discard_fragment();
        }
        return float4(finalRGB, finalAlpha);
    }

    // MARK: - 4. Instanced GPU Particle Shader

    struct ParticleOut {
        float4 position [[position]];
        float2 uv; // [-1..1]
        float4 color;
        float progress;
        uint kind;
    };

    vertex ParticleOut particle_vertex(
        uint vid [[vertex_id]],
        uint iid [[instance_id]],
        constant ParticleGPU *particles [[buffer(0)]],
        constant FrameUniforms &u [[buffer(1)]]
    ) {
        ParticleGPU p = particles[iid];
        float2 corners[6] = {
            float2(-1.0, -1.0), float2( 1.0, -1.0), float2(-1.0,  1.0),
            float2(-1.0,  1.0), float2( 1.0, -1.0), float2( 1.0,  1.0)
        };
        float2 c = corners[vid];
        float progress = clamp(p.age / max(p.lifetime, 0.001), 0.0, 1.0);
        float scale = p.size * (1.0 - progress * 0.65);
        float2 world = p.position + c * scale;

        ParticleOut out;
        out.position = float4(worldToNDC(world, u), 0.0, 1.0);
        out.uv = c;
        out.color = p.color;
        out.progress = progress;
        out.kind = p.kind;
        return out;
    }

    fragment float4 particle_fragment(ParticleOut in [[stage_in]]) {
        float r = length(in.uv);
        if (r > 1.0) { discard_fragment(); }
        float fade = (1.0 - in.progress) * (1.0 - in.progress);
        float mask = 0.0;
        if (in.kind == 1) {
            // 4-point star sparkle
            float cross = exp(-abs(in.uv.x) * 4.5) * exp(-abs(in.uv.y) * 1.2)
                        + exp(-abs(in.uv.y) * 4.5) * exp(-abs(in.uv.x) * 1.2);
            mask = clamp(exp(-r * 3.0) + cross * 0.85, 0.0, 1.0);
        } else {
            // Glowing ember / spark
            mask = exp(-r * r * 3.5);
        }
        float3 hdr = mix(in.color.rgb * 2.2, float3(1.0, 1.0, 1.0) * 2.4, exp(-r * 4.0) * 0.6);
        return float4(hdr, mask * fade * in.color.a);
    }

    // MARK: - 5. Procedural SDF Cyber-Turtle Avatar Shader

    struct AvatarOut {
        float4 position [[position]];
        float2 local; // [-1.5 .. 1.5] in turtle local space (+X forward, +Y left)
        float4 penColor;
        uint penDown;
        float time;
    };

    static inline float sdEllipse(float2 p, float2 r) {
        float k0 = length(p / r);
        float k1 = length(p / (r * r));
        return k0 * (k0 - 1.0) / max(k1, 0.0001);
    }

    static inline float sdSegment(float2 p, float2 a, float2 b, float r) {
        float2 pa = p - a, ba = b - a;
        float h = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
        return length(pa - ba * h) - r;
    }

    vertex AvatarOut turtle_avatar_vertex(
        uint vid [[vertex_id]],
        constant TurtleAvatarUniforms &tu [[buffer(0)]],
        constant FrameUniforms &u [[buffer(1)]]
    ) {
        float2 corners[6] = {
            float2(-1.6, -1.6), float2( 1.6, -1.6), float2(-1.6,  1.6),
            float2(-1.6,  1.6), float2( 1.6, -1.6), float2( 1.6,  1.6)
        };
        float2 local = corners[vid];
        // Keep turtle a comfortable screen size regardless of extreme zoom, with subtle zoom scaling
        float worldRadius = (18.0 / max(u.cameraZoom, 0.15)) * clamp(pow(u.cameraZoom, 0.25), 0.75, 1.45) * tu.scale;

        float cosA = cos(tu.headingRadians);
        float sinA = sin(tu.headingRadians);
        float2 rotated = float2(local.x * cosA - local.y * sinA, local.x * sinA + local.y * cosA);
        float2 world = tu.position + rotated * worldRadius;

        AvatarOut out;
        out.position = float4(worldToNDC(world, u), 0.0, 1.0);
        out.local = local;
        out.penColor = tu.penColor;
        out.penDown = tu.penDown;
        out.time = tu.time;
        return out;
    }

    fragment float4 turtle_avatar_fragment(AvatarOut in [[stage_in]]) {
        float2 p = in.local;
        float2 symP = float2(p.x, abs(p.y)); // Mirror symmetry across turtle spine

        // Subtle paddling animation for flippers
        float paddle = sin(in.time * 8.0) * 0.06;

        // Head (+X is forward)
        float dHead = length(p - float2(0.82, 0.0)) - 0.26;
        // Front flippers
        float dFrontFlipper = sdSegment(symP, float2(0.28, 0.35), float2(0.55 + paddle, 0.86), 0.14);
        // Back flippers
        float dBackFlipper = sdSegment(symP, float2(-0.42, 0.32), float2(-0.72 - paddle, 0.70), 0.12);
        // Cute tail
        float dTail = sdSegment(p, float2(-0.65, 0.0), float2(-0.92, sin(in.time * 6.0) * 0.06), 0.07);
        // Shell oval
        float dShell = sdEllipse(p - float2(-0.04, 0.0), float2(0.68, 0.56));

        float dLimbs = min(min(dHead, dFrontFlipper), min(dBackFlipper, dTail));
        float dBody = min(dLimbs, dShell);

        float aa = fwidth(dBody);
        float bodyMask = 1.0 - smoothstep(-aa, aa, dBody);
        float shellMask = 1.0 - smoothstep(-aa, aa, dShell);

        // Glowing eyes on head
        float dEyes = length(symP - float2(0.92, 0.12)) - 0.055;
        float eyeMask = 1.0 - smoothstep(-aa, aa, dEyes);

        // Hexagonal / Sacred geometry shell scutes
        float2 sp = (p - float2(-0.04, 0.0)) * 4.2;
        float hexRing = abs(length(sp) - 1.35);
        float spokes = abs(sin(atan2(sp.y, sp.x) * 3.0));
        float scutePattern = smoothstep(0.18, 0.04, min(hexRing, spokes * 0.45)) * shellMask;

        // Color composition
        float3 limbCol = mix(float3(0.10, 0.55, 0.52), in.penColor.rgb * 0.75, 0.35);
        float3 shellBase = mix(float3(0.08, 0.14, 0.24), in.penColor.rgb * 0.45, 0.35);
        float3 shellRim = in.penColor.rgb * 1.85;

        float rimMask = smoothstep(-0.12, -0.01, dShell) * shellMask;

        float3 col = limbCol;
        col = mix(col, shellBase, shellMask);
        col = mix(col, shellRim, clamp(scutePattern * 0.75 + rimMask * 0.9, 0.0, 1.0));
        col = mix(col, float3(1.0, 1.0, 1.0) * 2.0, eyeMask);

        // Glowing crystal pen nib at turtle origin (0,0) when pen is down
        float dNib = length(p);
        float nibGlow = exp(-dNib * 5.0) * (in.penDown != 0 ? 1.35 : 0.35);
        col += in.penColor.rgb * nibGlow * 1.8;

        // Soft outer selection/direction aura
        float outerHalo = exp(-max(dBody, 0.0) * 5.5) * 0.45;
        float alpha = clamp(bodyMask + outerHalo, 0.0, 1.0);
        if (alpha < 0.005) { discard_fragment(); }

        return float4(col, alpha);
    }

    // MARK: - 6. Multi-Pass HDR Bloom & Final ACES Tonemap Composite

    fragment float4 bloom_threshold_fragment(
        FullscreenOut in [[stage_in]],
        texture2d<float> hdrTex [[texture(0)]]
    ) {
        constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
        float3 c = hdrTex.sample(s, in.uv).rgb;
        float brightness = max(c.r, max(c.g, c.b));
        float soft = clamp((brightness - 0.65) / 1.2, 0.0, 1.0);
        float contribution = max(0.0, brightness - 0.85) + soft * soft * 0.35;
        float3 bloom = c * (contribution / max(brightness, 0.0001));
        return float4(min(bloom, float3(12.0)), 1.0);
    }

    fragment float4 bloom_blur_fragment(
        FullscreenOut in [[stage_in]],
        texture2d<float> srcTex [[texture(0)]],
        constant float2 &texelStep [[buffer(0)]]
    ) {
        constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
        // 9-tap separable Gaussian via 5 bilinear taps
        float weights[3] = { 0.2270270270, 0.3162162162, 0.0702702703 };
        float offsets[3] = { 0.0, 1.3846153846, 3.2307692308 };

        float3 acc = srcTex.sample(s, in.uv).rgb * weights[0];
        for (int i = 1; i < 3; ++i) {
            float2 off = texelStep * offsets[i];
            acc += srcTex.sample(s, in.uv + off).rgb * weights[i];
            acc += srcTex.sample(s, in.uv - off).rgb * weights[i];
        }
        return float4(acc, 1.0);
    }

    static inline float3 acesFilm(float3 x) {
        float a = 2.51;
        float b = 0.03;
        float c = 2.43;
        float d = 0.59;
        float e = 0.14;
        return clamp((x * (a * x + b)) / (x * (c * x + d) + e), 0.0, 1.0);
    }

    fragment float4 composite_fragment(
        FullscreenOut in [[stage_in]],
        texture2d<float> sceneTex [[texture(0)]],
        texture2d<float> bloomTex [[texture(1)]],
        constant FrameUniforms &u [[buffer(0)]]
    ) {
        constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
        float3 hdr = sceneTex.sample(s, in.uv).rgb;
        float3 bloom = bloomTex.sample(s, in.uv).rgb;

        float3 combined = hdr + bloom * u.bloomIntensity;

        // For parchment backdrop, preserve natural paper brightness without heavy film darkening
        float3 mapped;
        if (u.backdropKind == 2) {
            mapped = clamp(combined, 0.0, 1.0);
        } else {
            mapped = acesFilm(combined * 0.96);
            mapped = pow(mapped, float3(0.95)); // Subtle punchy contrast
        }

        return float4(mapped, 1.0);
    }
    """#
}
