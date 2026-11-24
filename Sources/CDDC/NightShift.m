#import "NightShift.h"
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

typedef struct { int hour, minute; } ADCTime;
typedef struct { ADCTime start, end; } ADCTimes;
typedef struct {
    BOOL active, enabled, sunSchedulePermitted;
    int mode;
    ADCTimes schedule;
    unsigned long long disableFlags;
    BOOL available;
} ADCBlueLightStatus;

@protocol ADCBlueLight <NSObject>
- (BOOL)getBlueLightStatus:(ADCBlueLightStatus *)status;
- (BOOL)getStrength:(float *)strength;
- (BOOL)setStrength:(float)strength commit:(BOOL)commit;
- (BOOL)setEnabled:(BOOL)enabled;
@end

// CoreBrightness is private. Check the ABI, including the status buffer layout,
// before messaging the client. System Settings remains available on other versions.
static id<ADCBlueLight> blueLightClient(void) {
    static id<ADCBlueLight> client;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSBundle *bundle = [NSBundle bundleWithPath:@"/System/Library/PrivateFrameworks/CoreBrightness.framework"];
        if (![bundle load]) return;
        Class cls = [bundle classNamed:@"CBBlueLightClient"];
        SEL selectors[] = { @selector(getBlueLightStatus:), @selector(getStrength:),
                            @selector(setStrength:commit:), @selector(setEnabled:) };
        for (unsigned i = 0; i < sizeof(selectors) / sizeof(selectors[0]); ++i) {
            Method method = class_getInstanceMethod(cls, selectors[i]);
            const char *expected = protocol_getMethodDescription(@protocol(ADCBlueLight), selectors[i], YES, YES).types;
            if (!method || !expected || strcmp(method_getTypeEncoding(method), expected) != 0) return;
        }
        client = [[cls alloc] init];
    });
    return client;
}

bool ADCNightShiftRead(bool *enabled, float *strength) {
    ADCBlueLightStatus status = {0};
    id<ADCBlueLight> client = blueLightClient();
    if (![client getBlueLightStatus:&status] || !status.available || ![client getStrength:strength]) return false;
    *enabled = status.enabled;
    return *strength >= 0 && *strength <= 1;
}

bool ADCNightShiftSetEnabled(bool enabled) {
    return [blueLightClient() setEnabled:enabled];
}

bool ADCNightShiftSetStrength(float strength) {
    return strength >= 0 && strength <= 1 && [blueLightClient() setStrength:strength commit:YES];
}
