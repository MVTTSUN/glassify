// The Visualizer's shaders (Redesigned/Player/SGRShaderSource.m, as the tweak compiles it) on the Mac: every
// built-in body and the template compiled through Metal's runtime compiler, as the player compiles them with
// newLibraryWithSource:, each drawn once into build/<name>.png at a phone's half resolution with a made-up song,
// and a broken body's error told at its own line. Each check is printed with ok or WRONG.
//
//     ./build.sh && build/shaders
#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>
#import <Metal/Metal.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import "Redesigned/Player/SGRShaderSource.h"

static int checks, right;

static void check(BOOL ok, NSString *what) {
    checks++;
    right += ok;
    printf("%s  %s\n", ok ? "ok   " : "WRONG", what.UTF8String);
}

static id<MTLRenderPipelineState> pipeline(id<MTLDevice> device, NSString *body, NSString **message) {
    NSError *error = nil;
    id<MTLLibrary> library = [device newLibraryWithSource:SGRShaderSourceFor(body) options:nil error:&error];
    *message = error.localizedDescription;
    if (!library) return nil;
    MTLRenderPipelineDescriptor *descriptor = [MTLRenderPipelineDescriptor new];
    descriptor.vertexFunction = [library newFunctionWithName:@"sgr_vertex"];
    descriptor.fragmentFunction = [library newFunctionWithName:@"sgr_fragment"];
    descriptor.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    return [device newRenderPipelineStateWithDescriptor:descriptor error:&error];
}

// A frame of a loud passage on a beat, in the colors of a dark blue and purple cover, over the Fluid field's gray;
// answers the brightest relative luminance drawn.
static double draw(id<MTLDevice> device, id<MTLRenderPipelineState> state, NSString *name) {
    const NSUInteger width = 295, height = 640;
    MTLTextureDescriptor *descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:width height:height mipmapped:NO];
    descriptor.usage = MTLTextureUsageRenderTarget;
    descriptor.storageMode = MTLStorageModeShared;
    id<MTLTexture> texture = [device newTextureWithDescriptor:descriptor];
    SGRShaderUniforms u = {0};
    u.time = 12.5f;
    u.resolution = simd_make_float2(width, height);
    u.palette[0] = simd_make_float4(0.10f, 0.16f, 0.36f, 1);
    u.palette[1] = simd_make_float4(0.28f, 0.12f, 0.36f, 1);
    u.palette[2] = simd_make_float4(0.08f, 0.26f, 0.30f, 1);
    u.palette[3] = simd_make_float4(0.30f, 0.18f, 0.12f, 1);
    for (int i = 0; i < 32; i++) u.bands[i] = 0.35f + 0.6f * expf(-i / 9.0f) * (0.6f + 0.4f * sinf(i * 1.3f));
    u.rms = 0.7f;
    u.beat = 0.8f;
    u.intensity = 1;
    u.ceiling = 0.14f;
    id<MTLCommandQueue> queue = [device newCommandQueue];
    id<MTLCommandBuffer> buffer = [queue commandBuffer];
    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = texture;
    pass.colorAttachments[0].loadAction = MTLLoadActionDontCare;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> encoder = [buffer renderCommandEncoderWithDescriptor:pass];
    [encoder setRenderPipelineState:state];
    [encoder setFragmentBytes:&u length:sizeof u atIndex:0];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [encoder endEncoding];
    [buffer commit];
    [buffer waitUntilCompleted];

    // Premultiplied BGRA over the field's gray, as the layer is composited.
    NSMutableData *pixels = [NSMutableData dataWithLength:width * height * 4];
    [texture getBytes:pixels.mutableBytes bytesPerRow:width * 4 fromRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0];
    uint8_t *p = pixels.mutableBytes;
    double brightest = 0;
    for (NSUInteger i = 0; i < width * height; i++, p += 4) {
        double a = p[3] / 255.0, light = 0;
        for (int c = 0; c < 3; c++) {
            double v = p[c] / 255.0 + 0.12 * (1 - a);
            p[c] = (uint8_t)lround(fmin(1, v) * 255);
            double weight = c == 0 ? 0.0722 : c == 1 ? 0.7152 : 0.2126;
            light += weight * pow(v, 2.2);
        }
        p[3] = 255;
        brightest = fmax(brightest, light);
    }
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef context = CGBitmapContextCreate(pixels.mutableBytes, width, height, 8, width * 4, space,
                                                 kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    CGImageRef image = CGBitmapContextCreateImage(context);
    NSURL *url = [NSURL fileURLWithPath:[NSString stringWithFormat:@"build/%@.png", name]];
    CGImageDestinationRef file = CGImageDestinationCreateWithURL((__bridge CFURLRef)url, (__bridge CFStringRef)UTTypePNG.identifier, 1, NULL);
    CGImageDestinationAddImage(file, image, NULL);
    CGImageDestinationFinalize(file);
    CFRelease(file);
    CGImageRelease(image);
    CGContextRelease(context);
    CGColorSpaceRelease(space);
    return brightest;
}

int main(void) {
    @autoreleasepool {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (!device) {
            printf("no Metal device\n");
            return 1;
        }
        NSMutableArray<NSString *> *names = [SGRBuiltInShaders() mutableCopy];
        [names removeObject:SGRShaderHills];
        check(names.count >= 6 && !SGRShaderBody(SGRShaderHills), @"six built-in shaders besides Hills, which has no body");
        [names addObject:@"template"];
        for (NSString *name in names) {
            NSString *message = nil;
            NSString *body = [name isEqualToString:@"template"] ? SGRShaderTemplate() : SGRShaderBody(name);
            id<MTLRenderPipelineState> state = pipeline(device, body, &message);
            double brightest = state ? draw(device, state, name) : 1;
            check(state && brightest <= 0.145, [NSString stringWithFormat:@"%@ compiles%@ and draws at most %.3f (ceiling 0.14 over the field)",
                                                 SGRShaderName(name) ?: name, message ? [@", with: " stringByAppendingString:message] : @"", brightest]);
        }
        NSString *message = nil;
        id<MTLRenderPipelineState> broken = pipeline(device, @"float2 p = uv;\nreturn float4(p, missing, 1.0);", &message);
        NSString *told = SGRShaderErrorForBody(message);
        check(!broken && [told containsString:@"line 2:"] && ![told containsString:@"program_source"],
              [NSString stringWithFormat:@"a broken body's error at its own line: %@", [told componentsSeparatedByString:@"\n"].firstObject]);
        printf("shader checks: %d of %d right -- %s\n", right, checks, right == checks ? "PASS" : "FAIL");
        return right == checks ? 0 : 1;
    }
}
