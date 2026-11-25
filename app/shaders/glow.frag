#version 460 core

// One soft round light to lay over something (lib/widget/shareme/ambient.dart), dithered like backdrop.frag.

precision highp float;

#include <flutter/runtime_effect.glsl>

uniform vec4 uPlace; // center x, center y, radius, device pixel ratio
uniform vec4 uColor; // rgb, strength

out vec4 fragColor;

// Interleaved gradient noise, see backdrop.frag
float noise(vec2 px) {
  return fract(52.9829189 * fract(dot(px, vec2(0.06711056, 0.00583715)))) - 0.5;
}

void main() {
  vec2 p = FlutterFragCoord().xy;
  float a = uColor.a * max(0.0, 1.0 - distance(p, uPlace.xy) / uPlace.z);
  if (a <= 0.0) {
    fragColor = vec4(0.0);
    return;
  }
  // Both the opacity and the color are rounded to 8 bits when they are blended, so both are dithered
  vec2 px = floor(p * uPlace.w);
  a = clamp(a + noise(px) / 255.0, 0.0, 1.0);
  fragColor = vec4(uColor.rgb * a + noise(px + vec2(47.0, 17.0)) / 255.0, a);
}
