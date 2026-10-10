// The Visualizer's shaders (SGRShaderSource.h): the prelude every one is compiled with, the built-in bodies, and
// the store of the user's own.
#import "SGRShaderSource.h"

_Static_assert(sizeof(SGRShaderUniforms) == 224, "SGRShaderUniforms must match SGRUniforms in the prelude");

NSString *const SGRShaderHills = @"hills";
static NSString *const kCustomPrefix = @"custom.";

#pragma mark - the source

// Everything a body may use. Each line is a line of the compiled source, so the compiler's line numbers can be
// told back as the body's.
static NSString *const kPrelude =
    @"#include <metal_stdlib>\n"
    @"using namespace metal;\n"
    @"\n"
    @"// The uniforms every shader gets, in this order (SGRShaderSource.h's SGRShaderUniforms).\n"
    @"struct SGRUniforms {\n"
    @"    float time;            // seconds, wrapping each hour\n"
    @"    float2 resolution;     // the drawable, in pixels\n"
    @"    float4 palette[4];     // the cover's colors, rgb in 0..1, a = 1\n"
    @"    float bands[32];       // the spectrum, 30 Hz to 16 kHz evenly in pitch, each 0..1\n"
    @"    float rms;             // the loudness, 0..1\n"
    @"    float beat;            // 1 on a beat, decaying to 0\n"
    @"    float intensity;       // the Intensity slider, 0.25..2\n"
    @"    float ceiling;         // the mod's own: the brightest the result may be\n"
    @"};\n"
    @"\n"
    @"struct SGRVertexOut {\n"
    @"    float4 position [[position]];\n"
    @"    float2 uv;\n"
    @"};\n"
    @"\n"
    @"// One triangle over the whole drawable; uv runs 0..1 from the top left.\n"
    @"vertex SGRVertexOut sgr_vertex(uint id [[vertex_id]]) {\n"
    @"    float2 p = float2(float((id << 1) & 2), float(id & 2));\n"
    @"    SGRVertexOut out;\n"
    @"    out.position = float4(p * 2.0 - 1.0, 0.0, 1.0);\n"
    @"    out.uv = float2(p.x, 1.0 - p.y);\n"
    @"    return out;\n"
    @"}\n"
    @"\n"
    @"// A band at x, 0 the lowest and 1 the highest, read between the two nearest.\n"
    @"float sgrBand(constant SGRUniforms &u, float x) {\n"
    @"    float f = clamp(x, 0.0, 1.0) * 31.0;\n"
    @"    int i = int(f);\n"
    @"    int j = min(i + 1, 31);\n"
    @"    return mix(u.bands[i], u.bands[j], f - float(i));\n"
    @"}\n"
    @"\n"
    @"float sgrAverage(constant SGRUniforms &u, int from, int to) {\n"
    @"    float sum = 0.0;\n"
    @"    for (int i = from; i < to; i++) sum += u.bands[i];\n"
    @"    return sum / float(to - from);\n"
    @"}\n"
    @"\n"
    @"float sgrBass(constant SGRUniforms &u) { return sgrAverage(u, 0, 7); }      // up to about 120 Hz\n"
    @"float sgrMids(constant SGRUniforms &u) { return sgrAverage(u, 8, 20); }     // about 150 Hz to 2 kHz\n"
    @"float sgrHighs(constant SGRUniforms &u) { return sgrAverage(u, 20, 32); }   // above\n"
    @"\n"
    @"// The four colors around a loop: t and t + 1 are the same color.\n"
    @"float3 sgrPalette(constant SGRUniforms &u, float t) {\n"
    @"    float f = fract(t) * 4.0;\n"
    @"    int i = int(f) % 4;\n"
    @"    int j = (i + 1) % 4;\n"
    @"    return mix(u.palette[i].rgb, u.palette[j].rgb, smoothstep(0.0, 1.0, fract(f)));\n"
    @"}\n"
    @"\n"
    @"float sgrHash(float2 p) {\n"
    @"    p = fract(p * float2(123.34, 456.21));\n"
    @"    p += dot(p, p + 45.32);\n"
    @"    return fract(p.x * p.y);\n"
    @"}\n"
    @"\n"
    @"float sgrNoise(float2 p) {\n"
    @"    float2 i = floor(p);\n"
    @"    float2 f = fract(p);\n"
    @"    float2 w = f * f * (3.0 - 2.0 * f);\n"
    @"    float a = sgrHash(i), b = sgrHash(i + float2(1.0, 0.0));\n"
    @"    float c = sgrHash(i + float2(0.0, 1.0)), d = sgrHash(i + float2(1.0, 1.0));\n"
    @"    return mix(mix(a, b, w.x), mix(c, d, w.x), w.y);\n"
    @"}\n"
    @"\n"
    @"float sgrFbm(float2 p) {\n"
    @"    float sum = 0.0, amplitude = 0.5;\n"
    @"    for (int octave = 0; octave < 4; octave++) {\n"
    @"        sum += amplitude * sgrNoise(p);\n"
    @"        p = p * 2.03 + float2(1.7, 9.2);\n"
    @"        amplitude *= 0.5;\n"
    @"    }\n"
    @"    return sum;\n"
    @"}\n"
    @"\n"
    @"// uv about the middle, x scaled by the aspect, so a circle is round: y runs -0.5..0.5.\n"
    @"float2 sgrCentered(float2 uv, constant SGRUniforms &u) {\n"
    @"    return (uv - 0.5) * float2(u.resolution.x / max(u.resolution.y, 1.0), 1.0);\n"
    @"}\n";

static NSString *const kOpen =
    @"float4 sgrShade(float2 uv, constant SGRUniforms &u) {\n";

// The fragment function: the body's color with its alpha clamped, NaNs dropped and its light held under the
// ceiling with its hue kept, premultiplied for the layer.
static NSString *const kClose =
    @"}\n"
    @"\n"
    @"// The color held under the ceiling as light, its hue kept, and premultiplied for the layer.\n"
    @"fragment float4 sgr_fragment(SGRVertexOut in [[stage_in]], constant SGRUniforms &u [[buffer(0)]]) {\n"
    @"    float4 c = sgrShade(in.uv, u);\n"
    @"    float alpha = saturate(isnan(c.a) ? 0.0 : c.a);\n"
    @"    float3 light = pow(clamp(c.rgb, 0.0, 16.0), 2.2);\n"
    @"    if (any(isnan(light))) light = float3(0.0);\n"
    @"    float luminance = dot(light, float3(0.2126, 0.7152, 0.0722));\n"
    @"    if (luminance > u.ceiling) light *= u.ceiling / luminance;\n"
    @"    float3 rgb = pow(saturate(light), 1.0 / 2.2);\n"
    @"    return float4(rgb * alpha, alpha);\n"
    @"}\n";

#pragma mark - the built-in ones

static NSString *const kAuroraBody =
    @"// Ribbons of light flowing across the upper half, swelling with the bass and the mids.\n"
    @"float bass = sgrBass(u), mids = sgrMids(u);\n"
    @"float t = u.time * (0.06 + 0.06 * u.intensity);\n"
    @"float3 color = float3(0.0);\n"
    @"float alpha = 0.0;\n"
    @"for (int i = 0; i < 3; i++) {\n"
    @"    float fi = float(i);\n"
    @"    float level = i == 0 ? bass : mids;\n"
    @"    float drift = sgrFbm(float2(uv.x * 1.6 + fi * 3.7, t * 0.8 + fi));\n"
    @"    float y = 0.18 + 0.14 * fi + 0.07 * sin(uv.x * (2.2 + fi) + t * (1.3 + 0.4 * fi)) + 0.12 * (drift - 0.5);\n"
    @"    float width = 0.025 + 0.06 * level * u.intensity;\n"
    @"    float d = uv.y - y;\n"
    @"    // Sharper above, a long soft fall below, as an aurora's curtain hangs.\n"
    @"    float curtain = d < 0.0 ? exp(-d * d / (width * width * 0.3)) : exp(-d / (width * 2.5));\n"
    @"    curtain *= 0.45 + 0.55 * sgrFbm(float2(uv.x * 9.0 - t * 3.0, fi * 5.3));\n"
    @"    color += sgrPalette(u, fi * 0.3 + uv.x * 0.4 + t * 0.15) * 2.4 * curtain;\n"
    @"    alpha += curtain;\n"
    @"}\n"
    @"return float4(color / max(alpha, 0.001), saturate(alpha * (0.45 + 0.3 * u.intensity + 0.25 * u.beat)));\n";

static NSString *const kPulseBody =
    @"// The spectrum around a ring, the bass at the top and the treble at the foot, both sides alike; it kicks on a beat.\n"
    @"float2 p = sgrCentered(uv, u);\n"
    @"p.y += 0.08;\n"
    @"float r = length(p);\n"
    @"float x = abs(atan2(p.x, -p.y)) / M_PI_F;\n"
    @"float level = sgrBand(u, x);\n"
    @"float radius = 0.14 * (1.0 + 0.08 * u.beat * u.intensity);\n"
    @"float reach = radius + 0.1 * level * u.intensity;\n"
    @"float spike = smoothstep(radius - 0.004, radius, r) * (1.0 - smoothstep(reach - 0.004, reach + 0.002, r));\n"
    @"spike *= 0.5 + 0.5 * smoothstep(0.0, 0.5, sin(x * 32.0 * M_PI_F) * 0.5 + 0.5);\n"
    @"float rim = exp(-abs(r - radius) * 90.0);\n"
    @"float glow = exp(-max(r - reach, 0.0) * 14.0) * (0.25 + 0.5 * level) * step(radius, r);\n"
    @"float core = exp(-r * 9.0) * (0.15 + 0.35 * u.rms);\n"
    @"float3 color = sgrPalette(u, x * 0.75 + u.time * 0.03) * 2.4;\n"
    @"return float4(color, saturate(spike * 0.85 + rim * 0.7 + glow * 0.5 + core));\n";

static NSString *const kLiquidBody =
    @"// Six blobs drifting and melting into each other, each swelling with its part of the song and all with the bass.\n"
    @"float2 p = sgrCentered(uv, u);\n"
    @"float half_width = 0.5 * u.resolution.x / max(u.resolution.y, 1.0);\n"
    @"float bass = sgrBass(u);\n"
    @"float field = 0.0, weight = 0.0;\n"
    @"float3 color = float3(0.0);\n"
    @"for (int i = 0; i < 6; i++) {\n"
    @"    float fi = float(i);\n"
    @"    float2 c = float2(sin(u.time * (0.13 + 0.03 * fi) + fi * 1.7) * half_width * 0.75,\n"
    @"                      cos(u.time * (0.11 + 0.025 * fi) + fi * 2.3) * 0.36);\n"
    @"    float r = 0.045 + 0.03 * sgrBand(u, (fi + 0.5) / 6.0) * u.intensity + 0.035 * bass * u.intensity;\n"
    @"    float v = r * r / max(dot(p - c, p - c), 0.0001);\n"
    @"    field += v;\n"
    @"    color += sgrPalette(u, fi * 0.21 + 0.05 * u.time) * v;\n"
    @"    weight += v;\n"
    @"}\n"
    @"color = color / max(weight, 0.0001) * (1.8 + 0.6 * u.beat);\n"
    @"float inside = smoothstep(0.85, 1.05, field);\n"
    @"float rim = smoothstep(0.55, 0.95, field) * (1.0 - inside);\n"
    @"return float4(color * (1.0 + rim), saturate(inside * 0.8 + rim * 0.45));\n";

static NSString *const kStarsBody =
    @"// Three layers of stars drifting up, each twinkling with its band and the brightest flaring on a beat.\n"
    @"float2 p = sgrCentered(uv, u);\n"
    @"float3 color = float3(0.0);\n"
    @"float alpha = 0.0;\n"
    @"for (int layer = 0; layer < 3; layer++) {\n"
    @"    float fl = float(layer);\n"
    @"    float scale = 9.0 + fl * 7.0;\n"
    @"    float2 q = p * scale + float2(fl * 13.1, u.time * (0.12 + 0.1 * fl) * (0.6 + 0.4 * u.intensity));\n"
    @"    float2 cell = floor(q);\n"
    @"    float2 f = fract(q) - 0.5;\n"
    @"    float h = sgrHash(cell + fl * 17.0);\n"
    @"    float2 offset = (float2(sgrHash(cell + 3.1), sgrHash(cell + 7.7)) - 0.5) * 0.6;\n"
    @"    float d = length(f - offset);\n"
    @"    float level = sgrBand(u, h);\n"
    @"    float size = 0.025 + 0.05 * level * u.intensity + 0.07 * u.beat * u.intensity * step(0.8, h);\n"
    @"    float star = smoothstep(size, 0.0, d) * step(0.45, h);\n"
    @"    float halo = exp(-d * 14.0) * 0.25 * level * step(0.45, h);\n"
    @"    float twinkle = 0.55 + 0.45 * sin(u.time * (1.0 + 3.0 * h) + h * 40.0);\n"
    @"    float light = (star + halo) * twinkle;\n"
    @"    color += sgrPalette(u, h * 4.0) * 3.0 * light;\n"
    @"    alpha += light;\n"
    @"}\n"
    @"return float4(color / max(alpha, 0.001), saturate(alpha));\n";

static NSString *const kGlowBody =
    @"// A glowing line across the foot of the screen, waving with the song: each band a wave of its own pitch.\n"
    @"float wave = 0.0;\n"
    @"for (int i = 0; i < 8; i++) {\n"
    @"    float fi = float(i);\n"
    @"    float level = sgrBand(u, (fi + 0.5) / 8.0);\n"
    @"    wave += level * sin(uv.x * (2.0 + fi * 3.0) * M_PI_F + u.time * (1.2 + fi * 0.8)) / (1.0 + fi * 0.4);\n"
    @"}\n"
    @"float y = 0.78 + wave * 0.045 * u.intensity;\n"
    @"float d = abs(uv.y - y);\n"
    @"float core = exp(-d * 420.0);\n"
    @"float glow = exp(-d * 30.0) * (0.35 + 0.45 * u.rms + 0.3 * u.beat);\n"
    @"float echo = exp(-abs(uv.y - (0.78 - wave * 0.03 * u.intensity)) * 70.0) * 0.25;\n"
    @"float3 color = sgrPalette(u, uv.x * 0.8 + u.time * 0.05) * 2.6;\n"
    @"return float4(color, saturate(core + glow * 0.8 + echo));\n";

static NSString *const kPrismBody =
    @"// Bands of the cover's colors at a slant, split like light through glass: the mids spread them, the bass packs them.\n"
    @"float2 p = sgrCentered(uv, u);\n"
    @"float t = u.time * 0.04;\n"
    @"float angle = 0.7 + 0.25 * sin(t * 1.3);\n"
    @"float s = dot(p, float2(cos(angle), sin(angle)));\n"
    @"float bend = sgrFbm(p * 1.8 + float2(t, -t)) * 1.4;\n"
    @"float v = s * (7.0 + 4.0 * sgrBass(u) * u.intensity) + bend + t * 6.0;\n"
    @"float split = 0.25 + 0.9 * sgrMids(u) * u.intensity;\n"
    @"float3 bands = 0.5 + 0.5 * sin(float3(v - split, v, v + split));\n"
    @"float3 base = sgrPalette(u, v * 0.06);\n"
    @"float shine = pow(max(bands.x, max(bands.y, bands.z)), 10.0) * (0.25 + 0.6 * u.beat + 0.4 * sgrHighs(u));\n"
    @"float3 color = base * (0.5 + 1.6 * bands) + base * shine * 2.0;\n"
    @"return float4(color, saturate(0.55 + 0.2 * u.intensity + 0.25 * shine));\n";

static NSString *const kTemplateBody =
    @"// A soft light in the middle that breathes with the bass.\n"
    @"float2 p = sgrCentered(uv, u);\n"
    @"float light = exp(-length(p) * (7.0 - 3.0 * sgrBass(u) * u.intensity));\n"
    @"float3 color = sgrPalette(u, u.time * 0.05 + length(p)) * 2.0;\n"
    @"return float4(color, light * (0.6 + 0.4 * u.beat));\n";

// Identifier, name and body of each, Hills first with no body.
static NSArray<NSArray<NSString *> *> *builtIns(void) {
    static NSArray *list;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        list = @[
            @[SGRShaderHills, @"Hills"],
            @[@"aurora", @"Aurora", kAuroraBody],
            @[@"pulse", @"Pulse Ring", kPulseBody],
            @[@"liquid", @"Liquid", kLiquidBody],
            @[@"stars", @"Starfield", kStarsBody],
            @[@"glow", @"Glow Wave", kGlowBody],
            @[@"prism", @"Prism", kPrismBody],
        ];
    });
    return list;
}

static NSArray<NSString *> *builtIn(NSString *identifier) {
    for (NSArray<NSString *> *entry in builtIns()) if ([entry[0] isEqualToString:identifier]) return entry;
    return nil;
}

NSArray<NSString *> *SGRBuiltInShaders(void) {
    NSMutableArray<NSString *> *identifiers = [NSMutableArray array];
    for (NSArray<NSString *> *entry in builtIns()) [identifiers addObject:entry[0]];
    return identifiers;
}

BOOL SGRShaderIsCustom(NSString *identifier) {
    return [identifier hasPrefix:kCustomPrefix];
}

NSString *SGRShaderName(NSString *identifier) {
    if (SGRShaderIsCustom(identifier)) return SGRCustomShaderWithIdentifier(identifier).name;
    return builtIn(identifier)[1];
}

NSString *SGRShaderBody(NSString *identifier) {
    if (SGRShaderIsCustom(identifier)) return SGRCustomShaderWithIdentifier(identifier).body;
    NSArray<NSString *> *entry = builtIn(identifier);
    return entry.count > 2 ? entry[2] : nil;
}

NSString *SGRShaderSourceFor(NSString *body) {
    return [NSString stringWithFormat:@"%@%@%@\n%@", kPrelude, kOpen, body ?: @"", kClose];
}

static NSUInteger lineCount(NSString *text) {
    return [text componentsSeparatedByString:@"\n"].count - 1;
}

NSString *SGRShaderErrorForBody(NSString *message) {
    if (!message.length) return message;
    // The body's first line is the source's line after the prelude and the opening line.
    NSInteger first = (NSInteger)(lineCount(kPrelude) + lineCount(kOpen)) + 1;
    NSRegularExpression *place = [NSRegularExpression regularExpressionWithPattern:@"program_source:(\\d+):(\\d+)" options:0 error:nil];
    NSMutableString *told = [NSMutableString string];
    __block NSUInteger from = 0;
    [place enumerateMatchesInString:message options:0 range:NSMakeRange(0, message.length)
                         usingBlock:^(NSTextCheckingResult *match, NSMatchingFlags flags, BOOL *stop) {
        [told appendString:[message substringWithRange:NSMakeRange(from, match.range.location - from)]];
        NSInteger line = [message substringWithRange:[match rangeAtIndex:1]].integerValue - first + 1;
        NSString *column = [message substringWithRange:[match rangeAtIndex:2]];
        [told appendString:line >= 1 ? [NSString stringWithFormat:@"line %ld:%@", (long)line, column] : @"the prelude"];
        from = NSMaxRange(match.range);
    }];
    [told appendString:[message substringFromIndex:from]];
    return told;
}

NSString *SGRShaderContract(void) {
    return @"Write the body of float4 sgrShade(float2 uv, constant SGRUniforms &u) in Metal: uv runs 0 to 1 from the "
           @"top left; return rgb and alpha, 0 to 1, drawn over the blurred cover. u.time (seconds), u.resolution "
           @"(pixels), u.palette[4] (the cover's colors), u.bands[32] (the spectrum, low first, 0 to 1), u.rms (loudness), "
           @"u.beat (1 on a beat, fading), u.intensity (the slider, 0.25 to 2). Helpers: sgrBand(u, x) reads the "
           @"spectrum at x from 0 to 1, sgrBass(u), sgrMids(u), sgrHighs(u), sgrPalette(u, t) loops through the colors, "
           @"sgrHash(p), sgrNoise(p), sgrFbm(p), sgrCentered(uv, u) is uv about the middle with round circles. Bright "
           @"results are dimmed so the player's text stays readable.";
}

NSString *SGRShaderTemplate(void) {
    return kTemplateBody;
}

#pragma mark - the user's own

@implementation SGRCustomShader

+ (instancetype)shaderWithName:(NSString *)name body:(NSString *)body {
    return [[self alloc] initWithIdentifier:[kCustomPrefix stringByAppendingString:NSUUID.UUID.UUIDString] name:name body:body];
}

- (instancetype)initWithIdentifier:(NSString *)identifier name:(NSString *)name body:(NSString *)body {
    if (!(self = [super init])) return nil;
    _identifier = [identifier copy];
    _name = [name copy];
    _body = [body copy];
    return self;
}

@end

static NSURL *folder(void) {
    NSURL *support = [NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
    return [[support URLByAppendingPathComponent:@"Vitrine" isDirectory:YES] URLByAppendingPathComponent:@"Visualizer" isDirectory:YES];
}

// Read once, then kept up to date by the save and the delete.
static NSMutableArray<SGRCustomShader *> *sg_custom;

static NSMutableArray<SGRCustomShader *> *custom(void) {
    if (sg_custom) return sg_custom;
    sg_custom = [NSMutableArray array];
    NSArray<NSURL *> *files = [NSFileManager.defaultManager contentsOfDirectoryAtURL:folder() includingPropertiesForKeys:nil options:0 error:nil];
    for (NSURL *file in files) {
        NSString *identifier = file.lastPathComponent.stringByDeletingPathExtension;
        if (![file.pathExtension isEqualToString:@"json"] || !SGRShaderIsCustom(identifier)) continue;
        NSData *data = [NSData dataWithContentsOfURL:file];
        NSDictionary *stored = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        if (![stored isKindOfClass:NSDictionary.class] || ![stored[@"name"] isKindOfClass:NSString.class] || ![stored[@"body"] isKindOfClass:NSString.class]) continue;
        [sg_custom addObject:[[SGRCustomShader alloc] initWithIdentifier:identifier name:stored[@"name"] body:stored[@"body"]]];
    }
    return sg_custom;
}

NSArray<SGRCustomShader *> *SGRCustomShaders(void) {
    return [custom() sortedArrayUsingComparator:^NSComparisonResult(SGRCustomShader *a, SGRCustomShader *b) {
        return [a.name localizedStandardCompare:b.name];
    }];
}

SGRCustomShader *SGRCustomShaderWithIdentifier(NSString *identifier) {
    for (SGRCustomShader *shader in custom()) if ([shader.identifier isEqualToString:identifier]) return shader;
    return nil;
}

BOOL SGRSaveCustomShader(SGRCustomShader *shader, NSError **error) {
    if (![NSFileManager.defaultManager createDirectoryAtURL:folder() withIntermediateDirectories:YES attributes:nil error:error]) return NO;
    NSData *data = [NSJSONSerialization dataWithJSONObject:@{@"name": shader.name ?: @"", @"body": shader.body ?: @""}
                                                   options:NSJSONWritingPrettyPrinted error:error];
    NSURL *file = [folder() URLByAppendingPathComponent:[shader.identifier stringByAppendingPathExtension:@"json"]];
    if (!data || ![data writeToURL:file options:NSDataWritingAtomic error:error]) return NO;
    NSMutableArray<SGRCustomShader *> *list = custom();
    SGRCustomShader *stored = SGRCustomShaderWithIdentifier(shader.identifier);
    if (stored) [list replaceObjectAtIndex:[list indexOfObject:stored] withObject:shader];
    else [list addObject:shader];
    return YES;
}

BOOL SGRDeleteCustomShader(NSString *identifier) {
    SGRCustomShader *stored = SGRCustomShaderWithIdentifier(identifier);
    if (!stored) return NO;
    NSURL *file = [folder() URLByAppendingPathComponent:[identifier stringByAppendingPathExtension:@"json"]];
    NSError *error = nil;
    if (![NSFileManager.defaultManager removeItemAtURL:file error:&error] && error.code != NSFileNoSuchFileError) return NO;
    [custom() removeObject:stored];
    return YES;
}
