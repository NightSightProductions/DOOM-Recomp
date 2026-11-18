// iOS has no Vulkan loader. The runtime's vulkan.c bootstraps through dlsym("vkGetInstanceProcAddr") on whatever
// RT_VULKAN_LIB names; boot_ios.m points that at this executable, and this function forwards to the KosmicKrisp ICD
// (Frameworks/libvulkan_kosmickrisp.dylib), which only exports vk_icdGetInstanceProcAddr.
#include <dlfcn.h>
#include <limits.h>
#include <stdio.h>
#include <string.h>
#include <mach-o/dyld.h>
void rt_log(const char *fmt, ...);

typedef void (*PFN_void)(void);
typedef PFN_void (*PFN_gipa)(void *instance, const char *name);
static PFN_gipa icd_gipa;

__attribute__((visibility("default"), used))
PFN_void vkGetInstanceProcAddr(void *instance, const char *name) {
    if (!icd_gipa) {
        char exe[PATH_MAX], path[PATH_MAX]; uint32_t n = sizeof exe;
        if (_NSGetExecutablePath(exe, &n)) return NULL;
        char *slash = strrchr(exe, '/'); if (slash) *slash = 0;
        snprintf(path, sizeof path, "%s/Frameworks/libvulkan_kosmickrisp.dylib", exe);
        void *h = dlopen(path, RTLD_NOW | RTLD_LOCAL);
        if (!h) { rt_log("[vulkan] cannot load %s: %s\n", path, dlerror()); return NULL; }
        icd_gipa = (PFN_gipa)dlsym(h, "vk_icdGetInstanceProcAddr");
        if (!icd_gipa) { rt_log("[vulkan] %s has no vk_icdGetInstanceProcAddr\n", path); return NULL; }
        rt_log("[vulkan] KosmicKrisp ICD %s\n", path);
    }
    return icd_gipa(instance, name);
}
