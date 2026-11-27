// Force-included (-include) into the framework runtime sources compiled for iOS, so they build unmodified.
#pragma once
#include <CoreGraphics/CoreGraphics.h>
#include <TargetConditionals.h>

// dinput.c grabs the mouse with this macOS-only call; on iOS pointer capture is handled by cocoa_cursor_visible
// (UIPointerLock), so the call is a no-op.
static inline CGError CGAssociateMouseAndMouseCursorPosition(boolean_t connected) { (void)connected; return kCGErrorSuccess; }

// wasapi.c / xaudio2.c open "the default output" audio unit; on iOS that unit is RemoteIO. The identifier is passed
// on the compiler command line (-DkAudioUnitSubType_DefaultOutput=kAudioUnitSubType_RemoteIO): iOS has no
// DefaultOutput subtype, so the macro only ever replaces a name the SDK does not define.

// bcrypt.c defines its own static crypt(); iOS's <unistd.h> declares one (macOS hides it). Rename later uses.
#include <unistd.h>
#define crypt rt_bcrypt_crypt
