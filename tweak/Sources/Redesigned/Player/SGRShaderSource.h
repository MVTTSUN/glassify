// The Visualizer's shaders (PlayerVisualiser.m): the built-in ones and the user's own, and the Metal source each
// is compiled from at runtime (SGRShaderView.h). Plain Foundation, so harness/visualiser/ compiles and draws
// every one of them on the Mac.
//
// The contract: a shader is the body of a function
//
//     float4 sgrShade(float2 uv, constant SGRUniforms &u)
//
// uv runs 0..1 from the top left of the player; it returns a color, rgb 0..1 and its alpha, over the Fluid field
// held still. u carries what SGRShaderUniforms does below, and the helpers of the prelude may be called: sgrBand,
// sgrBass, sgrMids, sgrHighs, sgrPalette, sgrHash, sgrNoise, sgrFbm, sgrCentered (SGRShaderContract says each). The
// result is held under a brightness ceiling, so white text keeps its contrast whatever a shader does.
//
// The user's own are kept one JSON file each ({"name", "body"}) in Application Support/Vitrine/Visualizer, named
// by their identifier, "custom.<UUID>".
//
// Threading: main thread only, but for SGRShaderSourceFor and the error mapping, which are pure.
#import <Foundation/Foundation.h>
#import <simd/simd.h>

// What the fragment function is handed, laid out as Metal lays out SGRUniforms: 224 bytes.
typedef struct {
    float time;                // seconds, wrapping each hour
    simd_float2 resolution;    // the drawable, in pixels
    simd_float4 palette[4];    // the cover's colors, rgb 0..1
    float bands[32];           // the spectrum, 30 Hz to 16 kHz evenly in pitch, each 0..1
    float rms;                 // the loudness, 0..1
    float beat;                // 1 on a beat, decaying to 0 within half a second
    float intensity;           // the Intensity slider, 0.25..2
    float ceiling;             // the brightest the result may be, as relative luminance
} SGRShaderUniforms;

// Hills, the Visualizer before shaders: drawn by Core Animation, not by a shader.
extern NSString *const SGRShaderHills;
// The built-in ones, Hills first, in the picker's order.
NSArray<NSString *> *SGRBuiltInShaders(void);
BOOL SGRShaderIsCustom(NSString *identifier);
// A shader's name, built in or the user's; nil for one that is not there (a custom one deleted).
NSString *SGRShaderName(NSString *identifier);
// A shader's body, built in or the user's; nil for Hills and for one that is not there.
NSString *SGRShaderBody(NSString *identifier);
// The whole Metal source for a body: the prelude, the body as sgrShade, and the fragment function that caps it.
NSString *SGRShaderSourceFor(NSString *body);
// A compiler message about SGRShaderSourceFor(body), its "program_source:LINE:COLUMN" told as the body's own lines.
NSString *SGRShaderErrorForBody(NSString *message);
// What a body may use, for the editor's header.
NSString *SGRShaderContract(void);
// The body a new shader starts from.
NSString *SGRShaderTemplate(void);

@interface SGRCustomShader : NSObject
@property (nonatomic, copy, readonly) NSString *identifier;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *body;
// A new one, not stored until SGRSaveCustomShader.
+ (instancetype)shaderWithName:(NSString *)name body:(NSString *)body;
@end

// The user's own, by name.
NSArray<SGRCustomShader *> *SGRCustomShaders(void);
SGRCustomShader *SGRCustomShaderWithIdentifier(NSString *identifier);
BOOL SGRSaveCustomShader(SGRCustomShader *shader, NSError **error);
BOOL SGRDeleteCustomShader(NSString *identifier);
