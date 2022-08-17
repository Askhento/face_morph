#include "Uniforms.glsl"
#include "Samplers.glsl"
#include "ScreenPos.glsl"
#include "Transform.glsl"
#line 6

const float PI = 3.14159265;
varying HIGHP_AUTO vec2 vTexCoord;
varying HIGHP_AUTO vec2 vScreenPos;
varying vec4 vColor;

#ifdef FACE
uniform mat4 cFaceInvMatrix;
uniform float cProgress;
#endif

#ifdef COMPILEPS
uniform vec2 cBlurDir;
uniform float cBlurRadius;
uniform float cBlurSigma;
uniform vec2 cBlurHInvSize;
#endif

// bit hacking
vec2 unpack2x16floatFromRGBA(vec4 value) {
  vec2 bitSh = vec2(1.0) / vec2(1.0, 255.0);
  vec2 res = vec2(dot(value.xy, bitSh), dot(value.zw, bitSh));
  // using -1 to 1 range
  res = res * 2.0 - 1.0;
  return clamp(res, -1.0, 1.0);
}

vec4 pack2x16FloatToRGBA(vec2 value) {
  // compress data
  value = clamp(value * 0.5 + 0.5, 0.0, 1.0);
  vec4 bitSh = vec4(1.0, 255.0, 1.0, 255.0);
  vec4 bitMsk = vec4(1.0 / 255.0, 0.0, 1.0 / 255.0, 0.0);
  vec4 res = fract(value.xxyy * bitSh);
  res -= res.yyww * bitMsk;
  return res;
}


// Adapted: http://callumhay.blogspot.com/2010/09/gaussian-blur-shader-glsl.html
vec4 GaussianBlur(int blurKernelSize, vec2 blurDir, vec2 blurRadius,
                  float sigma, sampler2D texSampler, vec2 texCoord) {
  int blurKernelSizeHalfSize = blurKernelSize / 2;

  // Incremental Gaussian Coefficent Calculation (See GPU Gems 3 pp. 877 - 889)
  vec3 gaussCoeff;
  gaussCoeff.x = 1.0 / (sqrt(2.0 * PI) * sigma);
  gaussCoeff.y = exp(-0.5 / (sigma * sigma));
  gaussCoeff.z = gaussCoeff.y * gaussCoeff.y;

  vec2 blurVec = blurRadius * blurDir;
  vec2 avgValue = vec2(0.0);
  float gaussCoeffSum = 0.0;

  avgValue +=
      unpack2x16floatFromRGBA(texture2D(texSampler, (texCoord))) * gaussCoeff.x;
  gaussCoeffSum += gaussCoeff.x;
  gaussCoeff.xy *= gaussCoeff.yz;

  for (int i = 1; i <= blurKernelSizeHalfSize; i++) {
    avgValue += unpack2x16floatFromRGBA(
                    texture2D(texSampler, (texCoord - float(i) * blurVec))) *
                gaussCoeff.x;
    avgValue += unpack2x16floatFromRGBA(
                    texture2D(texSampler, (texCoord + float(i) * blurVec))) *
                gaussCoeff.x;

    gaussCoeffSum += 2.0 * gaussCoeff.x;
    gaussCoeff.xy *= gaussCoeff.yz;
  }

  return pack2x16FloatToRGBA(avgValue / gaussCoeffSum);
}

void VS() {

#ifdef FACE
  mat4 modelMatrix = iModelMatrix;
  vec4 basePos = vec4(iTangent.xyz, 1.0);
  vec4 morphedPos = iPos;
  vec4 facePos = vec4(iTexCoord, iTexCoord1);
  vec3 faceWorld = (facePos * modelMatrix).xyz;
  vec3 faceView = (facePos * modelMatrix * cView).xyz;

  vec3 faceNormal = normalize((vec4(iNormal, 0.0) * cFaceInvMatrix).xyz);
  vec3 eyeDir = normalize(faceWorld - cCameraPos);
  float cameraFacing = (dot(eyeDir, faceNormal));
  cameraFacing = smoothstep(0.0, 1.0, cameraFacing) * 0.5  + 0.5;
  // cameraFacing = smoothstep(0.5, 0.0, abs(cameraFacing));

  vec3 vertexOffset = mix(vec3(0.0), morphedPos.xyz - basePos.xyz, cProgress) * cameraFacing;
  vec4 localPos = vec4(facePos.xyz + vertexOffset, 1.0);

  // localPos = vec4(iPos.xyz, 1.0);
  // localPos = vec4(facePos.xyz, 1.0);


  float offsetAmount = length(vertexOffset);
  vColor = vec4(vertexOffset, offsetAmount);
  // vColor.xyz = vec3(cameraFacinsg);

  vec3 worldPos = (localPos * modelMatrix).xyz;
  gl_Position = GetClipPos(worldPos);
  vScreenPos = GetScreenPosPreDiv(GetClipPos((facePos * modelMatrix).xyz)) -
               GetScreenPosPreDiv(GetClipPos((localPos * modelMatrix).xyz));
  // vScreenPos *= 2.0;
  // vScreenPos += 0.5;
  vTexCoord = GetTexCoord(iTexCoord);
#endif

#ifdef DEPTH

  // vec3 worldPos = (localPos * modelMatrix).xyz;
  // gl_Position = GetClipPos(worldPos);
#endif

#ifdef UV_QUAD
  gl_Position = vec4(iPos.xy, 0.0, 1.0);
  vScreenPos = iPos.xy * 0.5 + 0.5;
  // vScreenPos.y = 1.0  - vScreenPos.y;
  vTexCoord = vScreenPos;
#endif
}

void PS() {

#ifdef WARP

  // HIGHP_AUTO vec2 newScreenPos = texture2D(sNormalMap, vScreenPos).xy;
  vec2 newScreenPos =
      unpack2x16floatFromRGBA(texture2D(sNormalMap, vScreenPos));
  vec4 diffuse = texture2D(sDiffMap, newScreenPos + vScreenPos);
  gl_FragColor = diffuse;

  // diffuse =  texture2D(sDiffMap, vScreenPos);
  // gl_FragColor = vec4(newScreenPos * 10.0, 0.0, 0.0) + diffuse;
  // gl_FragColor = vec4(abs(newScreenPos) * 100.0, 0.0, 1.0);
#endif

#ifdef UV_QUAD
  gl_FragColor = pack2x16FloatToRGBA(vTexCoord);
#endif

#ifdef FACE
  gl_FragColor = pack2x16FloatToRGBA(vScreenPos);
#ifdef DEBUG
    gl_FragColor = vec4(vColor.xyz / (vColor.w + 1.0), 1.0);
    // gl_FragColor = vColor;
    // float d = ReconstructDepth(texture2D(sDepthBuffer, vScreenPos).r); // use ReconstructDepth when HWDEPTH
    // gl_FragColor.xyz = vec3(d);
#endif
#endif

#ifdef BLUR3
  gl_FragColor = GaussianBlur(3, cBlurDir, cBlurHInvSize * cBlurRadius,
                              cBlurSigma, sDiffMap, vScreenPos);
#endif

#ifdef BLUR5
  gl_FragColor = GaussianBlur(5, cBlurDir, cBlurHInvSize * cBlurRadius,
                              cBlurSigma, sDiffMap, vScreenPos);
#endif

#ifdef BLUR7
  gl_FragColor = GaussianBlur(7, cBlurDir, cBlurHInvSize * cBlurRadius,
                              cBlurSigma, sDiffMap, vScreenPos);
#endif

#ifdef BLUR9
  gl_FragColor = GaussianBlur(9, cBlurDir, cBlurHInvSize * cBlurRadius,
                              cBlurSigma, sDiffMap, vScreenPos);
#endif
}
