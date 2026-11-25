#version 460 core

// The app's backdrop (lib/widget/shareme/ambient.dart): a vertical base gradient and two soft round lights, in one pass and dithered.
// Impeller doesn't dither its own gradients on OpenGL ES (phones with an Adreno 650 or older fall back to it), which shows as rings.

precision highp float;

#include <flutter/runtime_effect.glsl>

uniform vec4 uFrame;  // width, height, device pixel ratio, unused
uniform vec4 uTop;
uniform vec4 uBottom;
uniform vec4 uGlow1;  // rgb, strength
uniform vec4 uPlace1; // center x, center y, radius, unused
uniform vec4 uGlow2;
uniform vec4 uPlace2;

out vec4 fragColor;

void main() {
  vec2 p = FlutterFragCoord().xy;
  vec3 color = mix(uTop.rgb, uBottom.rgb, clamp(p.y / uFrame.y, 0.0, 1.0));
  color = mix(color, uGlow1.rgb, uGlow1.a * max(0.0, 1.0 - distance(p, uPlace1.xy) / uPlace1.z));
  color = mix(color, uGlow2.rgb, uGlow2.a * max(0.0, 1.0 - distance(p, uPlace2.xy) / uPlace2.z));
  // Interleaved gradient noise (Jorge Jimenez, 2014): up to half a step more or less per pixel hides the edge between two colors
  vec2 px = floor(p * uFrame.z);
  float noise = fract(52.9829189 * fract(dot(px, vec2(0.06711056, 0.00583715))));
  fragColor = vec4(color + (noise - 0.5) / 255.0, 1.0);
}
