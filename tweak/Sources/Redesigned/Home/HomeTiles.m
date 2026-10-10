// Home redesign: a shortcut tile the way an Apple list row holds artwork. The cover sits inset from the tile's
// edges with its own corners, the title follows it in, and the tile sits on glass tinted by its cover: on iOS 26 with
// Shortcuts on glass on (SGRKeyHomeGlassShortcuts) and Reduce Transparency off, Liquid Glass (UIGlassEffect, the
// regular style) whose tint is the cover's average color (HomeCoverColor.x), its saturation lifted a little and its
// luminance held to kGlassLuminance at kGlassTintAlpha, so the grid is not one gray and the white title keeps its
// contrast; else a dark surface tinted faintly toward the cover's dominant color (Kit/SGRPalette.h, +tintForImage:).
// Until the cover has loaded, the tile is plain glass or the untinted surface.
//
// The glass or the surface sits behind Spotify's stack, so the title, the playing indicator and the button's
// touches stay Spotify's; under the glass the tile's own white fill goes transparent, as the glass is the tile's
// surface. The inset and the title's move are transforms, which Spotify's layout never reads, so its constraints are
// left as they are. The color is worked out off the main thread once per picture (once per URL for the glass) and
// follows the cover as Spotify sets it (SGRObserveImage), since a cover lands after layout. The glass and the surface
// are made once per tile and kept across reuse; a new glass effect is made only when the color changes.
//
// Tree (trees/home 3 more scrolled.txt:36-50, 2026-09-17): InteractableLayoutBackingButton id=Shortcut.Card.Home
// 181x48 clips > UIView 181x48 bg=#FFFFFF@0.10 (the fill), then Encore.StackView > AutoLayoutStackView >
// UIView 173x48 (the row) > UIView {0, 0} 48x48 bg=#000000@0.90 r=4 (the cover's square) > Encore.ImageView >
// UIImageView 48x48 and the PlaceholderView; then the row's 8pt spacer and the title's stack at x 56.
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Home.h"

// How far the cover sits in from the tile's top, bottom and leading edges, and its corners there.
static const CGFloat kInset = 5, kCoverRadius = 4;

// The glass's tint: the cover's average color, its saturation lifted by kGlassSaturation and its luminance held to
// kGlassLuminance, at kGlassTintAlpha.
static const CGFloat kGlassSaturation = 1.2, kGlassLuminance = 0.18, kGlassTintAlpha = 0.6;

static char kSurfaceKey, kImageKey, kShownKey, kGlassKey, kTintKey, kModeKey, kFillKey;

// Read at launch, like every switch; Reduce Transparency is read on every pass, as it can change while Spotify runs.
static BOOL glassOn(void) {
    static int state = -1;
    if (state < 0) {
        state = 0;
        if (@available(iOS 26.0, *)) state = SGEnabled(SGRKeyHomeGlassShortcuts) ? 1 : 0;
    }
    return state == 1 && !SGRReduceTransparency();
}

// Tints already worked out, by the image object while it lives (main thread only).
static NSMapTable<UIImage *, UIColor *> *tints(void) {
    static NSMapTable *table;
    if (!table) table = [NSMapTable weakToStrongObjectsMapTable];
    return table;
}

static UIColor *untinted(void) {
    static UIColor *color;
    if (!color) color = SGRElevated(UIColor.blackColor);
    return color;
}

@interface SGRTileParts : NSObject
@property (nonatomic, weak) UIView *fill;
@property (nonatomic, weak) UIView *square;
@property (nonatomic, weak) UIImageView *cover;
@end

@implementation SGRTileParts
@end

static SGRTileParts *partsOf(UIView *tile) {
    UIView *holder = SGRFindByIdentifier(tile, @"Encore.ImageView", &kImageKey);
    SGRTileParts *parts = [SGRTileParts new];
    for (UIView *sub in holder.subviews) {
        if ([sub isKindOfClass:UIImageView.class]) parts.cover = (UIImageView *)sub;
    }
    parts.square = holder.superview;
    UIView *first = tile.subviews.firstObject;
    if (object_getClass(first) == UIView.class && CGRectEqualToRect(first.frame, tile.bounds)) parts.fill = first;
    return parts;
}

static UIView *surfaceIn(UIView *tile, UIView *fill) {
    UIView *surface = objc_getAssociatedObject(tile, &kSurfaceKey);
    if (!surface) {
        surface = [UIView new];
        surface.userInteractionEnabled = NO;
        surface.accessibilityElementsHidden = YES;
        surface.backgroundColor = untinted();
        objc_setAssociatedObject(tile, &kSurfaceKey, surface, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (surface.superview != tile) {
        if (fill) [tile insertSubview:surface aboveSubview:fill];
        else [tile insertSubview:surface atIndex:0];
    }
    if (!CGRectEqualToRect(surface.frame, tile.bounds)) surface.frame = tile.bounds;
    return surface;
}

// The square scaled about its center so it clears the tile's edges by kInset, and everything after it in the
// row moved in by what that took off its trailing side.
static void inset(UIView *square) {
    CGFloat side = square.bounds.size.height;
    if (side <= kInset * 4) return;
    CGFloat scale = (side - kInset * 2) / side;
    CGAffineTransform shrink = CGAffineTransformMakeScale(scale, scale);
    if (!CGAffineTransformEqualToTransform(square.transform, shrink)) square.transform = shrink;
    CALayer *layer = square.layer;
    // The radius is drawn scaled with the square.
    CGFloat radius = kCoverRadius / scale;
    if (layer.cornerRadius != radius) layer.cornerRadius = radius;
    if (layer.cornerCurve != kCACornerCurveContinuous) layer.cornerCurve = kCACornerCurveContinuous;
    if (!layer.masksToBounds) layer.masksToBounds = YES;

    CGAffineTransform follow = CGAffineTransformMakeTranslation(-square.bounds.size.width * (1 - scale) / 2, 0);
    BOOL after = NO;
    for (UIView *sibling in square.superview.subviews) {
        if (sibling == square) {
            after = YES;
            continue;
        }
        if (after && !CGAffineTransformEqualToTransform(sibling.transform, follow)) sibling.transform = follow;
    }
}

static void tint(UIView *tile, UIView *surface, UIColor *color, BOOL animated) {
    color = color ?: untinted();
    if ([surface.backgroundColor isEqual:color]) return;
    if (!animated || !tile.window) {
        surface.backgroundColor = color;
        return;
    }
    SGRAnimate(SGRMotionFade, ^{ surface.backgroundColor = color; }, nil);
}

static UIColor *glassTint(UIColor *average) {
    if (!average) return nil;
    CGFloat hue = 0, saturation = 0, brightness = 0, alpha = 1;
    if ([average getHue:&hue saturation:&saturation brightness:&brightness alpha:&alpha]) {
        average = [UIColor colorWithHue:hue saturation:MIN(1, saturation * kGlassSaturation) brightness:brightness alpha:1];
    }
    return [SGRHomeDarkened(average, kGlassLuminance) colorWithAlphaComponent:kGlassTintAlpha];
}

static UIVisualEffectView *glassIn(UIView *tile) {
    UIVisualEffectView *glass = objc_getAssociatedObject(tile, &kGlassKey);
    if (!glass) {
        glass = [UIVisualEffectView new];
        // Dark like every glass of the redesign's, whatever the system appearance (Search/SearchCards.x).
        glass.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
        glass.userInteractionEnabled = NO;
        glass.accessibilityElementsHidden = YES;
        SGShapeGlass(glass, SGRRadiusCover, NO);
        objc_setAssociatedObject(tile, &kGlassKey, glass, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (glass.superview != tile) [tile insertSubview:glass atIndex:0];
    if (glass.hidden) glass.hidden = NO;
    if (!CGRectEqualToRect(glass.frame, tile.bounds)) glass.frame = tile.bounds;
    return glass;
}

// The glass tinted `color` (nil: untinted); a new effect only when the tint changes.
static void tintGlass(UIView *tile, UIVisualEffectView *glass, UIColor *color, BOOL animated) {
    UIColor *tint = glassTint(color);
    UIColor *current = objc_getAssociatedObject(tile, &kTintKey);
    BOOL same = tint ? (current && CGColorEqualToColor(current.CGColor, tint.CGColor)) : (!current && glass.effect);
    if (same) return;
    objc_setAssociatedObject(tile, &kTintKey, tint, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (@available(iOS 26.0, *)) {
        UIGlassEffect *effect = [UIGlassEffect effectWithStyle:UIGlassEffectStyleRegular];
        effect.tintColor = tint;
        if (!animated || !tile.window) {
            glass.effect = effect;
            return;
        }
        SGRAnimate(SGRMotionFade, ^{ glass.effect = effect; }, nil);
    }
}

// The tile's white fill goes transparent under the glass, and comes back with the surface.
static void showFill(UIView *tile, UIView *fill, BOOL shown) {
    if (!fill) return;
    if (!shown) {
        if (fill.alpha != 0) fill.alpha = 0;
        objc_setAssociatedObject(tile, &kFillKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } else if (objc_getAssociatedObject(tile, &kFillKey)) {
        fill.alpha = 1;
        objc_setAssociatedObject(tile, &kFillKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

static void refreshGlass(UIView *tile, SGRTileParts *parts) {
    UIVisualEffectView *glass = glassIn(tile);
    showFill(tile, parts.fill, NO);
    UIView *surface = objc_getAssociatedObject(tile, &kSurfaceKey);
    if (surface && !surface.hidden) surface.hidden = YES;

    UIImage *image = parts.cover.image;
    if (!image) {
        objc_setAssociatedObject(tile, &kShownKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        tintGlass(tile, glass, nil, NO);
        return;
    }
    // Asked already: the tint is on the glass, or on its way.
    if (objc_getAssociatedObject(tile, &kShownKey) == image) return;
    objc_setAssociatedObject(tile, &kShownKey, image, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    __weak UIView *weakTile = tile;
    UIColor *known = SGRHomeCoverColor(image, ^(UIColor *color) {
        UIView *strongTile = weakTile;
        // A tile reused for another cover in the meantime has asked for that one.
        if (!strongTile || objc_getAssociatedObject(strongTile, &kShownKey) != image || !glassOn()) return;
        tintGlass(strongTile, glassIn(strongTile), color, YES);
    });
    if (known) tintGlass(tile, glass, known, YES);
}

static void refresh(UIView *tile) {
    SGRTileParts *parts = partsOf(tile);
    UIImageView *cover = parts.cover;
    UIView *square = parts.square;
    if (!cover || !square || square.bounds.size.width < 20 || tile.bounds.size.width <= square.bounds.size.width) return;
    inset(square);

    // A change between the glass and the surface (Reduce Transparency) paints the tile again from its cover.
    BOOL glassy = glassOn();
    NSNumber *mode = objc_getAssociatedObject(tile, &kModeKey);
    if (!mode || mode.boolValue != glassy) {
        objc_setAssociatedObject(tile, &kModeKey, @(glassy), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(tile, &kShownKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (glassy) {
        refreshGlass(tile, parts);
        return;
    }
    UIVisualEffectView *glass = objc_getAssociatedObject(tile, &kGlassKey);
    if (glass && !glass.hidden) glass.hidden = YES;
    showFill(tile, parts.fill, YES);
    UIView *surface = surfaceIn(tile, parts.fill);
    if (surface.hidden) surface.hidden = NO;

    UIImage *image = cover.image;
    if (!image) {
        objc_setAssociatedObject(tile, &kShownKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        tint(tile, surface, nil, NO);
        return;
    }
    UIColor *known = [tints() objectForKey:image];
    if (known) {
        objc_setAssociatedObject(tile, &kShownKey, image, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        tint(tile, surface, known, YES);
        return;
    }
    if (objc_getAssociatedObject(tile, &kShownKey) == image) return;
    objc_setAssociatedObject(tile, &kShownKey, image, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    __weak UIView *weakTile = tile;
    [SGRPalette tintForImage:image surface:untinted() completion:^(UIColor *color) {
        UIView *strongTile = weakTile;
        if (color) [tints() setObject:color forKey:image];
        // A tile reused for another cover in the meantime has asked for that one.
        if (!strongTile || objc_getAssociatedObject(strongTile, &kShownKey) != image) return;
        tint(strongTile, surfaceIn(strongTile, partsOf(strongTile).fill), color, YES);
    }];
}

void SGRHomeStyleTile(UIView *tile) {
    CFTimeInterval began = SGRHomeProbeBegin();
    UIImageView *cover = partsOf(tile).cover;
    if (!cover) return;
    __weak UIView *weakTile = tile;
    // The block is replaced on every pass, so a cover taken into another tile tells the tile it is in now.
    SGRObserveImage(cover, ^(UIImageView *view) {
        UIView *strongTile = weakTile;
        if (strongTile && [view isDescendantOfView:strongTile]) refresh(strongTile);
    });
    refresh(tile);
    SGRHomeProbeEnd(SGRHomeProbeTiles, began);
}
