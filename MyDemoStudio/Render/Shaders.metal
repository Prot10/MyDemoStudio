#include <metal_stdlib>
using namespace metal;

// Uniform layout — must match `GPUUniforms` on the Swift side exactly. Everything is
// packed as float4 so alignment is trivially identical across the two languages.
struct GPUUniforms {
    float4 outputSize_corner;  // x=outW, y=outH, z=cornerRadius(px), w=unused
    float4 contentRect;        // x,y,w,h — screen placement at zoom 1 (output px, top-left origin)
    float4 zoom;               // x=focusX, y=focusY (output px), z=zoomScale, w=unused
    float4 bgColor1;           // rgba
    float4 bgColor2;           // rgba
    float4 bgParams;           // x=angleRadians, y=kind(0 solid,1 gradient), z=cursorMode(0 none,1 dot,2 arrow), w unused
    float4 shadow;             // x=radius(px), y=opacity, z=zoomBlur(uv frac), w unused
    float4 cursor;             // dot: x,y,radius,_  |  arrow: originX,originY,spriteW,spriteH (output px)
    float4 cursorColor;        // rgba (dot tint)
    float4 camera;             // x,y (output px), z=radius, w=enabled
    float4 cameraParams;       // x=aspect(w/h)
    float4 caption;            // x,y (top-left, output px), z=w, w=h of the text texture
};

struct VOut {
    float4 position [[position]];
    float2 uv;                 // 0..1, top-left origin
};

// Fullscreen triangle; uv has top-left origin to match CoreVideo textures.
vertex VOut demo_vertex(uint vid [[vertex_id]]) {
    float2 clip[3] = { float2(-1.0, -3.0), float2(-1.0, 1.0), float2(3.0, 1.0) };
    VOut out;
    float2 p = clip[vid];
    out.position = float4(p, 0.0, 1.0);
    out.uv = float2((p.x + 1.0) * 0.5, (1.0 - p.y) * 0.5);
    return out;
}

// A built-in mesh-gradient wallpaper: four corner colors blended bilinearly, softened
// toward their mean by `blur`.
static float3 wallpaperColor(float2 uv, int idx, float blur) {
    float3 c00, c10, c01, c11;
    switch (idx) {
        case 1:  c00=float3(0.98,0.45,0.42); c10=float3(0.96,0.76,0.36); c01=float3(0.94,0.35,0.55); c11=float3(0.99,0.62,0.34); break; // sunset
        case 2:  c00=float3(0.11,0.37,0.33); c10=float3(0.20,0.55,0.42); c01=float3(0.08,0.45,0.55); c11=float3(0.30,0.62,0.40); break; // forest
        case 3:  c00=float3(0.10,0.12,0.28); c10=float3(0.30,0.16,0.52); c01=float3(0.16,0.10,0.34); c11=float3(0.44,0.22,0.66); break; // midnight
        case 4:  c00=float3(0.98,0.58,0.30); c10=float3(0.94,0.32,0.46); c01=float3(0.85,0.28,0.62); c11=float3(0.99,0.72,0.36); break; // coral
        case 5:  c00=float3(0.16,0.18,0.22); c10=float3(0.30,0.33,0.38); c01=float3(0.10,0.11,0.13); c11=float3(0.24,0.26,0.30); break; // graphite
        default: c00=float3(0.42,0.30,0.86); c10=float3(0.24,0.62,0.94); c01=float3(0.70,0.34,0.90); c11=float3(0.28,0.48,0.96); break; // violet (0)
    }
    float2 t = smoothstep(0.0, 1.0, uv);
    float3 top = mix(c00, c10, t.x);
    float3 bot = mix(c01, c11, t.x);
    float3 col = mix(top, bot, t.y);
    float3 mean = (c00 + c10 + c01 + c11) * 0.25;
    return mix(col, mean, clamp(blur, 0.0, 1.0) * 0.7);
}

// Signed distance to a rounded box centered at `center` with the given half-extents.
static float sdRoundedBox(float2 p, float2 center, float2 halfExtent, float r) {
    float2 q = abs(p - center) - (halfExtent - r);
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}

fragment float4 demo_fragment(VOut in [[stage_in]],
                              texture2d<float> source [[texture(0)]],
                              texture2d<float> cursorTex [[texture(1)]],
                              texture2d<float> cameraTex [[texture(2)]],
                              texture2d<float> captionTex [[texture(3)]],
                              constant GPUUniforms &u [[buffer(0)]]) {
    constexpr sampler samp(address::clamp_to_edge, filter::linear);

    float2 outputSize = u.outputSize_corner.xy;
    float2 p = in.uv * outputSize;                 // pixel coordinate, top-left origin

    // --- Background --- (kind: 0 solid, 1 gradient, 2 wallpaper)
    float3 color;
    float kind = u.bgParams.y;
    if (kind > 1.5) {
        color = wallpaperColor(in.uv, int(u.bgParams.w + 0.5), u.shadow.w);
    } else if (kind > 0.5) {
        float angle = u.bgParams.x;
        float2 dir = float2(cos(angle), sin(angle));
        float t = clamp(dot(in.uv - 0.5, dir) + 0.5, 0.0, 1.0);
        color = mix(u.bgColor1.rgb, u.bgColor2.rgb, t);
    } else {
        color = u.bgColor1.rgb;
    }

    // --- Rounded-rect window geometry ---
    float2 rectOrigin = u.contentRect.xy;
    float2 rectSize = u.contentRect.zw;
    float2 center = rectOrigin + rectSize * 0.5;
    float2 halfExtent = rectSize * 0.5;
    float radius = u.outputSize_corner.z;
    float d = sdRoundedBox(p, center, halfExtent, radius);

    // --- Drop shadow (outside the window) ---
    float shadowRadius = max(u.shadow.x, 1.0);
    float shadowAlpha = u.shadow.y * smoothstep(shadowRadius, 0.0, d) * step(0.0, d);
    color = mix(color, float3(0.0), shadowAlpha);

    // --- Screen content --- camera "looks at" focusUV (master uv of the cursor) and
    // shows a 1/z-sized window around it, so the focus lands at the CENTER of the screen.
    float2 focusUV = u.zoom.xy;              // master uv (0..1) of the focus point
    float z = max(u.zoom.z, 0.0001);
    float2 contentNorm = (p - rectOrigin) / rectSize;   // 0..1 across the padded screen rect
    float2 srcUV = focusUV + (contentNorm - 0.5) / z;

    // Antialiased coverage of the rounded window.
    float aa = max(fwidth(d), 1e-4);
    float windowAlpha = clamp(0.5 - d / aa, 0.0, 1.0);

    if (windowAlpha > 0.0) {
        float blur = u.shadow.z;
        float3 screenColor;
        if (blur > 0.001) {
            // Radial zoom-blur: sample along the line toward the zoom focus, growing
            // with distance from it — approximates motion blur during a zoom move.
            float2 toFocus = srcUV - focusUV;
            const int N = 6;
            float3 acc = float3(0.0);
            for (int i = 0; i < N; i++) {
                float k = ((float(i) / float(N - 1)) - 0.5) * blur;
                acc += source.sample(samp, clamp(srcUV - toFocus * k, 0.0, 1.0)).rgb;
            }
            screenColor = acc / float(N);
        } else {
            screenColor = source.sample(samp, clamp(srcUV, 0.0, 1.0)).rgb;
        }
        color = mix(color, screenColor, windowAlpha);
    }

    // --- Cursor ---
    float cursorMode = u.bgParams.z;
    if (cursorMode > 1.5) {
        // Textured arrow: cursor = (originX, originY, spriteW, spriteH); tip at origin.
        float2 rel = (p - u.cursor.xy) / u.cursor.zw;
        if (rel.x >= 0.0 && rel.x <= 1.0 && rel.y >= 0.0 && rel.y <= 1.0) {
            float4 c = cursorTex.sample(samp, rel);   // premultiplied alpha
            color = c.rgb + color * (1.0 - c.a);
        }
    } else if (cursorMode > 0.5) {
        // Debug dot: cursor = (cx, cy, radius, _).
        float cr = max(u.cursor.z, 1.0);
        float dist = length(p - u.cursor.xy);
        float fill = smoothstep(cr, cr - 2.0, dist);
        float ring = smoothstep(cr + 2.5, cr + 0.5, dist) * (1.0 - fill);
        color = mix(color, float3(0.0), ring * 0.35);
        color = mix(color, u.cursorColor.rgb, fill * u.cursorColor.a);
    }

    // --- Captions --- (dark pill + white text texture, near the bottom)
    if (u.caption.z > 0.5) {
        float2 tmin = u.caption.xy;
        float2 tsize = u.caption.zw;
        float pad = tsize.y * 0.45;
        float2 pmin = tmin - float2(pad, pad * 0.55);
        float2 psize = tsize + float2(pad * 2.0, pad * 1.1);
        float2 pcenter = pmin + psize * 0.5;
        float pd = sdRoundedBox(p, pcenter, psize * 0.5, psize.y * 0.32);
        float pillAA = max(fwidth(pd), 1e-4);
        float pillAlpha = clamp(0.5 - pd / pillAA, 0.0, 1.0);
        color = mix(color, float3(0.0), pillAlpha * 0.6);

        float2 tuv = (p - tmin) / tsize;
        if (tuv.x >= 0.0 && tuv.x <= 1.0 && tuv.y >= 0.0 && tuv.y <= 1.0) {
            float coverage = captionTex.sample(samp, tuv).a;
            color = mix(color, float3(1.0), coverage);
        }
    }

    // --- Webcam bubble ---
    if (u.camera.w > 0.5) {
        float2 d = p - u.camera.xy;
        float dist = length(d);
        float r = u.camera.z;
        if (dist < r + 3.0) {
            float2 uvc = (d / r) * 0.5 + 0.5;              // 0..1 across the circle's bbox
            float asp = max(u.cameraParams.x, 0.01);
            float2 cuv = uvc;
            if (asp > 1.0) { cuv.x = (uvc.x - 0.5) / asp + 0.5; }  // center-crop wide camera to square
            else           { cuv.y = (uvc.y - 0.5) * asp + 0.5; }
            cuv.x = 1.0 - cuv.x;                           // mirror (selfie view)
            float3 cam = cameraTex.sample(samp, clamp(cuv, 0.0, 1.0)).rgb;
            float inside = smoothstep(r, r - 1.5, dist);
            float ring = smoothstep(r + 2.5, r + 0.5, dist) * (1.0 - inside);
            color = mix(color, float3(1.0), ring * 0.6);
            color = mix(color, cam, inside);
        }
    }

    return float4(color, 1.0);
}
