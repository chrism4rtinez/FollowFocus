/*
 * FollowFocus
 * Some pieces of the code are based on
 * AutoRaise by sbmpost
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License along
 * with this program; if not, write to the Free Software Foundation, Inc.,
 * 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
 */

// g++ -O2 -Wall -fobjc-arc -D"NS_FORMAT_ARGUMENT(A)=" -o FollowFocus FollowFocus.mm \
//   -framework AppKit && ./FollowFocus

#include <ApplicationServices/ApplicationServices.h>
#include <CoreFoundation/CoreFoundation.h>
#include <Foundation/Foundation.h>
#include <AppKit/AppKit.h>
#include <Carbon/Carbon.h>
#include <libproc.h>

#define FollowFocus_VERSION "1.0.0"
#define STACK_THRESHOLD 20

#ifdef EXPERIMENTAL_FOCUS_FIRST
#if SKYLIGHT_AVAILABLE
// Focus first is an experimental feature that can break easily across different OSX
// versions. It relies on the private Skylight api. As such, there are absolutely no
// guarantees that this feature will keep on working in future versions of FollowFocus.
#define FOCUS_FIRST
#else
#pragma message "Skylight api is unavailable, Focus First is disabled"
#endif
#endif

// It seems OSX Monterey introduced a transparent 3 pixel border around each window. This
// means that when two windows are visually precisely connected and not overlapping, in
// reality they are. Consequently one has to move the mouse 3 pixels further out of the
// visual area to make the connected window raise. This new OSX 'feature' also introduces
// unwanted raising of windows when visually connected to the top menu bar. To solve this
// we correct the mouse position before determining which window is underneath the mouse.
#define WINDOW_CORRECTION 3
#define MENUBAR_CORRECTION 8
static CGPoint oldCorrectedPoint = {0, 0};

// An activate delay of about 10 microseconds is just high enough to ensure we always
// find the latest focused (main)window. This value should be kept as low as possible.
#define ACTIVATE_DELAY_MS 10

#define SCALE_DELAY_MS 400 // The moment the mouse scaling should start, feel free to modify.
#define SCALE_DURATION_MS (SCALE_DELAY_MS+600) // Mouse scale duration, feel free to modify.

#ifdef FOCUS_FIRST
#define kCPSUserGenerated 0x200
extern "C" CGError SLPSPostEventRecordTo(ProcessSerialNumber *psn, uint8_t *bytes);
extern "C" CGError _SLPSSetFrontProcessWithOptions(
  ProcessSerialNumber *psn, uint32_t wid, uint32_t mode);

/* -----------Could these be a replacement for GetProcessForPID?-----------
extern "C" int SLSMainConnectionID(void);
extern "C" CGError SLSGetWindowOwner(int cid, uint32_t wid, int *wcid);
extern "C" CGError SLSGetConnectionPSN(int cid, ProcessSerialNumber *psn);
int element_connection;
SLSGetWindowOwner(SLSMainConnectionID(), window_id, &element_connection);
SLSGetConnectionPSN(element_connection, &window_psn);
-------------------------------------------------------------------------*/
#endif

typedef int CGSConnectionID;
extern "C" CGSConnectionID CGSMainConnectionID(void);
extern "C" CGError CGSSetCursorScale(CGSConnectionID connectionId, float scale);
extern "C" CGError CGSGetCursorScale(CGSConnectionID connectionId, float *scale);
extern "C" AXError _AXUIElementGetWindow(AXUIElementRef, CGWindowID *out);
// Above methods are undocumented and subjective to incompatible changes

#ifdef FOCUS_FIRST
static int raiseDelayCount = 0;
static pid_t lastFocusedWindow_pid;
static AXUIElementRef _lastFocusedWindow = NULL;
#endif

CFMachPortRef eventTap = NULL;
static char pathBuffer[PROC_PIDPATHINFO_MAXSIZE];
static bool activated_by_task_switcher = false;
static AXUIElementRef _accessibility_object = AXUIElementCreateSystemWide();
static AXUIElementRef _previousFinderWindow = NULL;
static AXUIElementRef _dock_app = NULL;
static NSArray * ignoreApps = NULL;
static NSArray * ignoreTitles = NULL;
static NSArray * stayFocusedBundleIds = NULL;
static NSArray * const mainWindowAppsWithoutTitle = @[@"Photos", @"Calculator", @"Podcasts", @"Stickies Pro", @"Reeder"];
static NSString * const DockBundleId = @"com.apple.dock";
static NSString * const FinderBundleId = @"com.apple.finder";
static NSString * const LittleSnitchBundleId = @"at.obdev.littlesnitch";
static NSString * const AssistiveControl = @"AssistiveControl";
static NSString * const BartenderBar = @"Bartender Bar";
static NSString * const AppStoreSearchResults = @"Search results";
static NSString * const Untitled = @"Untitled"; // OSX Email search
static NSString * const Zim = @"Zim";
static NSString * const XQuartz = @"XQuartz";
static NSString * const Finder = @"Finder";
static NSString * const NoTitle = @"";
static CGPoint desktopOrigin = {0, 0};
static CGPoint oldPoint = {0, 0};
static bool propagateMouseMoved = false;
static bool ignoreSpaceChanged = false;
static bool invertIgnoreApps = false;
static bool spaceHasChanged = false;
static bool appWasActivated = false;
static bool altTaskSwitcher = false;
static bool warpMouse = false;
static bool verbose = false;
static float warpX = 0.5;
static float warpY = 0.5;
static float oldScale = 1;
static float cursorScale = 2;
static float mouseDelta = 0;
static int ignoreTimes = 0;
static int raiseTimes = 0;
static int delayTicks = 0;
static int delayCount = 0;
static int pollMillis = 0;
static int disableKey = 0;

// SECURITY IMPROVEMENT: Add timeout mechanism for potentially hanging API calls
id performWithTimeout(dispatch_block_t block, double timeoutInSeconds) {
    __block id result = nil;
    __block BOOL completed = NO;
    
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        @autoreleasepool {
            block();
            completed = YES;
        }
    });
    
    NSDate *timeoutDate = [NSDate dateWithTimeIntervalSinceNow:timeoutInSeconds];
    while (!completed && [timeoutDate timeIntervalSinceNow] > 0) {
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
    
    if (!completed && verbose) {
        NSLog(@"API call timed out after %.2f seconds", timeoutInSeconds);
    }
    
    return result;
}

// SECURITY IMPROVEMENT: Add bounds checking for mouse points
CGPoint validatePoint(CGPoint point) {
    // Get screen dimensions and ensure point is within valid bounds
    NSArray *screens = [NSScreen screens];
    if ([screens count] == 0) {
        return point; // Return original if no screens available
    }
    
    CGFloat minX = CGFLOAT_MAX, minY = CGFLOAT_MAX;
    CGFloat maxX = CGFLOAT_MIN, maxY = CGFLOAT_MIN;
    
    for (NSScreen *screen in screens) {
        CGRect frame = [screen frame];
        minX = MIN(minX, NSMinX(frame));
        minY = MIN(minY, NSMinY(frame));
        maxX = MAX(maxX, NSMaxX(frame));
        maxY = MAX(maxY, NSMaxY(frame));
    }
    
    // Apply bounds
    point.x = MAX(minX, MIN(point.x, maxX));
    point.y = MAX(minY, MIN(point.y, maxY));
    
    return point;
}

// SECURITY IMPROVEMENT: Add sanitization for configuration values
id sanitizeConfigValue(id value, NSString *key) {
    if ([key isEqualToString:@"delay"] || [key isEqualToString:@"focusDelay"] || 
        [key isEqualToString:@"pollMillis"]) {
        // Ensure numeric values are within reasonable ranges
        int intValue = [value intValue];
        if (intValue < 0) return @0;
        if ([key isEqualToString:@"pollMillis"] && intValue < 20) return @20;
        if ([key isEqualToString:@"pollMillis"] && intValue > 1000) return @1000;
        return @(intValue);
    } else if ([key isEqualToString:@"warpX"] || [key isEqualToString:@"warpY"]) {
        // Ensure warp values are between 0 and 1
        float floatValue = [value floatValue];
        return @(MAX(0.0, MIN(1.0, floatValue)));
    } else if ([key isEqualToString:@"scale"]) {
        // Ensure scale is reasonable
        float floatValue = [value floatValue];
        return @(MAX(1.0, MIN(10.0, floatValue)));
    } else if ([key isEqualToString:@"mouseDelta"]) {
        // Ensure mouse delta is non-negative
        float floatValue = [value floatValue];
        return @(MAX(0.0, floatValue));
    } else if ([key isEqualToString:@"disableKey"]) {
        // Validate disable key options
        if (![value isEqual:@"control"] && ![value isEqual:@"option"] && 
            ![value isEqual:@"disabled"]) {
            return @"disabled";
        }
    }
    return value;
}

// SECURITY IMPROVEMENT: Show warning for private API usage
void showPrivateAPIWarning() {
    NSLog(@"WARNING: This application uses private APIs that may change in future macOS versions.");
    NSLog(@"Apple may restrict or remove these APIs in system updates, potentially breaking functionality.");
    
    // Show a notification to the user if notifications are available
    if (NSClassFromString(@"NSUserNotification")) {
        NSUserNotification *notification = [[NSUserNotification alloc] init];
        notification.title = @"FollowFocus Security Notice";
        notification.informativeText = @"This app uses private macOS APIs which may pose security risks. See documentation for details.";
        notification.soundName = NSUserNotificationDefaultSoundName;
        [[NSUserNotificationCenter defaultUserNotificationCenter] deliverNotification:notification];
    }
}

// SECURITY IMPROVEMENT: Add periodic permission check
void checkAccessibilityPermissions() {
    static dispatch_source_t timer;
    
    if (!timer) {
        timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
        dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC), 
                                 30 * NSEC_PER_SEC, 1 * NSEC_PER_SEC);
        
        dispatch_source_set_event_handler(timer, ^{
            NSDictionary *options = @{(id)CFBridgingRelease(kAXTrustedCheckOptionPrompt): @NO};
            bool trusted = AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)options);
            
            if (!trusted) {
                NSLog(@"WARNING: Accessibility permission was revoked. Some features may not work.");
                
                if (NSClassFromString(@"NSUserNotification")) {
                    NSUserNotification *notification = [[NSUserNotification alloc] init];
                    notification.title = @"FollowFocus Permission Alert";
                    notification.informativeText = @"Accessibility permission was revoked. Please re-enable in System Preferences.";
                    notification.soundName = NSUserNotificationDefaultSoundName;
                    [[NSUserNotificationCenter defaultUserNotificationCenter] deliverNotification:notification];
                }
            }
        });
        
        dispatch_resume(timer);
    }
}

//----------------------------------------yabai focus only methods------------------------------------------

#ifdef FOCUS_FIRST
// The two methods below, starting with "window_manager" were copied from
// https://github.com/koekeishiya/yabai and slightly modified. See also:
// https://github.com/Hammerspoon/hammerspoon/issues/370#issuecomment-545545468
void window_manager_make_key_window(ProcessSerialNumber * _window_psn, uint32_t window_id) {
    uint8_t * bytes = (uint8_t *) malloc(0xf8);
    memset(bytes, 0, 0xf8);

    bytes[0x04] = 0xf8;
    bytes[0x3a] = 0x10;

    memcpy(bytes + 0x3c, &window_id, sizeof(uint32_t));
    memset(bytes + 0x20, 0xFF, 0x10);

    bytes[0x08] = 0x01;
    SLPSPostEventRecordTo(_window_psn, bytes);

    bytes[0x08] = 0x02;
    SLPSPostEventRecordTo(_window_psn, bytes);
    free(bytes);
}

void window_manager_focus_window_without_raise(
    ProcessSerialNumber * _window_psn, uint32_t window_id,
    ProcessSerialNumber * _focused_window_psn, uint32_t focused_window_id
) {
    if (verbose) { NSLog(@"Focus"); }
    if (_focused_window_psn) {
        Boolean same_process;
        SameProcess(_window_psn, _focused_window_psn, &same_process);
        if (same_process) {
            if (verbose) { NSLog(@"Same process"); }
            uint8_t * bytes = (uint8_t *) malloc(0xf8);
            memset(bytes, 0, 0xf8);

            bytes[0x04] = 0xf8;
            bytes[0x08] = 0x0d;
            memcpy(bytes + 0x3c, &focused_window_id, sizeof(uint32_t));
            memcpy(bytes + 0x3c, &window_id, sizeof(uint32_t));

            bytes[0x8a] = 0x02;
            SLPSPostEventRecordTo(_focused_window_psn, bytes);

            // @hack
            // Artificially delay the activation by 1ms. This is necessary
            // because some applications appear to be confused if both of
            // the events appear instantaneously.
            usleep(10000);

            bytes[0x8a] = 0x01;
            SLPSPostEventRecordTo(_window_psn, bytes);
            free(bytes);
        }
    }

    _SLPSSetFrontProcessWithOptions(_window_psn, window_id, kCPSUserGenerated);
    window_manager_make_key_window(_window_psn, window_id);
}
#endif

//---------------------------------------------helper methods-----------------------------------------------

inline void activate(pid_t pid) {
    if (verbose) { NSLog(@"Activate"); }
#ifdef OLD_ACTIVATION_METHOD
    ProcessSerialNumber process;
    OSStatus error = GetProcessForPID(pid, &process);
    if (!error) { SetFrontProcessWithOptions(&process, kSetFrontProcessFrontWindowOnly); }
#else
    // Note activateWithOptions does not work properly on OSX 11.1
    NSRunningApplication *app = [NSRunningApplication runningApplicationWithProcessIdentifier: pid];
    if (app) {
        [app activateWithOptions: NSApplicationActivateIgnoringOtherApps];
    } else if (verbose) {
        NSLog(@"Failed to find running application with pid: %d", pid);
    }
#endif
}

inline void raiseAndActivate(AXUIElementRef _window, pid_t window_pid) {
    if (verbose) { NSLog(@"Raise"); }
    if (_window && AXUIElementPerformAction(_window, kAXRaiseAction) == kAXErrorSuccess) {
        activate(window_pid);
    } else if (verbose) {
        NSLog(@"Failed to raise window");
    }
}

// TODO: does not take into account different languages
inline bool titleEquals(AXUIElementRef _element, NSArray * _titles, NSArray * _patterns = NULL, bool logTitle = false) {
    if (!_element) return false;
    
    bool equal = false;
    CFStringRef _elementTitle = NULL;
    AXError error = AXUIElementCopyAttributeValue(_element, kAXTitleAttribute, (CFTypeRef *) &_elementTitle);
    
    if (error != kAXErrorSuccess && verbose) {
        NSLog(@"Error getting title: %d", error);
    }
    
    if (logTitle) { NSLog(@"element title: %@", _elementTitle); }
    if (_elementTitle) {
        NSString * _title = (__bridge NSString *) _elementTitle;
        equal = [_titles containsObject: _title];
        if (!equal && _patterns) {
            for (NSString * _pattern in _patterns) {
                equal = [_title rangeOfString:_pattern options:NSRegularExpressionSearch].location != NSNotFound;
                if (equal) { break; }
            }
        }
        CFRelease(_elementTitle);
    } else { equal = [_titles containsObject: NoTitle]; }
    return equal;
}

inline bool dock_active() {
    if (!_dock_app) return false;
    
    bool active = false;
    AXUIElementRef _focusedUIElement = NULL;
    AXError error = AXUIElementCopyAttributeValue(_dock_app, kAXFocusedUIElementAttribute, (CFTypeRef *) &_focusedUIElement);
    
    if (error != kAXErrorSuccess && verbose) {
        NSLog(@"Error checking dock active: %d", error);
    }
    
    if (_focusedUIElement) {
        active = true;
        if (verbose) { NSLog(@"Dock is active"); }
        CFRelease(_focusedUIElement);
    }
    return active;
}

// SECURITY IMPROVEMENT: Enhanced topwindow function with better memory management
NSDictionary * topwindow(CGPoint point) {
    NSDictionary * top_window = NULL;
    
    @autoreleasepool {
        NSArray * window_list = (NSArray *) CFBridgingRelease(CGWindowListCopyWindowInfo(
            kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements,
            kCGNullWindowID));

        for (NSDictionary * window in window_list) {
            NSDictionary * window_bounds_dict = window[(NSString *) CFBridgingRelease(kCGWindowBounds)];

            if (![window[(__bridge id) kCGWindowLayer] isEqual: @0]) { continue; }

            NSRect window_bounds = NSMakeRect(
                [window_bounds_dict[@"X"] intValue],
                [window_bounds_dict[@"Y"] intValue],
                [window_bounds_dict[@"Width"] intValue],
                [window_bounds_dict[@"Height"] intValue]);

            if (NSPointInRect(NSPointFromCGPoint(point), window_bounds)) {
                top_window = [window copy]; // Use a retained copy
                break;
            }
        }
    }

    return top_window;
}

AXUIElementRef fallback(CGPoint point) {
    if (verbose) { NSLog(@"Fallback"); }
    AXUIElementRef _window = NULL;
    NSDictionary * top_window = topwindow(point);
    if (top_window) {
        CFTypeRef _windows_cf = NULL;
        pid_t pid = [top_window[(__bridge id) kCGWindowOwnerPID] intValue];
        AXUIElementRef _window_owner = AXUIElementCreateApplication(pid);
        AXError error = AXUIElementCopyAttributeValue(_window_owner, kAXWindowsAttribute, &_windows_cf);
        
        if (error != kAXErrorSuccess && verbose) {
            NSLog(@"Error getting windows: %d", error);
        }
        
        CFRelease(_window_owner);
        if (_windows_cf) {
            NSArray * application_windows = (NSArray *) CFBridgingRelease(_windows_cf);
            CGWindowID top_window_id = [top_window[(__bridge id) kCGWindowNumber] intValue];
            if (top_window_id) {
                for (id application_window in application_windows) {
                    CGWindowID application_window_id;
                    AXUIElementRef application_window_ax =
                        (__bridge AXUIElementRef) application_window;
                    if (_AXUIElementGetWindow(
                        application_window_ax,
                        &application_window_id) == kAXErrorSuccess) {
                        if (application_window_id == top_window_id) {
                            _window = application_window_ax;
                            CFRetain(_window);
                            break;
                        }
                    }
                }
            }
        } else {
            activate(pid);
        }
    }

    return _window;
}

AXUIElementRef get_raisable_window(AXUIElementRef _element, CGPoint point, int count) {
    AXUIElementRef _window = NULL;
    if (_element) {
        if (count >= STACK_THRESHOLD) {
            if (verbose) {
                NSLog(@"Stack threshold reached");
                pid_t application_pid;
                if (AXUIElementGetPid(_element, &application_pid) == kAXErrorSuccess) {
                    proc_pidpath(application_pid, pathBuffer, sizeof(pathBuffer));
                    NSLog(@"Application path: %s", pathBuffer);
                }
            }
            CFRelease(_element);
        } else {
            CFStringRef _element_role = NULL;
            AXError error = AXUIElementCopyAttributeValue(_element, kAXRoleAttribute, (CFTypeRef *) &_element_role);
            
            if (error != kAXErrorSuccess && verbose) {
                NSLog(@"Error getting role: %d", error);
            }
            
            bool check_attributes = !_element_role;
            if (_element_role) {
                if (CFEqual(_element_role, kAXDockItemRole) ||
                    CFEqual(_element_role, kAXMenuItemRole) ||
                    CFEqual(_element_role, kAXMenuRole) ||
                    CFEqual(_element_role, kAXMenuBarRole) ||
                    CFEqual(_element_role, kAXMenuBarItemRole)) {
                    CFRelease(_element_role);
                    CFRelease(_element);
                } else if (
                    CFEqual(_element_role, kAXWindowRole) ||
                    CFEqual(_element_role, kAXSheetRole) ||
                    CFEqual(_element_role, kAXDrawerRole)) {
                    CFRelease(_element_role);
                    _window = _element;
                } else if (CFEqual(_element_role, kAXApplicationRole)) {
                    CFRelease(_element_role);
                    if (titleEquals(_element, @[XQuartz])) {
                        pid_t application_pid;
                        if (AXUIElementGetPid(_element, &application_pid) == kAXErrorSuccess) {
                            pid_t frontmost_pid = [[[NSWorkspace sharedWorkspace]
                                frontmostApplication] processIdentifier];
                            if (application_pid != frontmost_pid) {
                                // Focus and/or raising is the responsibility of XQuartz.
                                // As such FollowFocus features (delay/warp) do not apply.
                                activate(application_pid);
                            }
                        }
                        CFRelease(_element);
                    } else { check_attributes = true; }
                } else {
                    CFRelease(_element_role);
                    check_attributes = true;
                }
            }

            if (check_attributes) {
                AXError error = AXUIElementCopyAttributeValue(_element, kAXParentAttribute, (CFTypeRef *) &_window);
                
                if (error != kAXErrorSuccess && verbose) {
                    NSLog(@"Error getting parent: %d", error);
                }
                
                bool no_parent = !_window;
                _window = get_raisable_window(_window, point, ++count);
                if (!_window) {
                    error = AXUIElementCopyAttributeValue(_element, kAXWindowAttribute, (CFTypeRef *) &_window);
                    
                    if (error != kAXErrorSuccess && verbose) {
                        NSLog(@"Error getting window: %d", error);
                    }
                    
                    if (!_window && no_parent) { _window = fallback(point); }
                }
                CFRelease(_element);
            }
        }
    }

    return _window;
}

AXUIElementRef get_mousewindow(CGPoint point) {
    AXUIElementRef _element = NULL;
    AXError error = AXUIElementCopyElementAtPosition(_accessibility_object, point.x, point.y, &_element);

    AXUIElementRef _window = NULL;
    if (_element) {
        _window = get_raisable_window(_element, point, 0);
    } else if (error == kAXErrorCannotComplete || error == kAXErrorNotImplemented) {
        // fallback, happens for apps that do not support the Accessibility API
        if (verbose) { NSLog(@"Copy element: no accessibility support"); }
        _window = fallback(point);
    } else if (error == kAXErrorNoValue) {
        // fallback, happens sometimes when switching to another app (with cmd-tab)
        if (verbose) { NSLog(@"Copy element: no value"); }
        _window = fallback(point);
    } else if (error == kAXErrorAttributeUnsupported) {
        // no fallback, happens when hovering into volume/wifi menubar window
        if (verbose) { NSLog(@"Copy element: attribute unsupported"); }
    } else if (error == kAXErrorFailure) {
        // no fallback, happens when hovering over the menubar itself
        if (verbose) { NSLog(@"Copy element: failure"); }
    } else if (error == kAXErrorIllegalArgument) {
        // no fallback, happens in (Open, Save) dialogs
        if (verbose) { NSLog(@"Copy element: illegal argument"); }
    } else if (verbose) {
        NSLog(@"Copy element: AXError %d", error);
    }

    if (verbose) {
        if (_window) {
            CFStringRef _windowTitle = NULL;
            AXUIElementCopyAttributeValue(_window, kAXTitleAttribute, (CFTypeRef *) &_windowTitle);
            NSLog(@"Mouse window: %@", _windowTitle);
            if (_windowTitle) { CFRelease(_windowTitle); }
        } else { NSLog(@"No raisable window"); }
    }

    return _window;
}

// SECURITY IMPROVEMENT: Enhanced get_mousepoint with improved error handling
CGPoint get_mousepoint(AXUIElementRef _window) {
    CGPoint mousepoint = {0, 0};
    
    if (!_window) {
        if (verbose) { NSLog(@"Warning: NULL window reference passed to get_mousepoint"); }
        return mousepoint;
    }
    
    AXValueRef _size = NULL;
    AXValueRef _pos = NULL;
    AXError sizeError = AXUIElementCopyAttributeValue(_window, kAXSizeAttribute, (CFTypeRef *) &_size);
    
    if (sizeError != kAXErrorSuccess) {
        if (verbose) { NSLog(@"Error getting window size: %d", sizeError); }
        return mousepoint;
    }
    
    if (_size) {
        AXError posError = AXUIElementCopyAttributeValue(_window, kAXPositionAttribute, (CFTypeRef *) &_pos);
        
        if (posError != kAXErrorSuccess) {
            if (verbose) { NSLog(@"Error getting window position: %d", posError); }
            CFRelease(_size);
            return mousepoint;
        }
        
        if (_pos) {
            CGSize cg_size;
            CGPoint cg_pos;
            if (AXValueGetValue(_size, (AXValueType)kAXValueCGSizeType, &cg_size) &&
                AXValueGetValue(_pos, (AXValueType)kAXValueCGPointType, &cg_pos)) {
                mousepoint.x = cg_pos.x + (cg_size.width * warpX);
                mousepoint.y = cg_pos.y + (cg_size.height * warpY);
                
                // Validate the calculated point
                mousepoint = validatePoint(mousepoint);
            }
            CFRelease(_pos);
        }
        CFRelease(_size);
    }
    
    return mousepoint;
}

bool contained_within(AXUIElementRef _window1, AXUIElementRef _window2) {
    if (!_window1 || !_window2) return false;
    
    bool contained = false;
    AXValueRef _size1 = NULL;
    AXValueRef _size2 = NULL;
    AXValueRef _pos1 = NULL;
    AXValueRef _pos2 = NULL;

    AXError error = AXUIElementCopyAttributeValue(_window1, kAXSizeAttribute, (CFTypeRef *) &_size1);
    if (error != kAXErrorSuccess) {
        if (verbose) { NSLog(@"Error getting window1 size: %d", error); }
        return false;
    }
    
    if (_size1) {
        error = AXUIElementCopyAttributeValue(_window1, kAXPositionAttribute, (CFTypeRef *) &_pos1);
        if (error != kAXErrorSuccess) {
            if (verbose) { NSLog(@"Error getting window1 position: %d", error); }
            CFRelease(_size1);
            return false;
        }
        
        if (_pos1) {
            error = AXUIElementCopyAttributeValue(_window2, kAXSizeAttribute, (CFTypeRef *) &_size2);
            if (error != kAXErrorSuccess) {
                if (verbose) { NSLog(@"Error getting window2 size: %d", error); }
                CFRelease(_size1);
                CFRelease(_pos1);
                return false;
            }
            
            if (_size2) {
                error = AXUIElementCopyAttributeValue(_window2, kAXPositionAttribute, (CFTypeRef *) &_pos2);
                if (error != kAXErrorSuccess) {
                    if (verbose) { NSLog(@"Error getting window2 position: %d", error); }
                    CFRelease(_size1);
                    CFRelease(_pos1);
                    CFRelease(_size2);
                    return false;
                }
                
                if (_pos2) {
                    CGSize cg_size1;
                    CGSize cg_size2;
                    CGPoint cg_pos1;
                    CGPoint cg_pos2;
                    if (AXValueGetValue(_size1, (AXValueType)kAXValueCGSizeType, &cg_size1) &&
                        AXValueGetValue(_pos1, (AXValueType)kAXValueCGPointType, &cg_pos1) &&
                        AXValueGetValue(_size2, (AXValueType)kAXValueCGSizeType, &cg_size2) &&
                        AXValueGetValue(_pos2, (AXValueType)kAXValueCGPointType, &cg_pos2)) {
                        contained = cg_pos1.x > cg_pos2.x && cg_pos1.y > cg_pos2.y &&
                            cg_pos1.x + cg_size1.width < cg_pos2.x + cg_size2.width &&
                            cg_pos1.y + cg_size1.height < cg_pos2.y + cg_size2.height;
                    }
                    CFRelease(_pos2);
                }
                CFRelease(_size2);
            }
            CFRelease(_pos1);
        }
        CFRelease(_size1);
    }

    return contained;
}