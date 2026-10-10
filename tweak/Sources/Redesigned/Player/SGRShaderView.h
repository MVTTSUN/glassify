// A view drawing one of the Visualizer's shaders (SGRShaderSource.h) with Metal, for PlayerVisualiser.m: a
// CAMetalLayer, transparent, drawn at a share of the screen's pixels and stretched to its bounds.
//
// Each source is compiled once a launch, off the main thread (newLibraryWithSource: and the pipeline both with a
// completion handler), and kept, its error too, so a broken one is not compiled again. Nothing is drawn but by
// -render:, never in the background (iOS refuses a background app's GPU work), and a frame is skipped rather than
// waited for while two are still on the GPU, so the main thread never blocks on a drawable.
//
// Threading: main thread only.
#import <UIKit/UIKit.h>
#import "SGRShaderSource.h"

@interface SGRShaderView : UIView
// The shader drawn, by identifier. A change compiles it, keeping the last frame until it is in.
@property (nonatomic, copy) NSString *shader;
// The share of the screen's pixels drawn, 0.5 unless set.
@property (nonatomic) CGFloat renderScale;
// The pipeline is in: -render: draws from now on.
@property (nonatomic, readonly) BOOL ready;
// Runs once the shader's pipeline is in, so the owner can draw a first frame.
@property (nonatomic, copy) void (^arrived)(void);
// Runs when the shader cannot be drawn: it did not compile, or the GPU gave up on it (a custom one that runs too
// long). The view draws nothing more of it.
@property (nonatomic, copy) void (^failed)(NSString *error);
// Draws a frame now; `resolution` is filled in here.
- (void)render:(SGRShaderUniforms)uniforms;
@end

// Compiles `body` as the view would, calling back on the main queue with nil, or the compiler's message told at
// the body's own lines.
void SGRCompileShaderBody(NSString *body, void (^done)(NSString *error));
