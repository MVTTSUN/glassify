// The Visualizer's part of the redesign's Player page (PlayerSettings.m puts it there while the Visualizer is the
// background), and the pages it opens.
//
// The picker is a row of tiles that scrolls sideways, one for each shader, built in or the user's own, each a live
// Visualizer of its own drawing that shader in the playing cover's colors (SGRPlayerVisualiserPreviewOf, 30 frames
// a second at most and only while the page is in a window), its name under it and the one picked ringed in the
// accent. A tap picks it, which the player and the page's card follow at once.
//
// Under it: Intensity (25-200 %), Reduce in Low Power Mode, and Custom Shaders, a page of the user's own: a tap on
// one opens the editor, a swipe deletes it, and New Shader opens the editor on a template. The editor takes a name
// and the body of a Metal function (SGRShaderSource.h's contract, written above it), Check compiles it as the
// player would and shows the compiler's error at the body's own line, and Save compiles and keeps it only when it
// compiles, a new one picked at once.
//
// Threading: main thread only.
#import "Core/SGCore.h"
#import "Settings/SGModPage.h"
#import "Settings/SGPageStyle.h"
#import "Player.h"
#import "SGRShaderView.h"

static const CGFloat kTileWidth = 72, kTileHeight = 108, kTileGap = 10, kTileRadius = 14, kNameGap = 6;

static NSArray<NSString *> *allShaders(void) {
    NSMutableArray<NSString *> *all = [SGRBuiltInShaders() mutableCopy];
    for (SGRCustomShader *shader in SGRCustomShaders()) [all addObject:shader.identifier];
    return all;
}

static UIFont *nameFont(void) {
    return SGCappedFont([UIFont preferredFontForTextStyle:UIFontTextStyleCaption2], 15);
}

#pragma mark - the picker

@interface SGRShaderTile : UIControl
@property (nonatomic, copy, readonly) NSString *shader;
- (instancetype)initWithShader:(NSString *)shader;
@end

@implementation SGRShaderTile {
    UIView *_preview, *_ring;
    UILabel *_name;
}

- (instancetype)initWithShader:(NSString *)shader {
    if (!(self = [super initWithFrame:CGRectZero])) return nil;
    _shader = [shader copy];
    _preview = SGRPlayerVisualiserPreviewOf(shader);
    UIView *card = [UIView new];
    card.userInteractionEnabled = NO;
    card.clipsToBounds = YES;
    card.layer.cornerRadius = kTileRadius;
    card.layer.cornerCurve = kCACornerCurveContinuous;
    card.backgroundColor = SGCardBackground();
    card.tag = 1;
    [card addSubview:_preview];
    [self addSubview:card];
    _ring = [UIView new];
    _ring.userInteractionEnabled = NO;
    _ring.layer.cornerRadius = kTileRadius + 3;
    _ring.layer.cornerCurve = kCACornerCurveContinuous;
    _ring.layer.borderWidth = 2;
    [self addSubview:_ring];
    _name = [UILabel new];
    _name.textColor = UIColor.whiteColor;
    _name.textAlignment = NSTextAlignmentCenter;
    _name.lineBreakMode = NSLineBreakByTruncatingTail;
    _name.text = SGRShaderName(shader);
    [self addSubview:_name];
    self.isAccessibilityElement = YES;
    self.accessibilityLabel = _name.text;
    return self;
}

- (void)setSelected:(BOOL)selected {
    [super setSelected:selected];
    _ring.layer.borderColor = selected ? SGAccentMark().CGColor : UIColor.clearColor.CGColor;
    _name.textColor = selected ? UIColor.whiteColor : SGGrey();
    self.accessibilityTraits = UIAccessibilityTraitButton | (selected ? UIAccessibilityTraitSelected : 0);
}

- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    self.alpha = highlighted ? 0.6 : 1;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    UIView *card = [self viewWithTag:1];
    card.frame = CGRectMake(0, 3, kTileWidth, kTileHeight);
    _preview.frame = card.bounds;
    _ring.frame = CGRectInset(card.frame, -3, -3);
    _name.font = nameFont();
    _name.frame = CGRectMake(-4, CGRectGetMaxY(card.frame) + 3 + kNameGap, kTileWidth + 8, ceil(_name.font.lineHeight));
}

@end

@interface SGRShaderPicker : UIScrollView
@end

@implementation SGRShaderPicker {
    NSArray<SGRShaderTile *> *_tiles;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.showsHorizontalScrollIndicator = NO;
    self.alwaysBounceHorizontal = YES;
    self.clipsToBounds = NO;
    self.accessibilityLabel = @"Visualizer style";
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(reload) name:SGRVisualiserSettingsDidChangeNotification object:nil];
    [self reload];
    return self;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

// The tiles made again only when the list of shaders changed, so their previews keep running through a pick.
- (void)reload {
    NSArray<NSString *> *shaders = allShaders();
    if (![[_tiles valueForKey:@"shader"] isEqualToArray:shaders]) {
        for (SGRShaderTile *tile in _tiles) [tile removeFromSuperview];
        NSMutableArray<SGRShaderTile *> *tiles = [NSMutableArray array];
        for (NSString *shader in shaders) {
            SGRShaderTile *tile = [[SGRShaderTile alloc] initWithShader:shader];
            [tile addTarget:self action:@selector(picked:) forControlEvents:UIControlEventTouchUpInside];
            [self addSubview:tile];
            [tiles addObject:tile];
        }
        _tiles = tiles;
        [self setNeedsLayout];
    }
    NSString *current = SGRVisualiserShader();
    for (SGRShaderTile *tile in _tiles) tile.selected = [tile.shader isEqualToString:current];
}

- (void)picked:(SGRShaderTile *)tile {
    SGRSetVisualiserShader(tile.shader);
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat x = 0, height = self.bounds.size.height;
    for (SGRShaderTile *tile in _tiles) {
        tile.frame = CGRectMake(x, 0, kTileWidth, height);
        x += kTileWidth + kTileGap;
    }
    CGSize size = CGSizeMake(MAX(0, x - kTileGap), height);
    if (!CGSizeEqualToSize(self.contentSize, size)) self.contentSize = size;
}

@end

UIView *SGRVisualiserPicker(void) {
    return [SGRShaderPicker new];
}

CGFloat SGRVisualiserPickerHeight(void) {
    return 3 + kTileHeight + 3 + kNameGap + ceil(nameFont().lineHeight);
}

#pragma mark - the editor

static void showAlert(UIViewController *owner, NSString *title, NSString *message) {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    [owner presentViewController:alert animated:YES completion:nil];
}

typedef NS_ENUM(NSInteger, SGRShaderEditorSection) {
    SGRShaderEditorName,
    SGRShaderEditorBody,
    SGRShaderEditorStatus,
    SGRShaderEditorActions,
    SGRShaderEditorSectionCount,
};

typedef NS_ENUM(NSInteger, SGRShaderEditorAction) {
    SGRShaderEditorCheck,
    SGRShaderEditorSave,
    SGRShaderEditorPaste,
    SGRShaderEditorActionCount,
};

@interface SGRShaderEditor : SGPage <UITextViewDelegate>
- (instancetype)initWithShader:(SGRCustomShader *)shader;
@end

@implementation SGRShaderEditor {
    SGRCustomShader *_shader;   // nil for a new one
    UITextField *_name;
    UITextView *_body;
    UIView *_intro;
    NSString *_status;          // the last check: nil before one, "" when it compiled, else the error
    BOOL _checking;
}

- (instancetype)initWithShader:(SGRCustomShader *)shader {
    if (!(self = [super initWithStyle:UITableViewStyleInsetGrouped])) return nil;
    _shader = shader;
    self.title = shader ? @"Edit Shader" : @"New Shader";
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    _intro = SGNote(SGRShaderContract());
    self.tableView.tableHeaderView = _intro;
    self.tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;

    _name = [UITextField new];
    _name.font = SGTitleFont();
    _name.textColor = UIColor.whiteColor;
    _name.placeholder = @"Name";
    _name.text = _shader.name ?: @"My Shader";
    _name.keyboardAppearance = UIKeyboardAppearanceDark;
    _name.clearButtonMode = UITextFieldViewModeWhileEditing;
    _name.accessibilityLabel = @"Name";

    _body = [UITextView new];
    _body.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
    _body.textColor = UIColor.whiteColor;
    _body.backgroundColor = UIColor.clearColor;
    _body.textContainerInset = UIEdgeInsetsMake(12, 16, 12, 16);
    _body.textContainer.lineFragmentPadding = 0;
    _body.keyboardAppearance = UIKeyboardAppearanceDark;
    _body.autocorrectionType = UITextAutocorrectionTypeNo;
    _body.autocapitalizationType = UITextAutocapitalizationTypeNone;
    _body.spellCheckingType = UITextSpellCheckingTypeNo;
    _body.smartQuotesType = UITextSmartQuotesTypeNo;
    _body.smartDashesType = UITextSmartDashesTypeNo;
    _body.smartInsertDeleteType = UITextSmartInsertDeleteTypeNo;
    _body.accessibilityLabel = @"Shader body";
    _body.delegate = self;
    _body.text = _shader.body ?: SGRShaderTemplate();
}

- (void)viewWillLayoutSubviews {
    [super viewWillLayoutSubviews];
    SGFitNote(self.tableView, _intro, 24, 0);
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)table {
    return SGRShaderEditorSectionCount;
}

- (NSInteger)tableView:(UITableView *)table numberOfRowsInSection:(NSInteger)section {
    if (section == SGRShaderEditorStatus) return _status || _checking ? 1 : 0;
    return section == SGRShaderEditorActions ? SGRShaderEditorActionCount : 1;
}

- (CGFloat)tableView:(UITableView *)table heightForRowAtIndexPath:(NSIndexPath *)path {
    if (path.section == SGRShaderEditorName) return 44;
    return path.section == SGRShaderEditorBody ? 300 : UITableViewAutomaticDimension;
}

- (UITableViewCell *)tableView:(UITableView *)table cellForRowAtIndexPath:(NSIndexPath *)path {
    if (path.section == SGRShaderEditorName || path.section == SGRShaderEditorBody) {
        BOOL name = path.section == SGRShaderEditorName;
        UITableViewCell *cell = SGDequeueCell(table, name ? @"name" : @"body");
        cell.backgroundColor = SGCardBackground();
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        UIView *field = name ? _name : _body;
        field.frame = name ? CGRectInset(cell.contentView.bounds, 16, 0) : cell.contentView.bounds;
        field.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [cell.contentView addSubview:field];
        return cell;
    }
    UITableViewCell *cell = SGDequeueCell(table, path.section == SGRShaderEditorStatus ? @"status" : @"action");
    if (path.section == SGRShaderEditorStatus) {
        BOOL failed = _status.length > 0;
        SGFillCell(cell, _checking ? @"Compiling…" : failed ? @"Does not compile" : @"Compiles", failed ? _status : nil,
                   failed ? SGRed() : nil, _checking ? @"hourglass" : failed ? @"exclamationmark.triangle.fill" : @"checkmark.circle");
        UIListContentConfiguration *content = (UIListContentConfiguration *)cell.contentConfiguration;
        content.secondaryTextProperties.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
        content.secondaryTextProperties.color = SGRed();
        content.secondaryTextProperties.numberOfLines = 0;
        cell.contentConfiguration = content;
        return cell;
    }
    NSArray<NSArray<NSString *> *> *actions = @[
        @[@"Check", @"Compile it without saving", @"hammer"],
        @[@"Save", @"Compile it, keep it and use it", @"checkmark"],
        @[@"Paste", @"Replace the body with what you copied", @"doc.on.clipboard"],
    ];
    NSArray<NSString *> *action = actions[(NSUInteger)path.row];
    SGFillCell(cell, action[0], action[1], _checking ? SGGrey() : nil, action[2]);
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    cell.accessibilityTraits = UIAccessibilityTraitButton | (_checking ? UIAccessibilityTraitNotEnabled : 0);
    return cell;
}

- (BOOL)tableView:(UITableView *)table shouldHighlightRowAtIndexPath:(NSIndexPath *)path {
    return path.section == SGRShaderEditorActions && !_checking;
}

- (void)tableView:(UITableView *)table didSelectRowAtIndexPath:(NSIndexPath *)path {
    [table deselectRowAtIndexPath:path animated:YES];
    if (path.section != SGRShaderEditorActions || _checking) return;
    if (path.row == SGRShaderEditorPaste) {
        NSString *pasted = UIPasteboard.generalPasteboard.string;
        if (!pasted.length) {
            showAlert(self, @"Nothing to paste", @"Copy the body of a shader first.");
            return;
        }
        _body.text = pasted;
        [self showStatus:nil];
        return;
    }
    [self.view endEditing:YES];
    BOOL save = path.row == SGRShaderEditorSave;
    NSString *body = _body.text;
    _checking = YES;
    [self showStatus:nil];
    __weak SGRShaderEditor *weakSelf = self;
    SGRCompileShaderBody(body, ^(NSString *error) {
        SGRShaderEditor *editor = weakSelf;
        if (!editor) return;
        editor->_checking = NO;
        [editor showStatus:error ?: @""];
        if (save && !error) [editor saveBody:body];
    });
}

- (void)showStatus:(NSString *)status {
    _status = status;
    [self.tableView reloadSections:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(SGRShaderEditorStatus, 2)] withRowAnimation:UITableViewRowAnimationNone];
}

- (void)saveBody:(NSString *)body {
    NSString *name = [_name.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!name.length) name = @"Untitled Shader";
    BOOL made = !_shader;
    SGRCustomShader *shader = _shader ?: [SGRCustomShader shaderWithName:name body:body];
    shader.name = name;
    shader.body = body;
    NSError *error = nil;
    if (!SGRSaveCustomShader(shader, &error)) {
        showAlert(self, @"Could not save the shader", error.localizedDescription);
        return;
    }
    _shader = shader;
    SGLog(@"redesign player: custom visualizer shader %@ saved", shader.identifier);
    if (made) SGRSetVisualiserShader(shader.identifier);
    SGRVisualiserSettingsChanged();
    if (self.navigationController.viewControllers.count > 1) [self.navigationController popViewControllerAnimated:YES];
    else [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)textViewDidChange:(UITextView *)textView {
    if (_status) [self showStatus:nil];
}

@end

#pragma mark - the list

@interface SGRCustomShadersPage : SGPage
@end

@implementation SGRCustomShadersPage {
    NSArray<SGRCustomShader *> *_shaders;
    UIView *_intro;
}

- (instancetype)init {
    if (!(self = [super initWithStyle:UITableViewStyleInsetGrouped])) return nil;
    self.title = @"Custom Shaders";
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    _intro = SGNote(@"Your own Visualizer styles, written in Metal. Each is the body of one function that draws a "
                    @"frame from the song's spectrum and the cover's colors; the editor says what it can use.");
    self.tableView.tableHeaderView = _intro;
}

- (void)viewWillLayoutSubviews {
    [super viewWillLayoutSubviews];
    SGFitNote(self.tableView, _intro, 24, 0);
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    _shaders = SGRCustomShaders();
    [self.tableView reloadData];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)table {
    return 2;
}

- (NSInteger)tableView:(UITableView *)table numberOfRowsInSection:(NSInteger)section {
    return section == 0 ? (NSInteger)_shaders.count : 1;
}

- (UITableViewCell *)tableView:(UITableView *)table cellForRowAtIndexPath:(NSIndexPath *)path {
    UITableViewCell *cell = SGDequeueCell(table, @"row");
    if (path.section == 1) {
        SGFillCell(cell, @"New Shader", nil, nil, @"plus");
    } else {
        SGRCustomShader *shader = _shaders[(NSUInteger)path.row];
        BOOL used = [shader.identifier isEqualToString:SGRVisualiserShader()];
        SGFillCell(cell, shader.name, used ? @"In use" : nil, nil, @"wand.and.stars");
        cell.accessoryView = SGChevronView();
    }
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    return cell;
}

- (void)tableView:(UITableView *)table didSelectRowAtIndexPath:(NSIndexPath *)path {
    [table deselectRowAtIndexPath:path animated:YES];
    SGRCustomShader *shader = path.section == 0 ? _shaders[(NSUInteger)path.row] : nil;
    SGShowPage(self, [[SGRShaderEditor alloc] initWithShader:shader]);
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)table trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)path {
    if (path.section != 0) return nil;
    SGRCustomShader *shader = _shaders[(NSUInteger)path.row];
    __weak SGRCustomShadersPage *weakSelf = self;
    UIContextualAction *delete = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive title:@"Delete"
        handler:^(UIContextualAction *action, UIView *view, void (^done)(BOOL)) {
            SGRCustomShadersPage *page = weakSelf;
            BOOL deleted = SGRDeleteCustomShader(shader.identifier);
            done(deleted);
            if (!page) return;
            if (!deleted) {
                showAlert(page, @"Could not delete the shader", nil);
                return;
            }
            // One in use leaves the Visualizer with Hills (SGRVisualiserShader).
            SGRVisualiserSettingsChanged();
            page->_shaders = SGRCustomShaders();
            [page.tableView deleteRowsAtIndexPaths:@[path] withRowAnimation:UITableViewRowAnimationAutomatic];
        }];
    delete.image = [UIImage systemImageNamed:@"trash"];
    return [UISwipeActionsConfiguration configurationWithActions:@[delete]];
}

@end

#pragma mark - the rows

NSArray *SGRVisualiserRows(void) {
    SGModRow *intensity = SGSliderRow(@"Intensity", nil, 25, 200, 5, ^double { return SGRVisualiserIntensity(); },
                                      ^(double value) { SGRSetVisualiserIntensity(lround(value)); },
                                      ^NSString *(double value) { return [NSString stringWithFormat:@"%.0f%%", value]; });
    SGModRow *lowPower = SGSwitchRow(@"Reduce in Low Power Mode", @"Fewer frames, drawn smaller", SGRKeyVisualiserLowPower);
    lowPower.changed = ^(BOOL on) { SGRVisualiserSettingsChanged(); };
    SGModRow *custom = SGPageRow(@"Custom Shaders", ^UIViewController * { return [SGRCustomShadersPage new]; });
    custom.value = ^NSString * {
        NSUInteger count = SGRCustomShaders().count;
        return count ? [NSString stringWithFormat:@"%lu", (unsigned long)count] : @"None";
    };
    return @[intensity, lowPower, custom];
}
