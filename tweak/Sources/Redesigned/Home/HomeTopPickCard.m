// Home redesign: a card of the Top picks shelf (HomeTopPicks.x) the way the Music app draws one of its Top Picks: the
// square cover at the top, dissolving at its foot into the cover's own color, which runs on down the card, and the
// title and subtitle on that color, white and white 65%. The color is the cover's average (HomeCoverColor.x) with its
// luminance held to kLuminanceCeiling, so the white title keeps 7:1 on any cover; until the cover has been read the
// card is the Kit's elevated surface, and the color fades in.
//
// The card stays Spotify's button (id=Components.UI.HomeCard): what is drawn here is a face over it that takes no
// touches and is hidden from accessibility, so a tap, a press and VoiceOver are the card's own. The face covers the
// card's own labels with its color rather than touching them, and is made once per card and kept across reuse:
// a card scrolled into a shelf that is not Top picks has its face hidden.
//
// Tree (HomeCards.x, trees/clean/home/10.txt:2280-2286): InteractableLayoutBackingButton id=Components.UI.HomeCard
// 149x195 > ... Encore.ImageView 149x149 at the card's top > UIImageView; the title and subtitle labels under it.
// Drawn large the card is 253x332 and its picture 253x253.
#import <QuartzCore/QuartzCore.h>
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Home.h"

// The face's colour is held to this luminance: white on it is 7:1.
static const CGFloat kLuminanceCeiling = 0.10;
// The text's inset from the card's edges, and the gap between the title and the subtitle.
static const CGFloat kTextInset = 12, kTextGap = 2;
// How far up the cover the color reaches, as a share of the cover's height.
static const CGFloat kFadeShare = 0.4;

static char kFaceKey, kImageKey;

@interface SGRTopPickFace : UIView
@property (nonatomic) CGFloat artBottom;
@property (nonatomic, weak) UIImage *image;
@property (nonatomic, readonly) UILabel *title;
@property (nonatomic, readonly) UILabel *subtitle;
- (void)setColor:(UIColor *)color animated:(BOOL)animated;
- (void)applyFonts;
@end

@implementation SGRTopPickFace {
    CAGradientLayer *_fade;
    CALayer *_panel;
    UIColor *_color;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.userInteractionEnabled = NO;
    self.accessibilityElementsHidden = YES;
    self.clipsToBounds = YES;
    self.layer.cornerRadius = SGRRadiusCard;
    self.layer.cornerCurve = kCACornerCurveContinuous;
    _fade = [CAGradientLayer layer];
    _fade.locations = @[@0, @0.55, @1];
    _panel = [CALayer layer];
    [self.layer addSublayer:_fade];
    [self.layer addSublayer:_panel];
    _title = [UILabel new];
    _title.textColor = SGRPrimary();
    _title.lineBreakMode = NSLineBreakByTruncatingTail;
    _subtitle = [UILabel new];
    _subtitle.textColor = SGRSecondary();
    _subtitle.numberOfLines = 2;
    _subtitle.lineBreakMode = NSLineBreakByTruncatingTail;
    [self addSubview:_title];
    [self addSubview:_subtitle];
    [self applyFonts];
    [self setColor:nil animated:NO];
    return self;
}

- (void)applyFonts {
    self.title.font = SGRFont(UIFontTextStyleHeadline, UIFontWeightBold, UIContentSizeCategoryExtraExtraLarge);
    self.subtitle.font = SGRFont(UIFontTextStyleSubheadline, UIFontWeightRegular, UIContentSizeCategoryExtraExtraLarge);
    [self setNeedsLayout];
}

- (void)setColor:(UIColor *)color animated:(BOOL)animated {
    color = color ? SGRHomeDarkened(color, kLuminanceCeiling) : SGRElevated(UIColor.blackColor);
    if (_color && CGColorEqualToColor(_color.CGColor, color.CGColor)) return;
    _color = color;
    [CATransaction begin];
    // Stand-alone layers fade their colors on their own; a card drawn for the first time or off screen takes it at once.
    [CATransaction setDisableActions:!animated || !self.window];
    [CATransaction setAnimationDuration:SGRCrossfade];
    _fade.colors = @[(id)[color colorWithAlphaComponent:0].CGColor, (id)[color colorWithAlphaComponent:0.7].CGColor, (id)color.CGColor];
    _panel.backgroundColor = color.CGColor;
    [CATransaction commit];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGSize size = self.bounds.size;
    CGFloat width = MAX(0, size.width - kTextInset * 2);
    CGSize subtitle = self.subtitle.text.length ? [self.subtitle sizeThatFits:CGSizeMake(width, CGFLOAT_MAX)] : CGSizeZero;
    CGSize title = [self.title sizeThatFits:CGSizeMake(width, CGFLOAT_MAX)];
    CGFloat y = size.height - kTextInset - ceil(subtitle.height);
    self.subtitle.frame = CGRectMake(kTextInset, y, width, ceil(subtitle.height));
    y -= ceil(title.height) + (subtitle.height > 0 ? kTextGap : 0);
    self.title.frame = CGRectMake(kTextInset, y, width, ceil(title.height));

    // The color reaches up the cover, and further when the text does, so the text always sits on it.
    CGFloat bottom = MIN(MAX(self.artBottom, 0), size.height);
    CGFloat top = MAX(0, MIN(bottom - bottom * kFadeShare, y - kTextInset * 2));
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _fade.frame = CGRectMake(0, top, size.width, MAX(0, bottom - top));
    _panel.frame = CGRectMake(0, bottom, size.width, MAX(0, size.height - bottom));
    [CATransaction commit];
}

- (void)traitCollectionDidChange:(UITraitCollection *)previous {
    [super traitCollectionDidChange:previous];
    if ([previous.preferredContentSizeCategory isEqualToString:self.traitCollection.preferredContentSizeCategory]) return;
    [self applyFonts];
}
@end

static BOOL shown(UIView *view, UIView *root) {
    for (UIView *v = view; v && v != root; v = v.superview) {
        if (v.hidden || v.alpha == 0) return NO;
    }
    return YES;
}

// Spotify's labels on the card, top to bottom: the title, then whatever is under it.
static NSArray<UILabel *> *labelsOf(UIView *card, UIView *face) {
    NSMutableArray<UILabel *> *labels = [NSMutableArray array];
    SGForEachView(card, ^(UIView *v) {
        if (![v isKindOfClass:UILabel.class] || [v isDescendantOfView:face]) return;
        UILabel *label = (UILabel *)v;
        if (label.text.length && shown(label, card)) [labels addObject:label];
    });
    [labels sortUsingComparator:^NSComparisonResult(UILabel *a, UILabel *b) {
        CGFloat ya = [a convertPoint:CGPointZero toView:card].y, yb = [b convertPoint:CGPointZero toView:card].y;
        return ya < yb ? NSOrderedAscending : ya > yb ? NSOrderedDescending : NSOrderedSame;
    }];
    return labels;
}

static void setText(UILabel *label, NSString *text) {
    if ([label.text isEqualToString:text] || (!label.text.length && !text.length)) return;
    label.text = text;
    [label.superview setNeedsLayout];
}

static void paint(SGRTopPickFace *face, UIImage *image) {
    if (!image) {
        face.image = nil;
        [face setColor:nil animated:NO];
        return;
    }
    if (face.image == image) return;
    face.image = image;
    __weak SGRTopPickFace *weakFace = face;
    UIColor *known = SGRHomeCoverColor(image, ^(UIColor *color) {
        SGRTopPickFace *strongFace = weakFace;
        // A card reused for another cover in the meantime has asked for that one.
        if (strongFace && strongFace.image == image) [strongFace setColor:color animated:YES];
    });
    if (known) [face setColor:known animated:NO];
}

BOOL SGRHomeStyleTopPick(UIView *card) {
    SGRTopPickFace *face = objc_getAssociatedObject(card, &kFaceKey);
    if (!SGRHomeTopPicksShelfAround(card)) {
        if (face && !face.hidden) face.hidden = YES;
        return NO;
    }
    CFTimeInterval began = SGRHomeProbeBegin();
    if (!face) {
        face = [SGRTopPickFace new];
        objc_setAssociatedObject(card, &kFaceKey, face, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        static dispatch_once_t once;
        dispatch_once(&once, ^{ SGLog(@"redesign home: a top picks card %.0fx%.0f", card.bounds.size.width, card.bounds.size.height); });
    }
    if (face.superview != card) [card addSubview:face];
    else if (card.subviews.lastObject != face) [card bringSubviewToFront:face];
    if (face.hidden) face.hidden = NO;
    if (!CGRectEqualToRect(face.frame, card.bounds)) face.frame = card.bounds;

    UIView *holder = SGRFindByIdentifier(card, @"Encore.ImageView", &kImageKey);
    UIImageView *cover = nil;
    for (UIView *sub in holder.subviews) {
        if ([sub isKindOfClass:UIImageView.class]) cover = (UIImageView *)sub;
    }
    CGFloat bottom = holder ? CGRectGetMaxY([holder convertRect:holder.bounds toView:card]) : card.bounds.size.width;
    if (bottom != face.artBottom) {
        face.artBottom = bottom;
        [face setNeedsLayout];
    }
    if (cover) {
        CALayer *layer = cover.layer;
        if (layer.cornerRadius != SGRRadiusCard) layer.cornerRadius = SGRRadiusCard;
        if (layer.cornerCurve != kCACornerCurveContinuous) layer.cornerCurve = kCACornerCurveContinuous;
        if (!layer.masksToBounds) layer.masksToBounds = YES;
        __weak UIView *weakCard = card;
        // The block is replaced on every pass, so a cover taken into another card tells the card it is in now.
        SGRObserveImage(cover, ^(UIImageView *view) {
            UIView *strongCard = weakCard;
            if (strongCard && [view isDescendantOfView:strongCard]) SGRHomeStyleTopPick(strongCard);
        });
    }
    paint(face, cover.image);

    NSArray<UILabel *> *labels = labelsOf(card, face);
    setText(face.title, labels.firstObject.text);
    setText(face.subtitle, labels.count > 1 ? labels[1].text : nil);
    SGRHomeProbeEnd(SGRHomeProbeTopPicks, began);
    return YES;
}
