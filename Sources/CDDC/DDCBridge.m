@import ApplicationServices;
@import CoreGraphics;
@import Foundation;
@import IOKit;

#include "DDCBridge.h"
#include <dlfcn.h>

#define ADC_MAX_DISPLAYS 16
#define ADC_DDC_ADDRESS 0x51
#define ADC_DDC_CHIP_ADDRESS 0x37
#define ADC_DDC_MCDP29XX_CHIP_ADDRESS 0xB7
#define ADC_DDC_BUFFER_SIZE 256

typedef CFTypeRef IOAVServiceRef;
typedef CGError (*ADCConfigureDisplayEnabledFunction)(
    CGDisplayConfigRef config,
    CGDirectDisplayID display,
    bool enabled
);

extern IOAVServiceRef IOAVServiceCreateWithService(CFAllocatorRef allocator, io_service_t service);
extern IOReturn IOAVServiceReadI2C(
    IOAVServiceRef service,
    uint32_t chipAddress,
    uint32_t offset,
    void *outputBuffer,
    uint32_t outputBufferSize
);
extern IOReturn IOAVServiceWriteI2C(
    IOAVServiceRef service,
    uint32_t chipAddress,
    uint32_t dataAddress,
    void *inputBuffer,
    uint32_t inputBufferSize
);
extern CFDictionaryRef CoreDisplay_DisplayCreateInfoDictionary(CGDirectDisplayID displayID);

typedef struct {
    ADCDisplayInfo info;
    io_service_t adapter;
    char hardwareKey[ADC_DISPLAY_UUID_LENGTH];
} ADCInternalDisplay;

typedef struct {
    IOAVServiceRef service;
    uint32_t chipAddress;
    Boolean includeReadSource;
} ADCTransport;

static ADCTransport ADCCachedTransport = { .service = NULL, .chipAddress = ADC_DDC_CHIP_ADDRESS };
static char ADCCachedDisplayUUID[ADC_DISPLAY_UUID_LENGTH] = {0};

static ADCConfigureDisplayEnabledFunction ADCDisplayEnabledFunction(void) {
    static ADCConfigureDisplayEnabledFunction function;
    static void *skyLightHandle;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        function = (ADCConfigureDisplayEnabledFunction)dlsym(
            RTLD_DEFAULT,
            "CGSConfigureDisplayEnabled"
        );
        if (function != NULL) {
            return;
        }

        skyLightHandle = dlopen(
            "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
            RTLD_LAZY | RTLD_LOCAL
        );
        if (skyLightHandle != NULL) {
            function = (ADCConfigureDisplayEnabledFunction)dlsym(
                skyLightHandle,
                "SLSConfigureDisplayEnabled"
            );
        }
    });
    return function;
}

static NSLock *ADCSharedLock(void) {
    static NSLock *lock;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        lock = [[NSLock alloc] init];
    });
    return lock;
}

static void ADCCopyCFString(CFStringRef value, char *destination, size_t capacity) {
    if (destination == NULL || capacity == 0) {
        return;
    }

    destination[0] = '\0';
    if (value == NULL || CFGetTypeID(value) != CFStringGetTypeID()) {
        return;
    }

    CFStringGetCString(value, destination, (CFIndex)capacity, kCFStringEncodingUTF8);
    destination[capacity - 1] = '\0';
}

static CFTypeRef ADCCopyRecursiveProperty(io_service_t service, CFStringRef key) {
    return IORegistryEntrySearchCFProperty(
        service,
        kIOServicePlane,
        key,
        kCFAllocatorDefault,
        kIORegistryIterateRecursively
    );
}

// A physically connected monitor disabled by the PC profile can be offline
// before this process has opened a DDC transport. WindowServer still lists it.
extern CGError CGSGetDisplayList(CGDisplayCount capacity, CGDirectDisplayID *displays,
                                 CGDisplayCount *count) __attribute__((weak_import));

static int32_t ADCEnumerateDisplays(ADCInternalDisplay *displays, int32_t capacity) {
    if (displays == NULL || capacity <= 0) {
        return ADC_ERROR_INVALID_ARGUMENT;
    }

    CGDirectDisplayID displayIDs[ADC_MAX_DISPLAYS] = {0};
    CGDisplayCount displayCount = 0;
    CGError listError = CGSGetDisplayList != NULL
        ? CGSGetDisplayList(ADC_MAX_DISPLAYS, displayIDs, &displayCount)
        : kCGErrorFailure;
    if (listError != kCGErrorSuccess) {
        listError = CGGetOnlineDisplayList(ADC_MAX_DISPLAYS, displayIDs, &displayCount);
    }
    if (listError != kCGErrorSuccess) {
        return ADC_ERROR_COMMUNICATION;
    }

    int32_t resultCount = 0;
    for (CGDisplayCount index = 0; index < displayCount && resultCount < capacity; index++) {
        CGDirectDisplayID displayID = displayIDs[index];
        CFDictionaryRef displayDictionary = CoreDisplay_DisplayCreateInfoDictionary(displayID);
        if (displayDictionary == NULL) {
            continue;
        }

        CFStringRef uuid = CFDictionaryGetValue(displayDictionary, CFSTR("kCGDisplayUUID"));
        CFStringRef ioLocation = CFDictionaryGetValue(displayDictionary, CFSTR("IODisplayLocation"));
        if (uuid == NULL || ioLocation == NULL) {
            CFRelease(displayDictionary);
            continue;
        }

        io_service_t adapter = IORegistryEntryCopyFromPath(kIOMainPortDefault, ioLocation);
        if (adapter == MACH_PORT_NULL) {
            CFRelease(displayDictionary);
            continue;
        }

        ADCInternalDisplay *output = displays + resultCount;
        memset(output, 0, sizeof(*output));
        output->adapter = adapter;
        output->info.displayID = displayID;
        output->info.serialNumber = CGDisplaySerialNumber(displayID);
        output->info.modelID = CGDisplayModelNumber(displayID);
        output->info.vendorID = CGDisplayVendorNumber(displayID);
        ADCCopyCFString(uuid, output->info.uuid, sizeof(output->info.uuid));

        // Offline displays (and empty display slots) may all have the zero UUID.
        BOOL missingUUID = !output->info.uuid[0] ||
            strcmp(output->info.uuid, "00000000-0000-0000-0000-000000000000") == 0;
        if (output->info.vendorID && output->info.modelID && output->info.serialNumber) {
            snprintf(output->hardwareKey, sizeof(output->hardwareKey), "hw-%u-%u-%u",
                     output->info.vendorID, output->info.modelID, output->info.serialNumber);
            NSString *hardwareKey = [NSString stringWithUTF8String:output->hardwareKey];
            NSString *key = [@"displayUUID." stringByAppendingString:hardwareKey];
            NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
            NSString *remembered = [defaults stringForKey:key];
            if (missingUUID) {
                strlcpy(output->info.uuid, (remembered ?: hardwareKey).UTF8String,
                        sizeof(output->info.uuid));
            } else {
                NSString *current = [NSString stringWithUTF8String:output->info.uuid];
                if (![current isEqualToString:remembered]) {
                    [defaults setObject:current forKey:key];
                }
            }
        } else if (missingUUID) {
            IOObjectRelease(adapter);
            CFRelease(displayDictionary);
            continue;
        }

        CFTypeRef displayAttributes = ADCCopyRecursiveProperty(adapter, CFSTR("DisplayAttributes"));
        if (displayAttributes != NULL && CFGetTypeID(displayAttributes) == CFDictionaryGetTypeID()) {
            CFDictionaryRef attributesDictionary = (CFDictionaryRef)displayAttributes;
            CFDictionaryRef productAttributes = CFDictionaryGetValue(attributesDictionary, CFSTR("ProductAttributes"));
            if (productAttributes != NULL && CFGetTypeID(productAttributes) == CFDictionaryGetTypeID()) {
                ADCCopyCFString(
                    CFDictionaryGetValue(productAttributes, CFSTR("ProductName")),
                    output->info.productName,
                    sizeof(output->info.productName)
                );
                ADCCopyCFString(
                    CFDictionaryGetValue(productAttributes, CFSTR("ManufacturerID")),
                    output->info.manufacturer,
                    sizeof(output->info.manufacturer)
                );
            }
        }

        if (displayAttributes != NULL) {
            CFRelease(displayAttributes);
        }
        CFRelease(displayDictionary);

        if (output->info.productName[0] == '\0') {
            strlcpy(output->info.productName, "Unknown display", sizeof(output->info.productName));
        }

        resultCount++;
    }

    return resultCount;
}

static void ADCReleaseDisplays(ADCInternalDisplay *displays, int32_t count) {
    for (int32_t index = 0; index < count; index++) {
        if (displays[index].adapter != MACH_PORT_NULL) {
            IOObjectRelease(displays[index].adapter);
            displays[index].adapter = MACH_PORT_NULL;
        }
    }
}

static ADCInternalDisplay *ADCFindDisplay(
    ADCInternalDisplay *displays,
    int32_t count,
    const char *displayUUID
) {
    if (displayUUID != NULL && displayUUID[0] != '\0') {
        for (int32_t index = 0; index < count; index++) {
            if (strcasecmp(displays[index].info.uuid, displayUUID) == 0 ||
                strcasecmp(displays[index].hardwareKey, displayUUID) == 0) {
                return displays + index;
            }
        }
        return NULL;
    }

    for (int32_t index = 0; index < count; index++) {
        if (strcmp(displays[index].info.manufacturer, "ACR") == 0 ||
            strstr(displays[index].info.productName, "XV282K") != NULL) {
            return displays + index;
        }
    }

    return count > 0 ? displays : NULL;
}

static Boolean ADCIsMCDP29XXProxy(io_service_t proxy) {
    io_registry_entry_t parent = MACH_PORT_NULL;
    if (IORegistryEntryGetParentEntry(proxy, kIOServicePlane, &parent) != KERN_SUCCESS) {
        return false;
    }

    Boolean isMCDP29XX = false;
    CFTypeRef providerClass = IORegistryEntryCreateCFProperty(
        parent,
        CFSTR("EPICProviderClass"),
        kCFAllocatorDefault,
        0
    );
    if (providerClass != NULL && CFGetTypeID(providerClass) == CFStringGetTypeID()) {
        isMCDP29XX = CFStringCompare(providerClass, CFSTR("AppleDCPMCDP29XX"), 0) == kCFCompareEqualTo;
    }

    if (providerClass != NULL) {
        CFRelease(providerClass);
    }
    IOObjectRelease(parent);
    return isMCDP29XX;
}

static kern_return_t ADCCreateRegistryIterator(io_iterator_t *iterator) {
    io_registry_entry_t root = IORegistryGetRootEntry(kIOMainPortDefault);
    kern_return_t result = IORegistryEntryCreateIterator(
        root,
        kIOServicePlane,
        kIORegistryIterateRecursively,
        iterator
    );
    IOObjectRelease(root);
    return result;
}

static ADCTransport ADCTransportForDisplay(ADCInternalDisplay *display) {
    ADCTransport transport = { .service = NULL, .chipAddress = ADC_DDC_CHIP_ADDRESS };
    if (display == NULL || display->adapter == MACH_PORT_NULL) {
        return transport;
    }

    uint64_t selectedAdapterID = 0;
    if (IORegistryEntryGetRegistryEntryID(display->adapter, &selectedAdapterID) != KERN_SUCCESS) {
        return transport;
    }

    io_iterator_t iterator = MACH_PORT_NULL;
    if (ADCCreateRegistryIterator(&iterator) != KERN_SUCCESS) {
        return transport;
    }

    Boolean framebufferMatchesDisplay = false;
    io_service_t service = MACH_PORT_NULL;
    while ((service = IOIteratorNext(iterator)) != MACH_PORT_NULL) {
        if (IOObjectConformsTo(service, "IOMobileFramebuffer")) {
            uint64_t framebufferID = 0;
            framebufferMatchesDisplay =
                IORegistryEntryGetRegistryEntryID(service, &framebufferID) == KERN_SUCCESS &&
                framebufferID == selectedAdapterID;
            IOObjectRelease(service);
            continue;
        }

        io_name_t name = {0};
        IORegistryEntryGetName(service, name);
        if (!framebufferMatchesDisplay || strcmp(name, "DCPAVServiceProxy") != 0) {
            IOObjectRelease(service);
            continue;
        }

        CFTypeRef location = ADCCopyRecursiveProperty(service, CFSTR("Location"));
        Boolean isExternal = location != NULL &&
            CFGetTypeID(location) == CFStringGetTypeID() &&
            CFStringCompare(location, CFSTR("External"), 0) == kCFCompareEqualTo;
        if (location != NULL) {
            CFRelease(location);
        }

        if (!isExternal) {
            IOObjectRelease(service);
            continue;
        }

        IOAVServiceRef avService = IOAVServiceCreateWithService(kCFAllocatorDefault, service);
        if (avService != NULL) {
            transport.service = avService;
            transport.includeReadSource = strcmp(display->info.manufacturer, "BNQ") == 0;
            transport.chipAddress = ADCIsMCDP29XXProxy(service)
                ? ADC_DDC_MCDP29XX_CHIP_ADDRESS
                : ADC_DDC_CHIP_ADDRESS;
            IOObjectRelease(service);
            break;
        }

        IOObjectRelease(service);
    }

    IOObjectRelease(iterator);
    return transport;
}

static void ADCCacheTransport(ADCTransport transport, const char *displayUUID) {
    if (transport.service == NULL || displayUUID == NULL || displayUUID[0] == '\0') {
        return;
    }

    if (ADCCachedTransport.service != NULL) {
        CFRelease(ADCCachedTransport.service);
    }
    ADCCachedTransport.service = CFRetain(transport.service);
    ADCCachedTransport.chipAddress = transport.chipAddress;
    ADCCachedTransport.includeReadSource = transport.includeReadSource;
    strlcpy(ADCCachedDisplayUUID, displayUUID, sizeof(ADCCachedDisplayUUID));
}

static ADCTransport ADCCopyCachedTransport(const char *displayUUID) {
    ADCTransport transport = { .service = NULL, .chipAddress = ADC_DDC_CHIP_ADDRESS };
    if (ADCCachedTransport.service == NULL || displayUUID == NULL ||
        strcasecmp(ADCCachedDisplayUUID, displayUUID) != 0) {
        return transport;
    }

    transport.service = CFRetain(ADCCachedTransport.service);
    transport.chipAddress = ADCCachedTransport.chipAddress;
    transport.includeReadSource = ADCCachedTransport.includeReadSource;
    return transport;
}

static ADCTransport ADCResolveTransport(const char *displayUUID) {
    ADCInternalDisplay displays[ADC_MAX_DISPLAYS] = {0};
    int32_t count = ADCEnumerateDisplays(displays, ADC_MAX_DISPLAYS);
    if (count > 0) {
        ADCInternalDisplay *display = ADCFindDisplay(displays, count, displayUUID);
        if (display != NULL) {
            Boolean keepForInputSwitch = strcmp(display->info.manufacturer, "ACR") == 0 ||
                strstr(display->info.productName, "XV282K") != NULL;
            ADCTransport transport = ADCTransportForDisplay(display);
            ADCReleaseDisplays(displays, count);
            if (transport.service != NULL) {
                if (keepForInputSwitch) { ADCCacheTransport(transport, displayUUID); }
                return transport;
            }
        } else {
            ADCReleaseDisplays(displays, count);
        }
    }

    // A monitor can disappear from CGGetOnlineDisplayList after switching to
    // another host. Keep the already-open DCP transport so the menu-bar app can
    // still issue the command that switches it back.
    return ADCCopyCachedTransport(displayUUID);
}

static uint8_t ADCReadChecksum(const uint8_t *bytes, size_t length) {
    uint8_t checksum = 0x50;
    for (size_t index = 0; index < length; index++) {
        checksum ^= bytes[index];
    }
    return checksum;
}

static int32_t ADCReadVCPWithTransport(
    ADCTransport transport,
    uint8_t featureCode,
    ADCVCPReply *reply
) {
    uint8_t request[4] = {0x82, 0x01, featureCode, 0x00};
    request[3] = 0x6E ^ (transport.includeReadSource ? ADC_DDC_ADDRESS : 0) ^ request[0] ^ request[1] ^ request[2];

    int32_t readError = ADC_ERROR_COMMUNICATION;
    for (int attempt = 0; attempt < 3; attempt++) {
        IOReturn writeResult = IOAVServiceWriteI2C(
            transport.service,
            transport.chipAddress,
            ADC_DDC_ADDRESS,
            request,
            sizeof(request)
        );
        if (writeResult != kIOReturnSuccess) {
            usleep(30000 * (attempt + 1));
            continue;
        }

        usleep(transport.chipAddress == ADC_DDC_MCDP29XX_CHIP_ADDRESS ? 60000 : 30000);

        uint8_t response[11] = {0};
        IOReturn readResult = IOAVServiceReadI2C(
            transport.service,
            transport.chipAddress,
            0,
            response,
            sizeof(response)
        );
        if (readResult != kIOReturnSuccess) {
            usleep(30000 * (attempt + 1));
            continue;
        }

        // GW2406Z answers the legacy Get-VCP checksum with a DDC null
        // message. Retry including the source address; XV282K uses the
        // legacy checksum. Neither variant relaxes response validation.
        if (response[0] == 0x6E && response[1] == 0x80) {
            request[3] ^= ADC_DDC_ADDRESS;
            usleep(30000 * (attempt + 1));
            continue;
        }
        if (response[0] != 0x6E || response[2] != 0x02 || response[4] != featureCode ||
            ADCReadChecksum(response, 11) != 0) {
            readError = ADC_ERROR_MALFORMED_REPLY;
            usleep(30000 * (attempt + 1));
            continue;
        }

        reply->resultCode = response[3];
        reply->featureCode = response[4];
        reply->typeCode = response[5];
        reply->maximumValue = (uint16_t)((response[6] << 8) | response[7]);
        reply->currentValue = (uint16_t)((response[8] << 8) | response[9]);

        return response[3] == 0 ? ADC_SUCCESS : ADC_ERROR_UNSUPPORTED_FEATURE;
    }

    return readError;
}

static int32_t ADCWriteVCPWithTransport(ADCTransport transport, uint8_t featureCode, uint16_t value) {
    uint8_t request[6] = {
        0x84,
        0x03,
        featureCode,
        (uint8_t)(value >> 8),
        (uint8_t)(value & 0xFF),
        0x00
    };
    request[5] = 0x6E ^ ADC_DDC_ADDRESS ^ request[0] ^ request[1] ^ request[2] ^ request[3] ^ request[4];

    IOReturn lastResult = kIOReturnError;
    for (int attempt = 0; attempt < 2; attempt++) {
        usleep(15000);
        lastResult = IOAVServiceWriteI2C(
            transport.service,
            transport.chipAddress,
            ADC_DDC_ADDRESS,
            request,
            sizeof(request)
        );
        if (lastResult != kIOReturnSuccess) {
            return ADC_ERROR_COMMUNICATION;
        }
    }

    return ADC_SUCCESS;
}

int32_t ADCListDisplays(ADCDisplayInfo *displays, int32_t capacity) {
    if (displays == NULL || capacity <= 0) {
        return ADC_ERROR_INVALID_ARGUMENT;
    }

    [ADCSharedLock() lock];

    ADCInternalDisplay internalDisplays[ADC_MAX_DISPLAYS] = {0};
    int32_t count = ADCEnumerateDisplays(internalDisplays, MIN(capacity, ADC_MAX_DISPLAYS));
    if (count > 0) {
        for (int32_t index = 0; index < count; index++) {
            displays[index] = internalDisplays[index].info;
        }
        ADCReleaseDisplays(internalDisplays, count);
    }

    [ADCSharedLock() unlock];
    return count;
}

int32_t ADCReadVCP(const char *displayUUID, uint8_t featureCode, ADCVCPReply *reply) {
    if (reply == NULL || featureCode == 0) {
        return ADC_ERROR_INVALID_ARGUMENT;
    }

    [ADCSharedLock() lock];

    ADCTransport transport = ADCResolveTransport(displayUUID);
    if (transport.service == NULL) {
        [ADCSharedLock() unlock];
        return ADC_ERROR_TRANSPORT_NOT_FOUND;
    }

    int32_t result = ADCReadVCPWithTransport(transport, featureCode, reply);
    CFRelease(transport.service);
    [ADCSharedLock() unlock];
    return result;
}

int32_t ADCWriteVCP(const char *displayUUID, uint8_t featureCode, uint16_t value) {
    if (featureCode == 0) {
        return ADC_ERROR_INVALID_ARGUMENT;
    }

    [ADCSharedLock() lock];

    ADCTransport transport = ADCResolveTransport(displayUUID);
    if (transport.service == NULL) {
        [ADCSharedLock() unlock];
        return ADC_ERROR_TRANSPORT_NOT_FOUND;
    }

    int32_t result = ADCWriteVCPWithTransport(transport, featureCode, value);
    CFRelease(transport.service);
    [ADCSharedLock() unlock];
    return result;
}

bool ADCDisplayIsActive(uint32_t displayID) {
    return CGDisplayIsActive((CGDirectDisplayID)displayID);
}

int32_t ADCSetDisplayEnabled(uint32_t displayID, bool enabled) {
    // Serialize configuration changes with DDC traffic and other callers.
    [ADCSharedLock() lock];
    @try {
    ADCConfigureDisplayEnabledFunction configureDisplayEnabled = ADCDisplayEnabledFunction();
    if (configureDisplayEnabled == NULL) {
        return ADC_ERROR_DISPLAY_API_UNAVAILABLE;
    }

    CGDirectDisplayID target = (CGDirectDisplayID)displayID;
    // Input switching can briefly report an inactive display before macOS
    // brings the link back. Do not mistake that transient for a disconnect.
    if (!enabled) {
        usleep(300000);
    }
    if (CGDisplayIsActive(target) == enabled) {
        return ADC_SUCCESS;
    }

    if (!enabled) {
        CGDisplayCount activeCount = 0;
        CGError listError = CGGetActiveDisplayList(0, NULL, &activeCount);
        if (listError != kCGErrorSuccess) {
            return ADC_ERROR_DISPLAY_CONFIGURATION;
        }
        if (activeCount <= 1) {
            return ADC_ERROR_LAST_ACTIVE_DISPLAY;
        }
    }

    CGDisplayConfigRef config = NULL;
    CGError result = CGBeginDisplayConfiguration(&config);
    if (result != kCGErrorSuccess || config == NULL) {
        return ADC_ERROR_DISPLAY_CONFIGURATION;
    }

    result = configureDisplayEnabled(config, target, enabled);
    if (result != kCGErrorSuccess) {
        CGCancelDisplayConfiguration(config);
        return ADC_ERROR_DISPLAY_CONFIGURATION;
    }

    // App-only scope is deliberately fail-safe: WindowServer restores the
    // display automatically if the menu-bar app exits or crashes.
    result = CGCompleteDisplayConfiguration(config, kCGConfigureForAppOnly);
    if (result != kCGErrorSuccess) {
        return ADC_ERROR_DISPLAY_CONFIGURATION;
    }
    for (int attempt = 0; attempt < 20; attempt++) {
        usleep(100000);
        if (CGDisplayIsActive(target) == enabled) {
            return ADC_SUCCESS;
        }
    }
    return ADC_ERROR_DISPLAY_CONFIGURATION;
    } @finally {
        [ADCSharedLock() unlock];
    }
}

const char *ADCErrorDescription(int32_t errorCode) {
    switch (errorCode) {
        case ADC_SUCCESS:
            return "Success";
        case ADC_ERROR_INVALID_ARGUMENT:
            return "Invalid argument";
        case ADC_ERROR_DISPLAY_NOT_FOUND:
            return "Display not found";
        case ADC_ERROR_TRANSPORT_NOT_FOUND:
            return "DDC transport not found";
        case ADC_ERROR_COMMUNICATION:
            return "DDC communication failed";
        case ADC_ERROR_MALFORMED_REPLY:
            return "Malformed DDC reply";
        case ADC_ERROR_UNSUPPORTED_FEATURE:
            return "Unsupported VCP feature";
        case ADC_ERROR_DISPLAY_CONFIGURATION:
            return "macOS could not change the active display configuration";
        case ADC_ERROR_DISPLAY_API_UNAVAILABLE:
            return "Display disconnect is unavailable on this macOS version";
        case ADC_ERROR_LAST_ACTIVE_DISPLAY:
            return "Refusing to disconnect the last active display";
        default:
            return "Unknown DDC error";
    }
}
