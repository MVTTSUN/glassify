// What every source file of the mod builds on. Feature-specific API lives in the feature's own
// header under Shared/, Native/ or Redesigned/, next to the keys it reads.
// The product's name and the GitHub repo (owner/name) its updates come from, set by tweak/Makefile; a build
// outside it (the harnesses) gets these. An empty SG_REPO turns the update check and the GitHub links off.
#ifndef SG_NAME
#define SG_NAME "Glassify"
#endif
#ifndef SG_REPO
#define SG_REPO "MVTTSUN/glassify"
#endif
#import "SGRuntime.h"
#import "SGLog.h"
#import "SGPrefs.h"
#import "SGViewTree.h"
#import "SGGlass.h"
#import "SGBackdrop.h"
#import "SGUIMode.h"
#import "SGFlagForce.h"
