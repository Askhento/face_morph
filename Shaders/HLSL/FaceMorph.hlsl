#include "Uniforms.hlsl"
#include "Samplers.hlsl"
#include "Transform.hlsl"
#include "ScreenPos.hlsl"
#line 5

#define PI 3.14159265

#ifdef FACE
uniform float4x3 cFaceInvMatrix;
uniform float cProgress;
#endif

#ifdef COMPILEPS
uniform float2 cBlurDir;
uniform float cBlurRadius;
uniform float cBlurSigma;
uniform float2 cBlurHInvSize;
#endif

// bit hacking
float2 unpack2x16floatFromRGBA(float4 value) {
  float2 bitSh = float2(1.0, 1.0) / float2(1.0, 255.0);
  float2 res = float2(dot(value.xy, bitSh), dot(value.zw, bitSh));
  // using -1 to 1 range
  res = res * 2.0 - 1.0;
  return clamp(res, -1.0, 1.0);
}

float4 pack2x16FloatToRGBA(float2 value) {
  // compress data
  value = clamp(value * 0.5 + 0.5, 0.0, 1.0);
  float4 bitSh = float4(1.0, 255.0, 1.0, 255.0);
  float4 bitMsk = float4(1.0 / 255.0, 0.0, 1.0 / 255.0, 0.0);
  float4 res = frac(value.xxyy * bitSh);
  res -= res.yyww * bitMsk;
  return res;
}

// Adapted: http://callumhay.blogspot.com/2010/09/gaussian-blur-shader-glsl.html
#ifndef D3D11
float4 GaussianBlur(int blurKernelSize, float2 blurDir, float2 blurRadius, float sigma, sampler2D texSampler, float2 texCoord)
#else
float4 GaussianBlur(int blurKernelSize, float2 blurDir, float2 blurRadius, float sigma, Texture2D tex, SamplerState texSampler, float2 texCoord)
#endif
{
    const int blurKernelHalfSize = blurKernelSize / 2;

    // Incremental Gaussian Coefficent Calculation (See GPU Gems 3 pp. 877 - 889)
    float3 gaussCoeff;
    gaussCoeff.x = 1.0 / (sqrt(2.0 * PI) * sigma);
    gaussCoeff.y = exp(-0.5 / (sigma * sigma));
    gaussCoeff.z = gaussCoeff.y * gaussCoeff.y;

    float2 blurVec = blurRadius * blurDir;
    float2 avgValue = float2(0.0, 0.0);
    float gaussCoeffSum = 0.0;

    #ifndef D3D11
    avgValue += unpack2x16floatFromRGBA(tex2D(texSampler, texCoord)) * gaussCoeff.x;
    #else
    avgValue += unpack2x16floatFromRGBA(tex.Sample(texSampler, texCoord)) * gaussCoeff.x;
    #endif

    gaussCoeffSum += gaussCoeff.x;
    gaussCoeff.xy *= gaussCoeff.yz;

    for (int i = 1; i <= blurKernelHalfSize; i++)
    {
        #ifndef D3D11
        avgValue += unpack2x16floatFromRGBA(tex2D(texSampler, texCoord - i * blurVec)) * gaussCoeff.x;
        avgValue += unpack2x16floatFromRGBA(tex2D(texSampler, texCoord + i * blurVec)) * gaussCoeff.x;
        #else
        avgValue += unpack2x16floatFromRGBA(tex.Sample(texSampler, texCoord - i * blurVec)) * gaussCoeff.x;
        avgValue += unpack2x16floatFromRGBA(tex.Sample(texSampler, texCoord + i * blurVec)) * gaussCoeff.x;
        #endif

        gaussCoeffSum += 2.0 * gaussCoeff.x;
        gaussCoeff.xy *= gaussCoeff.yz;
    }

    return pack2x16FloatToRGBA(avgValue / gaussCoeffSum);
}

void VS(
    float4 iPos: POSITION,
    float3 iNormal: NORMAL,
    float4 iTangent : TANGENT,
    float2 iTexCoord: TEXCOORD0,
    float2 iTexCoord1: TEXCOORD1,
    out float2 oTexCoord: TEXCOORD0,
    out float2 oScreenPos: TEXCOORD1,
    out float4 oPos: OUTPOSITION
#ifdef DEBUG
        ,
        out float4 oColor: COLOR0
#endif
) {

#ifdef FACE
  float4x3 modelMatrix = iModelMatrix;
  float4 basePos = float4(iTangent.xyz, 1.0);
  float4 morphedPos = iPos;
  float4 facePos = float4(iTexCoord, iTexCoord1);
  float3 faceWorld = mul(facePos, modelMatrix).xyz;
  float3 faceView = mul(mul(facePos, modelMatrix), cView).xyz;

  float3 faceNormal = normalize(mul(float4(iNormal, 0.0), cFaceInvMatrix).xyz);
  float3 eyeDir = normalize(faceWorld - cCameraPos);
  float cameraFacing = (dot(eyeDir, faceNormal));
  cameraFacing = smoothstep(0.0, 1.0, cameraFacing) * 0.5  + 0.5;

  float3 vertexOffset = lerp(float3(0.0, 0.0, 0.0), morphedPos.xyz - basePos.xyz, cProgress);
  float4 localPos = float4(facePos.xyz + vertexOffset, 1.0);

  // localPos = float4(iPos.xyz, 1.0);
  // localPos = float4(facePos.xyz, 1.0);
  // localPos = float4(iNormal.xyz, 1.0);

#ifdef DEBUG
  float offsetAmount = length(vertexOffset);
  oColor = float4(vertexOffset, offsetAmount);
  oColor.xyz = float3(cameraFacing, cameraFacing, cameraFacing);
#endif

  float3 worldPos = mul(localPos, modelMatrix).xyz;
  oPos = GetClipPos(worldPos);
  oScreenPos = GetScreenPosPreDiv(GetClipPos(mul(facePos, modelMatrix).xyz)) - GetScreenPosPreDiv(GetClipPos(mul(localPos, modelMatrix).xyz));
  // oScreenPos *= 2.0;
  // oScreenPos += 0.5;
  oTexCoord = GetTexCoord(iTexCoord);
#endif

#ifdef UV_QUAD
  oPos = float4(iPos.xy, 0.0, 1.0);
  oScreenPos = iPos.xy * 0.5 + 0.5;
  oScreenPos.y = 1.0  - oScreenPos.y;
  oTexCoord = oScreenPos;
#endif
}

void PS(
    float2 iTexCoord : TEXCOORD0, 
    float2 iScreenPos: TEXCOORD1,
#ifdef DEBUG
    float4 iColor : COLOR0,
#endif
    out float4 oColor : OUTCOLOR0) 
{

#ifdef WARP
  float2 newScreenPos = unpack2x16floatFromRGBA(Sample2D(NormalMap, iScreenPos));
  float4 diffuse = Sample2D(DiffMap, newScreenPos + iScreenPos);
  oColor = diffuse;
#endif

#ifdef UV_QUAD
  oColor = pack2x16FloatToRGBA(vTexCoord);
#endif

#ifdef FACE
  oColor = pack2x16FloatToRGBA(iScreenPos);
#ifdef DEBUG
  oColor = float4(iColor.xyz / (iColor.w + 1.0), 1.0);
  // debug with tone map
  // oColor.xyz = iColor.xyz;
#endif
#endif

#ifdef BLUR3
    #ifndef D3D11 
        oColor = GaussianBlur(3, cBlurDir, cBlurHInvSize * cBlurRadius, cBlurSigma, sDiffMap, iScreenPos);
    #else
        oColor = GaussianBlur(3, cBlurDir, cBlurHInvSize * cBlurRadius, cBlurSigma, tDiffMap, sDiffMap, iScreenPos);
    #endif
#endif

#ifdef BLUR5
    #ifndef D3D11
        oColor = GaussianBlur(5, cBlurDir, cBlurHInvSize * cBlurRadius, cBlurSigma, sDiffMap, iScreenPos);
    #else
        oColor = GaussianBlur(5, cBlurDir, cBlurHInvSize * cBlurRadius, cBlurSigma, tDiffMap, sDiffMap, iScreenPos);
    #endif
#endif

#ifdef BLUR7
    #ifndef D3D11
        oColor = GaussianBlur(7, cBlurDir, cBlurHInvSize * cBlurRadius, cBlurSigma, sDiffMap, iScreenPos);
    #else
        oColor = GaussianBlur(7, cBlurDir, cBlurHInvSize * cBlurRadius, cBlurSigma, tDiffMap, sDiffMap, iScreenPos);
    #endif
#endif

#ifdef BLUR9
    #ifndef D3D11
        oColor = GaussianBlur(9, cBlurDir, cBlurHInvSize * cBlurRadius, cBlurSigma, sDiffMap, iScreenPos);
    #else
        oColor = GaussianBlur(9, cBlurDir, cBlurHInvSize * cBlurRadius, cBlurSigma, tDiffMap, sDiffMap, iScreenPos);
    #endif
#endif
}
