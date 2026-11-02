// license:GPLv3+

$input v_texcoord0, v_eye

#include "common.sh"

// Foveation composer: rebuilds each full resolution eye from its 3 pictures, in linear HDR (before bloom and tonemapping).
// The pictures are the layers of a texture array: layer = picture * 2 + eye, picture 0 being the coarse full eye, 1 the
// middle window and 2 the sharp window (see FoveaLayout.h). Windows blend over the picture below with a round feather,
// and are hard limited to their round support so that their square corners never contribute.

SAMPLER2DARRAY(tex_fb_filtered, 0); // Pictures color (bilinear)
SAMPLER2DARRAY(tex_depth, 4); // Pictures depth (point)

uniform vec4 w_h_height; // xy = 1 / picture size, zw = picture size
uniform vec4 foveaRects[4]; // Window placement in the eye, (u0, v0, u1, v1) with v pointing up, indexed by eye * 2 + window (0 = middle, 1 = sharp)
uniform vec4 foveaParams; // x = feather inner radius, y = support radius, z = feather dither amplitude, w = unused

// Flips between texture coordinates and coordinates with v pointing up (the same operation both ways)
vec2 flipV(const vec2 uv)
{
#if TEX_V_IS_UP
   return uv;
#else
   return vec2(uv.x, 1.0 - uv.y);
#endif
}

// Window contribution at window NDC radius r: 1 inside, quintic falloff across the feather, 0 from the support radius
float featherWeight(const float r)
{
   const float t = saturate((r - foveaParams.x) / (foveaParams.y - foveaParams.x));
   return r >= foveaParams.y ? 0.0 : 1.0 - t * t * t * (t * (t * 6.0 - 15.0) + 10.0);
}

// Coarse picture upsampling: bilinear with a slightly eased phase, keeping the 4 texel footprint (no ringing)
vec3 coarseRead(const vec2 uv, const float layer)
{
   const vec2 q = uv * w_h_height.zw - 0.5;
   const vec2 base = floor(q);
   const vec2 phase = q - base;
   const vec2 eased = mix(phase, phase * phase * (3.0 - 2.0 * phase), 0.35);
   return texture2DArrayLod(tex_fb_filtered, vec3((base + eased + 0.5) * w_h_height.xy, layer), 0.0).rgb;
}

// Point sample of a window texel, dropped if its centre is outside of the window support
vec3 supportTexel(const vec2 texel, const float layer, const float weight)
{
   const vec2 c = (texel + 0.5) * w_h_height.xy;
   BRANCH if (weight <= 0.0 || length(2.0 * c - 1.0) >= foveaParams.y)
      return vec3_splat(0.0);
   return weight * texture2DArrayLod(tex_fb_filtered, vec3(c, layer), 0.0).rgb;
}

// Window picture read at window texture coordinate uv (radius r in window NDC). Texels outside of the support never
// contribute: near the support edge, the bilinear filter is done by hand, without renormalization.
vec3 windowRead(const vec2 uv, const float layer, const float r)
{
   BRANCH if (r < foveaParams.y - 1.4143 * 2.0 * w_h_height.x)
      return texture2DArrayLod(tex_fb_filtered, vec3(uv, layer), 0.0).rgb;
   const vec2 q = uv * w_h_height.zw - 0.5;
   const vec2 i0 = floor(q);
   const vec2 f = q - i0;
   return supportTexel(i0,                   layer, (1.0 - f.x) * (1.0 - f.y))
        + supportTexel(i0 + vec2(1.0, 0.0), layer, f.x * (1.0 - f.y))
        + supportTexel(i0 + vec2(0.0, 1.0), layer, (1.0 - f.x) * f.y)
        + supportTexel(i0 + vec2(1.0, 1.0), layer, f.x * f.y);
}

void main()
{
   const float eye = round(v_eye);
   const vec2 up = flipV(v_texcoord0);
   // Small dither of the blend weight inside the feather bands, to break any banding of the transition
   const float dither = (fract(52.9829189 * fract(dot(gl_FragCoord.xy, vec2(0.06711056, 0.00583715)))) - 0.5) * foveaParams.z;

   // Sharp window
   const vec4 rectS = foveaRects[int(eye) * 2 + 1];
   const vec2 wS = (up - rectS.xy) / (rectS.zw - rectS.xy);
   const float rS = length(2.0 * wS - 1.0);
   float aS = featherWeight(rS);
   if (aS > 0.0 && aS < 1.0)
      aS = saturate(aS + dither);

   vec3 color;
   float depth;
   BRANCH if (aS >= 1.0)
   {
      color = windowRead(flipV(wS), 4.0 + eye, rS);
      depth = texture2DArrayLod(tex_depth, vec3(flipV(wS), 4.0 + eye), 0.0).x;
   }
   else
   {
      // Middle window
      const vec4 rectM = foveaRects[int(eye) * 2];
      const vec2 wM = (up - rectM.xy) / (rectM.zw - rectM.xy);
      const float rM = length(2.0 * wM - 1.0);
      float aM = featherWeight(rM);
      if (aM > 0.0 && aM < 1.0)
         aM = saturate(aM + dither);
      BRANCH if (aM >= 1.0)
         color = windowRead(flipV(wM), 2.0 + eye, rM);
      else if (aM > 0.0)
         color = mix(coarseRead(v_texcoord0, eye), windowRead(flipV(wM), 2.0 + eye, rM), aM);
      else
         color = coarseRead(v_texcoord0, eye);
      if (aS > 0.0)
         color = mix(color, windowRead(flipV(wS), 4.0 + eye, rS), aS);

      // Depth is selected (never blended) from the most detailed picture contributing at least half of the color
      if (aS >= 0.5)
         depth = texture2DArrayLod(tex_depth, vec3(flipV(wS), 4.0 + eye), 0.0).x;
      else if (aM >= 0.5)
         depth = texture2DArrayLod(tex_depth, vec3(flipV(wM), 2.0 + eye), 0.0).x;
      else
         depth = texture2DArrayLod(tex_depth, vec3(v_texcoord0, eye), 0.0).x;
   }

   gl_FragColor = vec4(color, 1.0);
   gl_FragDepth = depth;
}
