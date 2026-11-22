// ImGui's Vulkan backend behind a plain C interface, so Zig never needs the
// C Vulkan headers: handles cross as opaque pointers, enums as integers.
#pragma once
#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct CvImGuiVulkanInfo {
    uint32_t api_version;
    // PFN_vkGetInstanceProcAddr; every backend function is loaded through it.
    void *get_instance_proc_addr;
    void *instance;
    void *physical_device;
    void *device;
    void *queue;
    uint32_t queue_family;
    uint32_t image_count;
    // VkFormat of the colour attachment ImGui draws into (dynamic rendering).
    int32_t color_format;
} CvImGuiVulkanInfo;

bool cvImGuiVulkanInit(const CvImGuiVulkanInfo *info);
void cvImGuiVulkanShutdown(void);
void cvImGuiVulkanNewFrame(void);
// Records the current draw data into a command buffer inside a rendering pass.
void cvImGuiVulkanRender(void *command_buffer);
void cvImGuiVulkanSetMinImageCount(uint32_t count);

#ifdef __cplusplus
}
#endif
