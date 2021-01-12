// A bit of an attempt at a CRT shader, not at all good or developed yet
// Works on shadertoy.com


vec4 v_at(vec2 xy)
{
    vec4 texColor = texture(iChannel0, xy);    //Get the pixel at xy from iChannel0

    vec2 bumpxy = vec2(xy[0] * 10., xy[1] * 10.);
    vec4 bumptex = texture(iChannel2, bumpxy);

    vec4 texBump = bumptex * texture(iChannel0, xy) * 3.5;

    return texBump;

}

vec4 t_at(vec2 xy)
{
    vec4 texColor = texture(iChannel0, xy);    //Get the pixel at xy from iChannel0
    return texColor;
}

void mainImage( out vec4 fragColor, in vec2 fragCoord )
{
    vec2 xy = fragCoord.xy / iResolution.xy;  //Condensing this into one line

    vec4 texOut = vec4(0., 0., 0., 0.);
    int n = 3;
    float wsum = 0.;
    for(int x=-n; x <= 0; x++)
    {
        float w = abs(float(n - abs(x)));
        wsum += w;
        texOut += w * t_at(vec2(xy[0] + float(x) / 300., xy[1]));

    }
    texOut /= wsum;
    vec2 bumpxy = vec2(xy[0] * 250., xy[1] * 250.);
    vec4 bumptex = texture(iChannel2, bumpxy) * 0.3 + 0.8;
    vec4 texBump = bumptex * texOut;
    fragColor = texBump;  //Set the screen pixel to that color
}
