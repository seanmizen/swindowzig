// fxaa.wgsl — FXAA 3.11 post-process anti-aliasing
// Adapted from Timothy Lottes' public-domain FXAA 3.11 algorithm for WGSL/WebGPU.
// All texture samples use textureSampleLevel (explicit LOD = 0) so the shader is
// valid in non-uniform control flow (loops, conditionals).  No vertex buffer is
// required; positions are generated from @builtin(vertex_index).
//
// Bind group 0:
//   binding 0 — texture_2d<f32>  (scene colour, bgra8unorm, same size as swapchain)
//   binding 1 — sampler           (linear, clamp_to_edge)

struct VertexOutput {
    @builtin(position) pos: vec4<f32>,
    @location(0) uv: vec2<f32>,
}

// Full-screen triangle: three vertices cover the entire NDC viewport.
//   vi=0 → (-1,-1), vi=1 → (3,-1), vi=2 → (-1,3)
// After clipping the triangle fills exactly the viewport; interpolated UVs
// cover [0,1]² with standard WebGPU orientation (y=0 = top).
@vertex
fn vs_main(@builtin(vertex_index) vi: u32) -> VertexOutput {
    let x = select(-1.0, 3.0, vi == 1u);
    let y = select(-1.0, 3.0, vi == 2u);
    var out: VertexOutput;
    out.pos = vec4<f32>(x, y, 0.0, 1.0);
    // UV: NDC x in [-1,1] → [0,1]; NDC y flipped (y=1 is top in NDC, y=0 is top in UV)
    out.uv = vec2<f32>((x + 1.0) * 0.5, (1.0 - y) * 0.5);
    return out;
}

@group(0) @binding(0) var t_scene: texture_2d<f32>;
@group(0) @binding(1) var s_scene: sampler;

// ── FXAA constants ────────────────────────────────────────────────────────────

// Minimum local contrast below which FXAA is skipped (protects dark areas).
const EDGE_THRESHOLD_MIN: f32 = 0.0312;
// Fraction of local maximum luma — skip pixels with contrast below this.
const EDGE_THRESHOLD: f32 = 0.125;
// Cap on the subpixel blend contribution (0.75 = 75 % of a pixel).
const SUBPIX_CAP: f32 = 0.75;
// Maximum steps to search along the detected edge in each direction.
const SEARCH_STEPS: i32 = 12;
// Fraction of the edge gradient used as the end-of-edge luminance threshold.
const SEARCH_THRESHOLD: f32 = 0.25;

// ── Helpers ───────────────────────────────────────────────────────────────────

fn luma(rgb: vec3<f32>) -> f32 {
    return dot(rgb, vec3<f32>(0.299, 0.587, 0.114));
}

// ── Fragment shader ───────────────────────────────────────────────────────────

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4<f32> {
    let dim = vec2<f32>(textureDimensions(t_scene, 0));
    let rcp = 1.0 / dim;   // UV extent of one pixel
    let uv  = in.uv;

    // ── 5-tap cross neighbourhood ─────────────────────────────────────────────
    let rgbM = textureSampleLevel(t_scene, s_scene, uv,                               0.0).rgb;
    let rgbN = textureSampleLevel(t_scene, s_scene, uv + vec2<f32>( 0.0, -rcp.y),    0.0).rgb;
    let rgbS = textureSampleLevel(t_scene, s_scene, uv + vec2<f32>( 0.0,  rcp.y),    0.0).rgb;
    let rgbW = textureSampleLevel(t_scene, s_scene, uv + vec2<f32>(-rcp.x,  0.0),    0.0).rgb;
    let rgbE = textureSampleLevel(t_scene, s_scene, uv + vec2<f32>( rcp.x,  0.0),    0.0).rgb;

    let lumM = luma(rgbM);
    let lumN = luma(rgbN);
    let lumS = luma(rgbS);
    let lumW = luma(rgbW);
    let lumE = luma(rgbE);

    // Local contrast — early exit for non-edge pixels
    let lumMax   = max(lumM, max(max(lumN, lumS), max(lumW, lumE)));
    let lumMin   = min(lumM, min(min(lumN, lumS), min(lumW, lumE)));
    let lumRange = lumMax - lumMin;
    if (lumRange < max(EDGE_THRESHOLD_MIN, lumMax * EDGE_THRESHOLD)) {
        return vec4<f32>(rgbM, 1.0);
    }

    // ── Diagonal neighbours (for edge orientation Sobel) ──────────────────────
    let lumNW = luma(textureSampleLevel(t_scene, s_scene, uv + vec2<f32>(-rcp.x, -rcp.y), 0.0).rgb);
    let lumNE = luma(textureSampleLevel(t_scene, s_scene, uv + vec2<f32>( rcp.x, -rcp.y), 0.0).rgb);
    let lumSW = luma(textureSampleLevel(t_scene, s_scene, uv + vec2<f32>(-rcp.x,  rcp.y), 0.0).rgb);
    let lumSE = luma(textureSampleLevel(t_scene, s_scene, uv + vec2<f32>( rcp.x,  rcp.y), 0.0).rgb);

    // ── Subpixel blend ────────────────────────────────────────────────────────
    // How far does the centre luma deviate from the cross-neighbourhood average?
    let lumL    = (lumN + lumS + lumW + lumE) * 0.25;
    let subpix  = clamp(abs(lumL - lumM) / lumRange, 0.0, 1.0);
    let subBlend = subpix * subpix * SUBPIX_CAP;   // squared for gentler curve

    // ── Edge orientation ──────────────────────────────────────────────────────
    // Sobel-style 3×3 gradient:
    //   edgeH large → vertical luminance gradient → *horizontal* edge (runs in X)
    //   edgeV large → horizontal luminance gradient → *vertical* edge (runs in Y)
    let edgeH = abs(lumNW + 2.0*lumN + lumNE - lumSW - 2.0*lumS - lumSE);
    let edgeV = abs(lumNW + 2.0*lumW + lumSW - lumNE - 2.0*lumE - lumSE);
    let isHorz = edgeH >= edgeV;   // true → edge runs in X, blur/search in Y/X resp.

    // Perpendicular neighbours (across the edge)
    let lumNeg = select(lumW, lumN, isHorz);   // "negative" perp neighbour
    let lumPos = select(lumE, lumS, isHorz);   // "positive" perp neighbour

    let gradNeg = abs(lumNeg - lumM);
    let gradPos = abs(lumPos - lumM);
    let goNeg   = gradNeg >= gradPos;   // true → steeper gradient on the negative side

    // Direction toward steeper gradient (perpendicular to edge, in UV-pixel units)
    let perpSign = select(1.0, -1.0, goNeg);

    // lumSide: average of the two pixels forming the edge (target for the search)
    let lumSide      = (select(lumPos, lumNeg, goNeg) + lumM) * 0.5;
    let gradThreshold = max(gradNeg, gradPos) * SEARCH_THRESHOLD;

    // ── Edge search ───────────────────────────────────────────────────────────
    // Move 0.5 pixels toward the steeper side so the search probes sit on the
    // edge rather than inside one of the blocks.
    //   isHorz=true  → edge runs in X, perpendicular = Y → start offset in Y
    //   isHorz=false → edge runs in Y, perpendicular = X → start offset in X
    let halfOff = perpSign * 0.5;
    let startUV = select(
        uv + vec2<f32>(halfOff * rcp.x, 0.0),    // isHorz=false: Y-running edge, X perp
        uv + vec2<f32>(0.0, halfOff * rcp.y),     // isHorz=true:  X-running edge, Y perp
        isHorz
    );

    // Search direction: along the edge (not perpendicular)
    //   isHorz=true  → search in X: sStep=(rcp.x, 0)
    //   isHorz=false → search in Y: sStep=(0, rcp.y)
    let sStep = select(vec2<f32>(0.0, rcp.y), vec2<f32>(rcp.x, 0.0), isHorz);

    var uvNeg     = startUV;
    var uvPos     = startUV;
    var lumEndNeg = 0.0;
    var lumEndPos = 0.0;
    var doneNeg   = false;
    var donePos   = false;

    for (var i: i32 = 0; i < SEARCH_STEPS; i++) {
        if (!doneNeg) {
            uvNeg    -= sStep;
            lumEndNeg = luma(textureSampleLevel(t_scene, s_scene, uvNeg, 0.0).rgb);
            doneNeg   = abs(lumEndNeg - lumSide) >= gradThreshold;
        }
        if (!donePos) {
            uvPos    += sStep;
            lumEndPos = luma(textureSampleLevel(t_scene, s_scene, uvPos, 0.0).rgb);
            donePos   = abs(lumEndPos - lumSide) >= gradThreshold;
        }
    }

    // ── Edge blend factor ─────────────────────────────────────────────────────
    // Distance (in search-axis UV) from the current pixel to each endpoint
    let distNeg = select(abs(uvNeg.y - uv.y), abs(uvNeg.x - uv.x), isHorz);
    let distPos = select(abs(uvPos.y - uv.y), abs(uvPos.x - uv.x), isHorz);
    let span    = distNeg + distPos;

    let isNearerNeg = distNeg < distPos;
    let nearDist    = select(distPos, distNeg, isNearerNeg);
    let lumNearEnd  = select(lumEndPos, lumEndNeg, isNearerNeg);

    // Only apply edge blend if the nearer endpoint is on the OPPOSITE side of
    // lumSide from the centre — confirms we found a real edge terminus rather
    // than just exhausting the search budget.
    let goodSpan  = (lumNearEnd < lumSide) != (lumM < lumSide);
    let edgeBlend = select(0.0, 0.5 - nearDist / span, goodSpan);

    // ── Combine and sample ────────────────────────────────────────────────────
    let totalBlend = max(subBlend, edgeBlend);

    // Shift UV perpendicular to the edge by totalBlend pixels toward the steeper side
    let blendPx  = totalBlend * perpSign;
    let blendUV  = select(
        uv + vec2<f32>(blendPx * rcp.x, 0.0),    // isHorz=false: shift in X
        uv + vec2<f32>(0.0, blendPx * rcp.y),     // isHorz=true:  shift in Y
        isHorz
    );

    return textureSampleLevel(t_scene, s_scene, blendUV, 0.0);
}
