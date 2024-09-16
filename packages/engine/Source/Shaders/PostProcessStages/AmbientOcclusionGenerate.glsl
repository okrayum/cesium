precision highp float;

uniform sampler2D randomTexture;
uniform sampler2D depthTexture;
uniform float intensity;
uniform float bias;
uniform float lengthCap;
uniform float stepSize;
uniform float frustumLength;

in vec2 v_textureCoordinates;

vec4 clipToEye(vec2 uv, float depth)
{
    vec2 xy = 2.0 * uv - vec2(1.0);
    vec4 posEC = czm_inverseProjection * vec4(xy, depth, 1.0);
    posEC = posEC / posEC.w;
    return posEC;
}

vec3 pixelToEye(vec2 screenCoordinate)
{
    float depthOrLogDepth = texelFetch(depthTexture, ivec2(screenCoordinate), 0).r;
    float depth = czm_reverseLogDepth(depthOrLogDepth);
    ivec2 screenDimensions = textureSize(depthTexture, 0);
    vec2 normalizedCoordinate = screenCoordinate / vec2(screenDimensions);
    return clipToEye(normalizedCoordinate, depth).xyz;
}

// Reconstruct surface normal in eye coordinates, avoiding edges
vec3 getNormalXEdge(vec3 positionEC)
{
    // Find the 3D surface positions at adjacent screen pixels
    vec2 centerCoord = gl_FragCoord.xy;
    vec3 positionLeft = pixelToEye(centerCoord + vec2(-1.0, 0.0));
    vec3 positionRight = pixelToEye(centerCoord + vec2(1.0, 0.0));
    vec3 positionUp = pixelToEye(centerCoord + vec2(0.0, 1.0));
    vec3 positionDown = pixelToEye(centerCoord + vec2(0.0, -1.0));

    // Compute potential tangent vectors
    vec3 dx0 = positionEC - positionLeft;
    vec3 dx1 = positionRight - positionEC;
    vec3 dy0 = positionEC - positionDown;
    vec3 dy1 = positionUp - positionEC;

    // The shorter tangent is more likely to be on the same surface
    vec3 dx = length(dx0) < length(dx1) ? dx0 : dx1;
    vec3 dy = length(dy0) < length(dy1) ? dy0 : dy1;

    return normalize(cross(dx, dy));
}

void main(void)
{
    vec2 screenSize = vec2(textureSize(depthTexture, 0));

    vec3 positionEC = pixelToEye(gl_FragCoord.xy);

    if (positionEC.z > frustumLength)
    {
        out_FragColor = vec4(1.0);
        return;
    }

    vec3 normalEC = getNormalXEdge(positionEC);

    float ao = 0.0;

    const int ANGLE_STEPS = 4;
    float angleStepScale = 1.0 / float(ANGLE_STEPS);
    float angleStep = angleStepScale * czm_twoPi;
    float cosStep = cos(angleStep);
    float sinStep = sin(angleStep);
    mat2 rotateStep = mat2(cosStep, sinStep, -sinStep, cosStep);

    // Initial sampling direction (different for each pixel)
    vec2 randomTextureSize = vec2(textureSize(randomTexture, 0));
    vec2 randomTexCoord = mod(gl_FragCoord.xy, randomTextureSize);
    float randomVal = texelFetch(randomTexture, ivec2(randomTexCoord), 0).x;
    vec2 sampleDirection = vec2(cos(angleStep * randomVal), sin(angleStep * randomVal));

    // Loop over sampling directions
    for (int i = 0; i < ANGLE_STEPS; i++)
    {
        sampleDirection = rotateStep * sampleDirection;

        float localAO = 0.0;
        vec2 radialStep = stepSize * sampleDirection;

        for (int j = 0; j < 6; j++)
        {
            // Step along sampling direction, away from output pixel
            vec2 newCoords = floor(gl_FragCoord.xy + float(j + 1) * radialStep) + vec2(0.5);

            // Exit if we stepped off the screen
            if (clamp(newCoords, vec2(0.0), screenSize) != newCoords)
            {
                break;
            }

            vec3 stepPositionEC = pixelToEye(newCoords);
            vec3 stepVector = stepPositionEC - positionEC;
            float stepLength = length(stepVector);

            if (stepLength > lengthCap)
            {
                // TODO: should we continue instead? We don't want to cut off the background shading if we crossed a foreground wire
                break;
            }

            float dotVal = clamp(dot(normalEC, normalize(stepVector)), 0.0, 1.0);
            if (dotVal < bias)
            {
                dotVal = 0.0;
            }

            float weight = stepLength / lengthCap;
            weight = 1.0 - weight * weight;
            localAO = max(localAO, dotVal * weight);
        }
        ao += localAO;
    }

    ao *= angleStepScale;
    ao = 1.0 - clamp(ao, 0.0, 1.0);
    ao = pow(ao, intensity);
    out_FragColor = vec4(vec3(ao), 1.0);
}
