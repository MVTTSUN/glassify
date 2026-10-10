// The Visualizer's Metal view (SGRShaderView.h).
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import "Core/SGCore.h"
#import "SGRShaderView.h"

static id<MTLDevice> device(void) {
    static id<MTLDevice> shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = MTLCreateSystemDefaultDevice(); });
    return shared;
}

static id<MTLCommandQueue> queue(void) {
    static id<MTLCommandQueue> shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [device() newCommandQueue]; });
    return shared;
}

#pragma mark - compiling

typedef void (^SGRPipelineDone)(id<MTLRenderPipelineState> pipeline, NSString *error);

// By source: a pipeline, or the error it gave (an NSString). And the callers waiting on one being compiled.
static NSMutableDictionary<NSString *, id> *sg_compiled;
static NSMutableDictionary<NSString *, NSMutableArray<SGRPipelineDone> *> *sg_waiting;

static void finish(NSString *source, id<MTLRenderPipelineState> pipeline, NSString *error) {
    dispatch_async(dispatch_get_main_queue(), ^{
        sg_compiled[source] = pipeline ?: (id)(error ?: @"The shader did not compile.");
        NSArray<SGRPipelineDone> *waiting = sg_waiting[source];
        [sg_waiting removeObjectForKey:source];
        for (SGRPipelineDone done in waiting) done(pipeline, pipeline ? nil : sg_compiled[source]);
    });
}

static void pipelineFor(NSString *source, SGRPipelineDone done) {
    if (!sg_compiled) {
        sg_compiled = [NSMutableDictionary dictionary];
        sg_waiting = [NSMutableDictionary dictionary];
    }
    id compiled = sg_compiled[source];
    if (compiled) {
        BOOL failed = [compiled isKindOfClass:NSString.class];
        done(failed ? nil : compiled, failed ? compiled : nil);
        return;
    }
    if (sg_waiting[source]) {
        [sg_waiting[source] addObject:done];
        return;
    }
    sg_waiting[source] = [NSMutableArray arrayWithObject:done];
    id<MTLDevice> gpu = device();
    if (!gpu) {
        finish(source, nil, @"Metal is not available on this iPhone.");
        return;
    }
    [gpu newLibraryWithSource:source options:nil completionHandler:^(id<MTLLibrary> library, NSError *error) {
        id<MTLFunction> vertex = [library newFunctionWithName:@"sgr_vertex"], fragment = [library newFunctionWithName:@"sgr_fragment"];
        if (!vertex || !fragment) {
            finish(source, nil, SGRShaderErrorForBody(error.localizedDescription));
            return;
        }
        MTLRenderPipelineDescriptor *descriptor = [MTLRenderPipelineDescriptor new];
        descriptor.vertexFunction = vertex;
        descriptor.fragmentFunction = fragment;
        descriptor.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
        [gpu newRenderPipelineStateWithDescriptor:descriptor completionHandler:^(id<MTLRenderPipelineState> pipeline, NSError *failure) {
            finish(source, pipeline, failure.localizedDescription);
        }];
    }];
}

void SGRCompileShaderBody(NSString *body, void (^done)(NSString *error)) {
    pipelineFor(SGRShaderSourceFor(body), ^(id<MTLRenderPipelineState> pipeline, NSString *error) { done(error); });
}

#pragma mark - the view

// Shaders the GPU gave up on this launch, never drawn again until Spotify restarts.
static NSMutableSet<NSString *> *sg_broken;

@implementation SGRShaderView {
    id<MTLRenderPipelineState> _pipeline;
    NSUInteger _request;   // which shader the pipeline being waited on is for
    NSInteger _inFlight;
    CGSize _drawableSize;
}

+ (Class)layerClass {
    return CAMetalLayer.class;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.userInteractionEnabled = NO;
    self.backgroundColor = UIColor.clearColor;
    _renderScale = 0.5;
    CAMetalLayer *layer = (CAMetalLayer *)self.layer;
    layer.device = device();
    layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
    layer.framebufferOnly = YES;
    layer.opaque = NO;
    layer.maximumDrawableCount = 3;
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    layer.colorspace = space;
    CGColorSpaceRelease(space);
    return self;
}

- (BOOL)ready {
    return _pipeline != nil;
}

- (void)setShader:(NSString *)shader {
    if ([shader isEqualToString:_shader]) return;
    _shader = [shader copy];
    _pipeline = nil;
    NSUInteger request = ++_request;
    NSString *body = SGRShaderBody(shader);
    if (!body || [sg_broken containsObject:shader]) {
        if (self.failed) self.failed(body ? @"The GPU stopped this shader." : @"The shader is not there.");
        return;
    }
    __weak SGRShaderView *weakSelf = self;
    pipelineFor(SGRShaderSourceFor(body), ^(id<MTLRenderPipelineState> pipeline, NSString *error) {
        SGRShaderView *view = weakSelf;
        if (!view || request != view->_request) return;
        if (!pipeline) {
            SGLog(@"redesign player: visualizer shader %@ did not compile: %@", shader, error);
            if (view.failed) view.failed(error);
            return;
        }
        view->_pipeline = pipeline;
        if (view.arrived) view.arrived();
    });
}

- (void)setRenderScale:(CGFloat)renderScale {
    if (renderScale == _renderScale) return;
    _renderScale = renderScale;
    [self setNeedsLayout];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat scale = (self.traitCollection.displayScale ?: 2) * _renderScale;
    CGSize size = CGSizeMake(MAX(1, round(self.bounds.size.width * scale)), MAX(1, round(self.bounds.size.height * scale)));
    if (CGSizeEqualToSize(size, _drawableSize)) return;
    _drawableSize = size;
    ((CAMetalLayer *)self.layer).drawableSize = size;
}

- (void)render:(SGRShaderUniforms)uniforms {
    if (!_pipeline || _inFlight >= 2 || self.bounds.size.width <= 0 || !self.window) return;
    if (UIApplication.sharedApplication.applicationState == UIApplicationStateBackground) return;
    CAMetalLayer *layer = (CAMetalLayer *)self.layer;
    id<CAMetalDrawable> drawable = [layer nextDrawable];
    if (!drawable) return;
    uniforms.resolution = simd_make_float2((float)_drawableSize.width, (float)_drawableSize.height);
    id<MTLCommandBuffer> buffer = [queue() commandBuffer];
    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = drawable.texture;
    pass.colorAttachments[0].loadAction = MTLLoadActionDontCare;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> encoder = [buffer renderCommandEncoderWithDescriptor:pass];
    [encoder setRenderPipelineState:_pipeline];
    [encoder setFragmentBytes:&uniforms length:sizeof uniforms atIndex:0];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [encoder endEncoding];
    [buffer presentDrawable:drawable];
    _inFlight++;
    __weak SGRShaderView *weakSelf = self;
    NSString *shader = _shader;
    NSUInteger request = _request;
    [buffer addCompletedHandler:^(id<MTLCommandBuffer> done) {
        BOOL failed = done.status == MTLCommandBufferStatusError;
        NSString *reason = done.error.localizedDescription;
        dispatch_async(dispatch_get_main_queue(), ^{
            SGRShaderView *view = weakSelf;
            if (view) view->_inFlight--;
            // A shader that runs past the GPU's watchdog is a custom one gone wrong: given up for the launch.
            if (!failed || !view || request != view->_request) return;
            SGLog(@"redesign player: the GPU stopped visualizer shader %@: %@", shader, reason);
            if (!sg_broken) sg_broken = [NSMutableSet set];
            [sg_broken addObject:shader];
            view->_pipeline = nil;
            if (view.failed) view.failed(reason ?: @"The GPU stopped this shader.");
        });
    }];
    [buffer commit];
}

@end
