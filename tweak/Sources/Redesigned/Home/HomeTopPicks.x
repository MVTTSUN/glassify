// Home redesign: Top picks, the first shelf of cards drawn large the way the Music app draws its Top Picks: cards
// about two thirds of the screen wide that page one at a time, each the cover with its title and subtitle over the
// cover's color at its foot (HomeTopPickCard.m), under the heading "Top Picks" (HomeHeadings.x). The cards are
// Spotify's own cells, only drawn larger, so a tap on one does what a tap on it always did.
//
// A shelf is a Home_CarouselKit.TouchCancellingCollectionView in a cell of the page's list (HomeSections.x), a
// compositional layout of its own with cards 149 by 195 under a 40pt heading (trees: the 393x235 shelf, cards at
// {149, 195}). Its sizes are Spotify's, made by the layout's section provider each time the layout is asked for one.
// So every compositional layout's provider is wrapped, and while the large shelf's provider runs, the absolute and
// estimated sizes it makes of kSmallest or more are scaled by kScale: the cards and their group, not the heading or
// the spacing; 149 becomes 253, two thirds of a 393pt screen. The section it makes pages a group at a time where it
// scrolls across on its own (orthogonalScrollingBehavior); a layout that scrolls the shelf itself across snaps to the
// nearest card as a drag ends (-targetContentOffsetForProposedContentOffset:withScrollingVelocity:). The page's cell
// is made that much taller to hold it.
//
// Which shelf: of Home's sections that are shelves of cards (the class above, taller than its heading) holding
// kFewest cards or more, the one at the lowest index of the page's list any has been measured at, whatever the
// server calls it ("Jump back in", "Your top mixes", "Made for you"...): the first shelf the page shows, so the
// headings, languages and orders the server sends do not matter. A shelf of fewer cards is passed over, as a carousel
// of one or two large cards is no carousel. Cells are reused across shelves, so each measuring sets or clears the
// mark on the layout it holds.
#import <objc/runtime.h>
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Home.h"

static const CGFloat kScale = 1.7, kSmallest = 120, kHeading = 40;
static const NSInteger kFewest = 3;
static char kLargeKey, kNaturalKey, kWrappedKey;
static _Thread_local BOOL sg_enlarging;
static NSInteger sg_topIndex = NSIntegerMax;

NSString *const SGRHomeTopPicksTitle = @"Top Picks";

static Class shelfClass(void) {
    static Class shelf;
    if (!shelf) shelf = NSClassFromString(@"_TtC16Home_CarouselKit29TouchCancellingCollectionView");
    return shelf;
}

BOOL SGRHomeShelfIsTopPicks(UICollectionView *shelf) {
    UICollectionViewLayout *layout = shelf.collectionViewLayout;
    return layout && objc_getAssociatedObject(layout, &kLargeKey) != nil;
}

UICollectionView *SGRHomeTopPicksShelfAround(UIView *view) {
    Class shelf = shelfClass();
    if (!shelf) return nil;
    NSUInteger depth = 0;
    for (UIView *v = view.superview; v && depth < 12; v = v.superview, depth++) {
        if ([v isKindOfClass:shelf]) return SGRHomeShelfIsTopPicks((UICollectionView *)v) ? (UICollectionView *)v : nil;
    }
    return nil;
}

// The layout a wrapped provider belongs to, set once the layout is made.
@interface SGRLayoutBox : NSObject
@property (nonatomic, weak) UICollectionViewCompositionalLayout *layout;
@end
@implementation SGRLayoutBox
@end

static UICollectionViewCompositionalLayoutSectionProvider wrapped(UICollectionViewCompositionalLayoutSectionProvider provider, SGRLayoutBox *box) {
    return ^NSCollectionLayoutSection *(NSInteger section, id<NSCollectionLayoutEnvironment> environment) {
        UICollectionViewCompositionalLayout *layout = box.layout;
        BOOL large = layout && objc_getAssociatedObject(layout, &kLargeKey) != nil;
        BOOL was = sg_enlarging;
        sg_enlarging = large;
        NSCollectionLayoutSection *made = provider(section, environment);
        sg_enlarging = was;
        // One card at a time, where the section scrolls across on its own.
        if (large && made && made.orthogonalScrollingBehavior != UICollectionLayoutSectionOrthogonalScrollingBehaviorNone) {
            made.orthogonalScrollingBehavior = UICollectionLayoutSectionOrthogonalScrollingBehaviorGroupPaging;
        }
        return made;
    };
}

static UICollectionViewCompositionalLayout *boxed(UICollectionViewCompositionalLayout *made, SGRLayoutBox *box) {
    box.layout = made;
    if (made) objc_setAssociatedObject(made, &kWrappedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return made;
}

// Where a drag of a shelf that scrolls itself across comes to rest: the leading edge of the card nearest to where it
// would have, one card on at most in the direction of the fling.
static CGPoint snapped(UICollectionViewLayout *layout, CGPoint proposed, CGPoint velocity) {
    UICollectionView *view = layout.collectionView;
    if (!view) return proposed;
    CGFloat inset = view.adjustedContentInset.left, current = view.contentOffset.x;
    CGRect area = CGRectMake(proposed.x - view.bounds.size.width, 0, view.bounds.size.width * 3, MAX(view.contentSize.height, view.bounds.size.height));
    CGFloat best = proposed.x, distance = CGFLOAT_MAX;
    for (UICollectionViewLayoutAttributes *attributes in [layout layoutAttributesForElementsInRect:area]) {
        if (attributes.representedElementCategory != UICollectionElementCategoryCell) continue;
        CGFloat x = attributes.frame.origin.x - inset;
        // A fling moves on from where the drag let go, never back past it.
        if (velocity.x > 0 && x <= current) continue;
        if (velocity.x < 0 && x >= current) continue;
        CGFloat d = fabs(x - proposed.x);
        if (d < distance) {
            distance = d;
            best = x;
        }
    }
    CGFloat most = MAX(-inset, view.contentSize.width + view.adjustedContentInset.right - view.bounds.size.width);
    return CGPointMake(MIN(MAX(best, -inset), most), proposed.y);
}

%hook UICollectionViewCompositionalLayout
- (instancetype)initWithSectionProvider:(UICollectionViewCompositionalLayoutSectionProvider)provider
                          configuration:(UICollectionViewCompositionalLayoutConfiguration *)configuration {
    if (!provider) return %orig;
    SGRLayoutBox *box = [SGRLayoutBox new];
    return boxed(%orig(wrapped(provider, box), configuration), box);
}
- (instancetype)initWithSectionProvider:(UICollectionViewCompositionalLayoutSectionProvider)provider {
    if (!provider) return %orig;
    SGRLayoutBox *box = [SGRLayoutBox new];
    return boxed(%orig(wrapped(provider, box)), box);
}
- (CGPoint)targetContentOffsetForProposedContentOffset:(CGPoint)proposed withScrollingVelocity:(CGPoint)velocity {
    CGPoint target = %orig;
    UICollectionViewCompositionalLayout *layout = (UICollectionViewCompositionalLayout *)self;
    if (!objc_getAssociatedObject(layout, &kLargeKey)) return target;
    if (layout.configuration.scrollDirection != UICollectionViewScrollDirectionHorizontal) return target;
    return snapped(layout, target, velocity);
}
%end

%hook NSCollectionLayoutDimension
+ (instancetype)absoluteDimension:(CGFloat)dimension {
    if (sg_enlarging && dimension >= kSmallest) dimension = round(dimension * kScale);
    return %orig(dimension);
}
+ (instancetype)estimatedDimension:(CGFloat)dimension {
    if (sg_enlarging && dimension >= kSmallest) dimension = round(dimension * kScale);
    return %orig(dimension);
}
%end

static NSInteger cardsIn(UICollectionView *shelf) {
    NSInteger cards = 0;
    for (NSInteger section = 0, sections = shelf.numberOfSections; section < sections; section++) cards += [shelf numberOfItemsInSection:section];
    return cards;
}

// After the mark moved: the headings and cards of the shelf look again, since a heading keeps its size and so is not
// laid out again by the layout's change alone.
static void relayout(UICollectionView *shelf) {
    __weak UICollectionView *weakShelf = shelf;
    dispatch_async(dispatch_get_main_queue(), ^{
        UICollectionView *strongShelf = weakShelf;
        if (strongShelf) SGForEachView(strongShelf, ^(UIView *v) { [v setNeedsLayout]; });
    });
}

%hook _TtC12Element_List18CollectionViewCell
- (UICollectionViewLayoutAttributes *)preferredLayoutAttributesFittingAttributes:(UICollectionViewLayoutAttributes *)attributes {
    UICollectionViewLayoutAttributes *result = %orig;
    UIView *content = ((UICollectionViewCell *)self).contentView.subviews.firstObject;
    // Home's sections only, as HomeSections.x tells them: a shelf on another page is not Home's top.
    if (![NSStringFromClass(object_getClass(content)) containsString:@"Home_EvoPageImpl13HomeStructure"]) return result;
    CFTimeInterval began = SGRHomeProbeBegin();
    Class shelf = shelfClass();
    UIView *root = content.subviews.firstObject;
    NSInteger index = attributes.indexPath.section * 10000 + attributes.indexPath.item;
    BOOL eligible = shelf && [root isKindOfClass:shelf] && result.size.height > kHeading && cardsIn((UICollectionView *)root) >= kFewest;
    UICollectionViewLayout *layout = [root isKindOfClass:UICollectionView.class] ? ((UICollectionView *)root).collectionViewLayout : nil;
    if (!eligible) {
        // The top's place holds something else now (the feed came again): the next shelf measured takes it.
        if (index == sg_topIndex) sg_topIndex = NSIntegerMax;
        // A shelf that was large and is too short now is drawn as Spotify draws it again.
        if (layout && objc_getAssociatedObject(layout, &kLargeKey)) {
            NSNumber *natural = objc_getAssociatedObject(layout, &kNaturalKey);
            objc_setAssociatedObject(layout, &kLargeKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            [layout invalidateLayout];
            relayout((UICollectionView *)root);
            if (natural) result.size = CGSizeMake(result.size.width, natural.doubleValue);
        }
        SGRHomeProbeEnd(SGRHomeProbeTopPicks, began);
        return result;
    }
    if (index < sg_topIndex) sg_topIndex = index;
    BOOL large = index == sg_topIndex, was = objc_getAssociatedObject(layout, &kLargeKey) != nil;
    // The shelf's height as Spotify sizes it, from a measuring before it was large.
    if (!was) objc_setAssociatedObject(layout, &kNaturalKey, @(result.size.height), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (large != was) {
        objc_setAssociatedObject(layout, &kLargeKey, large ? @YES : nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [layout invalidateLayout];
        relayout((UICollectionView *)root);
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            UICollectionViewCompositionalLayout *compositional = [layout isKindOfClass:UICollectionViewCompositionalLayout.class] ? (UICollectionViewCompositionalLayout *)layout : nil;
            SGLog(@"redesign home: top picks at %ld, %ld cards, its layout %@ (%@, %@)", (long)index, (long)cardsIn((UICollectionView *)root),
                  NSStringFromClass(layout.class),
                  objc_getAssociatedObject(layout, &kWrappedKey) ? @"sized by a provider" : @"not made by a provider: left as it is",
                  compositional.configuration.scrollDirection == UICollectionViewScrollDirectionHorizontal ? @"scrolls itself across: snaps" : @"its section scrolls across: pages");
        });
    }
    NSNumber *natural = objc_getAssociatedObject(layout, &kNaturalKey);
    // Large, the natural height scaled; small again in a cell that was large, the natural height, since this measuring
    // was of the cards still drawn large.
    if (natural && large) result.size = CGSizeMake(result.size.width, round(kHeading + (natural.doubleValue - kHeading) * kScale));
    else if (natural && was) result.size = CGSizeMake(result.size.width, natural.doubleValue);
    SGRHomeProbeEnd(SGRHomeProbeTopPicks, began);
    return result;
}
%end

%ctor {
    if (!SGRedesignedUI() || !SGEnabled(SGRKeyHomeTopPicks)) return;
    %init;
    SGRequireClasses(@[
        @"_TtC12Element_List18CollectionViewCell",
        @"_TtC16Home_CarouselKit29TouchCancellingCollectionView",
    ]);
}
