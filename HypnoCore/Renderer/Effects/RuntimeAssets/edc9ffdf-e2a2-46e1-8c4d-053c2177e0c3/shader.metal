#include <metal_stdlib>
using namespace metal;

struct HypnoParams {
    int profileMode;      // 0 auto, 1 snes/nes, 2 md/ps1, 3 pce
    bool palMode;
    int cableType;        // 0 rf, 1 composite, 2 s-video
    float lumaBandwidth;
    float chromaBandwidth;
    float chromaGain;
    float rfJitter;
    float dotCrawl;
    int frameIndex;
    int textureWidth;
    int textureHeight;
};

inline float3 rgbToYiq(float3 rgb) {
    float y = dot(rgb, float3(0.299, 0.587, 0.114));
    float i = dot(rgb, float3(0.596, -0.274, -0.322));
    float q = dot(rgb, float3(0.211, -0.523, 0.312));
    return float3(y, i, q);
}

inline float3 yiqToRgb(float3 yiq) {
    float r = dot(yiq, float3(1.000, 0.956, 0.621));
    float g = dot(yiq, float3(1.000, -0.272, -0.647));
    float b = dot(yiq, float3(1.000, -1.106, 1.703));
    return float3(r, g, b);
}

inline float blackmanWindow(float n, float N, float bw) {
    float safeN = max(N, 1.0);
    return (0.5 - bw)
        - (0.5 * cos((2.0 * M_PI_F * n) / safeN))
        + (bw * cos((4.0 * M_PI_F * n) / safeN));
}

inline float hash12(float2 p) {
    return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.5453123);
}

inline float cyclesPerPixel(int profileMode, float sourceWidth) {
    constexpr float snesNes = 0.6666;
    constexpr float mdPs1 = 0.5333;
    constexpr float pce = 0.5;

    if (profileMode == 1) {
        return M_PI_F * snesNes;
    }
    if (profileMode == 2) {
        return M_PI_F * mdPs1;
    }
    if (profileMode == 3) {
        return M_PI_F * pce;
    }

    // Auto profile: approximate 256px/320px split.
    return M_PI_F * (sourceWidth < 300.0 ? snesNes : mdPs1);
}

inline int tapRadiusForCable(int cableType) {
    if (cableType == 0) { return 13; } // RF
    if (cableType == 1) { return 11; } // Composite
    return 9;                          // S-Video
}

kernel void render(
    texture2d<float, access::sample> inputTexture [[texture(0)]],
    texture2d<float, access::write> outputTexture [[texture(1)]],
    constant HypnoParams& params [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= uint(params.textureWidth) || gid.y >= uint(params.textureHeight)) {
        return;
    }

    constexpr sampler linearSampler(mag_filter::linear, min_filter::linear, address::clamp_to_edge);

    float2 texSize = float2(params.textureWidth, params.textureHeight);
    float2 texel = 1.0 / max(texSize, float2(1.0));
    float2 uv = (float2(gid) + 0.5) * texel;
    float2 pixelPos = float2(gid);

    int cableType = clamp(params.cableType, 0, 2);
    int radius = tapRadiusForCable(cableType);
    float cycles = cyclesPerPixel(clamp(params.profileMode, 0, 3), texSize.x);

    float linePhase = 0.0;
    if (params.profileMode == 1) {
        linePhase = floor(pixelPos.y) * cycles;
    } else if (params.palMode) {
        linePhase = fmod(floor(pixelPos.y), 2.0) * M_PI_F;
    }

    float crawlAmount = clamp(params.dotCrawl, 0.0, 1.0);
    float framePhase = 0.0;
    if (crawlAmount > 0.0001) {
        int phasePeriod = (cableType == 0) ? 3 : 2;
        float phaseUnit = float(params.frameIndex % phasePeriod) / float(phasePeriod);
        framePhase = phaseUnit * (2.0 * M_PI_F) * crawlAmount;
    }

    float timeSeconds = float(params.frameIndex) / 60.0;
    float rfDrift = 0.0;
    if (cableType == 0) {
        rfDrift = sin(timeSeconds * 0.8 + uv.y * 120.0 + timeSeconds * 5.0) * 0.0015 * clamp(params.rfJitter, 0.0, 1.0);
    }

    float yAccum = 0.0;
    float iAccum = 0.0;
    float qAccum = 0.0;
    float yWeightSum = 0.0;
    float cWeightSum = 0.0;

    float lumaBW = clamp(params.lumaBandwidth / 10.0, 0.0, 0.5);
    float chromaBW = clamp(params.chromaBandwidth / 10.0, 0.0, 0.5);

    for (int tap = -radius; tap <= radius; tap++) {
        float tapF = float(tap);
        float n = tapF + float(radius);
        float N = float(radius * 2);

        float tapJitter = 0.0;
        if (cableType == 0) {
            float noise = hash12(float2(tapF + float(gid.x), float(gid.y) + timeSeconds * 17.0));
            tapJitter = (noise - 0.5) * clamp(params.rfJitter, 0.0, 1.0) * 0.6;
        }

        float2 sampleUV = uv + float2((tapF + tapJitter) * texel.x + rfDrift, 0.0);
        sampleUV = clamp(sampleUV, float2(0.0), float2(1.0));
        float3 yiq = rgbToYiq(inputTexture.sample(linearSampler, sampleUV).rgb);

        float yWeight = blackmanWindow(n, N, lumaBW);
        float cWeight = blackmanWindow(n, N, chromaBW);
        yWeightSum += yWeight;
        cWeightSum += cWeight;

        if (cableType == 2) {
            // S-Video approximation: less cross-talk, mostly separated Y/C.
            yAccum += yiq.x * yWeight;
            iAccum += yiq.y * cWeight;
            qAccum += yiq.z * cWeight;
            continue;
        }

        float phase = (floor(pixelPos.x) + tapF + tapJitter) * cycles + linePhase + framePhase;
        float carrierI = cos(phase);
        float carrierQ = sin(phase);

        // Composite/RF encode to one wire, then decode.
        float compositeSignal = yiq.x + yiq.y * carrierI + yiq.z * carrierQ;
        yAccum += compositeSignal * yWeight;
        iAccum += compositeSignal * carrierI * cWeight * 2.0;
        qAccum += compositeSignal * carrierQ * cWeight * 2.0;
    }

    float safeY = max(yWeightSum, 1e-6);
    float safeC = max(cWeightSum, 1e-6);

    float y = yAccum / safeY;
    float i = (iAccum / safeC) * max(params.chromaGain, 0.0);
    float q = (qAccum / safeC) * max(params.chromaGain, 0.0);

    if (cableType == 0) {
        float snow = (hash12(float2(float(gid.x), float(gid.y) + float(params.frameIndex) * 13.7)) - 0.5)
            * 0.04 * clamp(params.rfJitter, 0.0, 1.0);
        y += snow;
    }

    float3 rgbOut = yiqToRgb(float3(y, i, q));
    float alpha = inputTexture.sample(linearSampler, uv).a;

    // Small RF smear to reduce "too-clean shader" feel.
    if (cableType == 0) {
        float smear = clamp(params.rfJitter * 0.25, 0.0, 0.5);
        float2 smearUV = clamp(uv + float2(texel.x * 2.0, 0.0), float2(0.0), float2(1.0));
        float3 smearRGB = inputTexture.sample(linearSampler, smearUV).rgb;
        rgbOut = mix(rgbOut, smearRGB, smear);
    }

    outputTexture.write(float4(clamp(rgbOut, 0.0, 1.0), alpha), gid);
}
