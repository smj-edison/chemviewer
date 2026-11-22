// See imgui_vulkan.h.
#include "imgui_vulkan.h"

#include "imgui.h"
#include "imgui_impl_vulkan.h"

static PFN_vkGetInstanceProcAddr g_get_instance_proc_addr;

static PFN_vkVoidFunction loadFunction(const char *name, void *instance) {
    return g_get_instance_proc_addr((VkInstance)instance, name);
}

static VkFormat g_color_format;

extern "C" bool cvImGuiVulkanInit(const CvImGuiVulkanInfo *info) {
    g_get_instance_proc_addr = (PFN_vkGetInstanceProcAddr)info->get_instance_proc_addr;
    if (!ImGui_ImplVulkan_LoadFunctions(info->api_version, loadFunction, info->instance)) return false;

    g_color_format = (VkFormat)info->color_format;
    ImGui_ImplVulkan_InitInfo init = {};
    init.ApiVersion = info->api_version;
    init.Instance = (VkInstance)info->instance;
    init.PhysicalDevice = (VkPhysicalDevice)info->physical_device;
    init.Device = (VkDevice)info->device;
    init.QueueFamily = info->queue_family;
    init.Queue = (VkQueue)info->queue;
    init.DescriptorPoolSize = IMGUI_IMPL_VULKAN_MINIMUM_SAMPLED_IMAGE_POOL_SIZE;
    init.MinImageCount = info->image_count < 2 ? 2 : info->image_count;
    init.ImageCount = init.MinImageCount;
    init.UseDynamicRendering = true;
    init.PipelineInfoMain.MSAASamples = VK_SAMPLE_COUNT_1_BIT;
    VkPipelineRenderingCreateInfoKHR &rendering = init.PipelineInfoMain.PipelineRenderingCreateInfo;
    rendering.sType = VK_STRUCTURE_TYPE_PIPELINE_RENDERING_CREATE_INFO_KHR;
    rendering.colorAttachmentCount = 1;
    rendering.pColorAttachmentFormats = &g_color_format;
    return ImGui_ImplVulkan_Init(&init);
}

extern "C" void cvImGuiVulkanShutdown(void) { ImGui_ImplVulkan_Shutdown(); }

extern "C" void cvImGuiVulkanNewFrame(void) { ImGui_ImplVulkan_NewFrame(); }

extern "C" void cvImGuiVulkanRender(void *command_buffer) {
    ImGui_ImplVulkan_RenderDrawData(ImGui::GetDrawData(), (VkCommandBuffer)command_buffer);
}

extern "C" void cvImGuiVulkanSetMinImageCount(uint32_t count) {
    ImGui_ImplVulkan_SetMinImageCount(count < 2 ? 2 : count);
}
