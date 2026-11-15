// Runs DOOM's GPU particle simulate compute shader (a SPIR-V file dumped with RT_VK_DUMP) on the bundled
// KosmicKrisp with a synthetic emitter, and prints the indirect draw arguments it writes. A working driver
// commits every visible particle: indexCount = 6 * particles. No window is opened.
//
//   cc -O1 -Iframework/third_party/vulkan/include tests/particle_sim.c framework/runtime/spvfix.c build/kosmickrisp/libvulkan.1.dylib -o build/particle_sim
//   VK_ICD_FILENAMES=build/kosmickrisp/kosmickrisp_icd.json [SPVFIX=1] build/particle_sim sim.spv [particles] [repeats]
#include <vulkan/vulkan.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

uint32_t *spv_fix_atomic_resets(const uint32_t *code, size_t words, size_t *out_words, int *nfixed);

#define CK(x) do { VkResult r_ = (x); if (r_) { fprintf(stderr, "%s -> %d\n", #x, r_); exit(1); } } while (0)

static VkDevice dev; static VkPhysicalDevice pd;
static uint32_t memtype(uint32_t bits, VkMemoryPropertyFlags want) {
    VkPhysicalDeviceMemoryProperties mp; vkGetPhysicalDeviceMemoryProperties(pd, &mp);
    for (uint32_t i = 0; i < mp.memoryTypeCount; i++) if ((bits >> i & 1) && (mp.memoryTypes[i].propertyFlags & want) == want) return i;
    fprintf(stderr, "no memory type\n"); exit(1);
}
typedef struct { VkBuffer b; VkDeviceMemory m; void *p; VkDeviceSize n; } Buf;
static Buf buffer(VkDeviceSize n, VkBufferUsageFlags u) {
    Buf r = { .n = n };
    VkBufferCreateInfo ci = { VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO, .size = n, .usage = u };
    CK(vkCreateBuffer(dev, &ci, NULL, &r.b));
    VkMemoryRequirements mr; vkGetBufferMemoryRequirements(dev, r.b, &mr);
    VkMemoryAllocateInfo ai = { VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .allocationSize = mr.size,
        .memoryTypeIndex = memtype(mr.memoryTypeBits, VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT) };
    CK(vkAllocateMemory(dev, &ai, NULL, &r.m)); CK(vkBindBufferMemory(dev, r.b, r.m, 0));
    CK(vkMapMemory(dev, r.m, 0, VK_WHOLE_SIZE, 0, &r.p)); memset(r.p, 0, n);
    return r;
}
static VkImageView image(VkImageType t, VkImageViewType vt) {
    VkImageCreateInfo ci = { VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO, .imageType = t, .format = VK_FORMAT_R8G8B8A8_UNORM,
        .extent = { 1, 1, 1 }, .mipLevels = 1, .arrayLayers = 1, .samples = 1, .usage = VK_IMAGE_USAGE_SAMPLED_BIT };
    VkImage im; CK(vkCreateImage(dev, &ci, NULL, &im));
    VkMemoryRequirements mr; vkGetImageMemoryRequirements(dev, im, &mr);
    VkMemoryAllocateInfo ai = { VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .allocationSize = mr.size, .memoryTypeIndex = memtype(mr.memoryTypeBits, 0) };
    VkDeviceMemory m; CK(vkAllocateMemory(dev, &ai, NULL, &m)); CK(vkBindImageMemory(dev, im, m, 0));
    VkImageViewCreateInfo vi = { VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO, .image = im, .viewType = vt, .format = ci.format,
        .subresourceRange = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 } };
    VkImageView v; CK(vkCreateImageView(dev, &vi, NULL, &v));
    return v;
}

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: particle_sim sim.spv [particles] [repeats]\n"); return 2; }
    int count = argc > 2 ? atoi(argv[2]) : 64, reps = argc > 3 ? atoi(argv[3]) : 4;
    FILE *f = fopen(argv[1], "rb"); if (!f) { perror(argv[1]); return 1; }
    fseek(f, 0, SEEK_END); long n = ftell(f); fseek(f, 0, SEEK_SET);
    uint32_t *code = malloc((size_t)n); if (fread(code, 1, (size_t)n, f) != (size_t)n) return 1; fclose(f);
    if (getenv("SPVFIX")) {   // the runtime's SPIR-V fix (framework/runtime/spvfix.c)
        size_t ow; int nf; uint32_t *o = spv_fix_atomic_resets(code, (size_t)n / 4, &ow, &nf);
        printf("spvfix: %d stores made atomic\n", nf);
        if (o) { code = o; n = (long)(ow * 4); }
        if (getenv("SPVFIX_OUT")) { FILE *g = fopen(getenv("SPVFIX_OUT"), "wb"); fwrite(code, 1, (size_t)n, g); fclose(g); }
    }

    const char *iext[] = { VK_KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME };
    VkApplicationInfo app = { VK_STRUCTURE_TYPE_APPLICATION_INFO, .apiVersion = VK_API_VERSION_1_0 };
    VkInstanceCreateInfo ici = { VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, .flags = VK_INSTANCE_CREATE_ENUMERATE_PORTABILITY_BIT_KHR,
        .pApplicationInfo = &app, .enabledExtensionCount = 1, .ppEnabledExtensionNames = iext };
    VkInstance inst; CK(vkCreateInstance(&ici, NULL, &inst));
    uint32_t npd = 1; CK(vkEnumeratePhysicalDevices(inst, &npd, &pd) < 0);
    float prio = 1; VkDeviceQueueCreateInfo qci = { VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO, .queueCount = 1, .pQueuePriorities = &prio };
    VkDeviceCreateInfo dci = { VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, .queueCreateInfoCount = 1, .pQueueCreateInfos = &qci };
    CK(vkCreateDevice(pd, &dci, NULL, &dev));
    VkQueue q; vkGetDeviceQueue(dev, 0, 0, &q);

    // bindings: 0 freqHigh UBO, 1 freqLow UBO, 2-3 sampler3D, 4-5 sampler2D, 6 random, 7 indirect args, 8 particles, 9 vector fields
    VkDescriptorSetLayoutBinding lb[10];
    for (int i = 0; i < 10; i++)
        lb[i] = (VkDescriptorSetLayoutBinding){ i, i < 2 ? VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER : i < 6 ? VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER : VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1, VK_SHADER_STAGE_COMPUTE_BIT, NULL };
    VkDescriptorSetLayoutCreateInfo lci = { VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO, .bindingCount = 10, .pBindings = lb };
    VkDescriptorSetLayout dsl; CK(vkCreateDescriptorSetLayout(dev, &lci, NULL, &dsl));
    VkPipelineLayoutCreateInfo plci = { VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO, .setLayoutCount = 1, .pSetLayouts = &dsl };
    VkPipelineLayout pl; CK(vkCreatePipelineLayout(dev, &plci, NULL, &pl));
    VkShaderModuleCreateInfo smci = { VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO, .codeSize = (size_t)n, .pCode = code };
    VkShaderModule sm; CK(vkCreateShaderModule(dev, &smci, NULL, &sm));
    VkComputePipelineCreateInfo cpci = { VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO,
        .stage = { VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = VK_SHADER_STAGE_COMPUTE_BIT, .module = sm, .pName = "main" }, .layout = pl };
    VkPipeline pipe; CK(vkCreateComputePipelines(dev, VK_NULL_HANDLE, 1, &cpci, NULL, &pipe));

    Buf hi = buffer(18 * 16, VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT), lo = buffer(6 * 16, VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT);
    Buf rnd = buffer(8192 * 16, VK_BUFFER_USAGE_STORAGE_BUFFER_BIT), args = buffer(256, VK_BUFFER_USAGE_STORAGE_BUFFER_BIT);
    Buf parts = buffer((VkDeviceSize)(count + 64) * 48, VK_BUFFER_USAGE_STORAGE_BUFFER_BIT), vf = buffer(256, VK_BUFFER_USAGE_STORAGE_BUFFER_BIT);
    float *r = rnd.p; srand(1); for (int i = 0; i < 8192 * 4; i++) r[i] = (float)rand() / (float)RAND_MAX;
    // freqHigh vec4s: 0 emitseed 1 dist0 2 vel0 3 dist1 4 vel1 5-7 emit axes 8 origin 9 accel 10 particlevel 11 emitlifetime
    // 12 vectorfieldindices 13 timeparms 14 physicsparms 15 physicsparms2 16 emitparms 17 emitparms2
    float (*h)[4] = hi.p;
    h[5][0] = 1; h[6][1] = 1; h[7][2] = 1;               // emit axes = identity
    h[8][2] = 0.0f;                                      // origin
    h[11][0] = 0.5f; h[11][1] = 2.0f;                    // lifetime min/max
    h[12][0] = -1; h[12][1] = -1;                        // no vector fields
    h[13][0] = 1.0f / 60;                                // time step
    h[14][3] = 1.0f;                                     // mass
    h[1][3] = 1; h[1][0] = h[1][1] = h[1][2] = 1;        // box distribution, 1 unit
    h[2][3] = 1; h[2][0] = h[2][1] = h[2][2] = 1;        // box velocities
    h[16][0] = 0.25f; h[16][1] = 2.0f; h[16][2] = 0.001f; h[16][3] = (float)count;   // age, cycle length, spawn interval, count
    float (*l)[4] = lo.p;
    l[0][2] = 1;                                         // projectionmatrixz
    l[1][0] = 0.01f; l[2][1] = 0.01f; l[3][2] = 0.01f; l[4][3] = 1;   // view-projection: small scale, everything visible
    l[5][0] = 1; l[5][1] = 1;

    VkSamplerCreateInfo sci = { VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO };
    VkSampler samp; CK(vkCreateSampler(dev, &sci, NULL, &samp));
    VkImageView v3 = image(VK_IMAGE_TYPE_3D, VK_IMAGE_VIEW_TYPE_3D), v2 = image(VK_IMAGE_TYPE_2D, VK_IMAGE_VIEW_TYPE_2D);
    VkDescriptorPoolSize ps[3] = { { VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, 2 }, { VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, 4 }, { VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 4 } };
    VkDescriptorPoolCreateInfo dpci = { VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO, .maxSets = 1, .poolSizeCount = 3, .pPoolSizes = ps };
    VkDescriptorPool dp; CK(vkCreateDescriptorPool(dev, &dpci, NULL, &dp));
    VkDescriptorSetAllocateInfo dsai = { VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO, .descriptorPool = dp, .descriptorSetCount = 1, .pSetLayouts = &dsl };
    VkDescriptorSet ds; CK(vkAllocateDescriptorSets(dev, &dsai, &ds));
    VkDescriptorBufferInfo bi[10] = { [0] = { hi.b, 0, VK_WHOLE_SIZE }, [1] = { lo.b, 0, VK_WHOLE_SIZE }, [6] = { rnd.b, 0, VK_WHOLE_SIZE },
        [7] = { args.b, 0, VK_WHOLE_SIZE }, [8] = { parts.b, 0, VK_WHOLE_SIZE }, [9] = { vf.b, 0, VK_WHOLE_SIZE } };
    VkDescriptorImageInfo ii[10] = { [2] = { samp, v3, VK_IMAGE_LAYOUT_GENERAL }, [3] = { samp, v3, VK_IMAGE_LAYOUT_GENERAL },
        [4] = { samp, v2, VK_IMAGE_LAYOUT_GENERAL }, [5] = { samp, v2, VK_IMAGE_LAYOUT_GENERAL } };
    VkWriteDescriptorSet w[10];
    for (int i = 0; i < 10; i++)
        w[i] = (VkWriteDescriptorSet){ VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .dstSet = ds, .dstBinding = i, .descriptorCount = 1,
            .descriptorType = lb[i].descriptorType, .pImageInfo = &ii[i], .pBufferInfo = &bi[i] };
    vkUpdateDescriptorSets(dev, 10, w, 0, NULL);

    VkCommandPoolCreateInfo cpi = { VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO };
    VkCommandPool pool; CK(vkCreateCommandPool(dev, &cpi, NULL, &pool));
    VkCommandBufferAllocateInfo cai = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO, .commandPool = pool, .commandBufferCount = 1 };
    VkCommandBuffer cb; CK(vkAllocateCommandBuffers(dev, &cai, &cb));
    int groups = (count + 63) / 64;
    for (int it = 0; it < reps; it++) {
        h[16][0] = 0.25f + 0.1f * (float)it;   // the emitter ages a little each frame
        h[17][2] = it == 0;                      // emitparms2.z: reset the particles on the first frame
        VkCommandBufferBeginInfo cbi = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO, .flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT };
        CK(vkBeginCommandBuffer(cb, &cbi));
        vkCmdBindPipeline(cb, VK_PIPELINE_BIND_POINT_COMPUTE, pipe);
        vkCmdBindDescriptorSets(cb, VK_PIPELINE_BIND_POINT_COMPUTE, pl, 0, 1, &ds, 0, NULL);
        vkCmdDispatch(cb, (uint32_t)groups, 1, 1);
        VkMemoryBarrier mb = { VK_STRUCTURE_TYPE_MEMORY_BARRIER, .srcAccessMask = VK_ACCESS_SHADER_WRITE_BIT, .dstAccessMask = VK_ACCESS_HOST_READ_BIT };
        vkCmdPipelineBarrier(cb, VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, VK_PIPELINE_STAGE_HOST_BIT, 0, 1, &mb, 0, NULL, 0, NULL);
        CK(vkEndCommandBuffer(cb));
        VkSubmitInfo si = { VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1, .pCommandBuffers = &cb };
        CK(vkQueueSubmit(q, 1, &si, VK_NULL_HANDLE)); CK(vkQueueWaitIdle(q));
        int32_t *a = args.p; int32_t *p = parts.p;
        int emitted = 0; for (int i = 0; i < count; i++) if (p[i * 12 + 2] >= 0 && ((float *)p)[i * 12 + 7] > 0) emitted++;
        printf("frame %d: indexCount %d instanceCount %d | args2-4 %d %d %d | particles with a cycle %d\n", it, a[0], a[1], a[2], a[3], a[4], emitted);
        float *fp = parts.p;
        if (getenv("SHOW")) for (int i = 0; i < 3; i++) printf("  p%d: commit %d cycle %d flags %d pos %g %g %g maxlife %g vel %g %g %g life %g\n", i, p[i*12], p[i*12+2], p[i*12+3],
            fp[i*12+4], fp[i*12+5], fp[i*12+6], fp[i*12+7], fp[i*12+8], fp[i*12+9], fp[i*12+10], fp[i*12+11]);
        CK(vkResetCommandBuffer(cb, 0));
    }
    return 0;
}
