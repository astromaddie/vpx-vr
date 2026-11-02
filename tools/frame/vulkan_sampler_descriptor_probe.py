#!/usr/bin/env python3
"""Isolate Turnip sampler descriptor writes without shaders, XR, or rendering.

Run ``python3 tools/frame/vulkan_sampler_descriptor_probe.py --suite`` on the
Frame inside the same Steam Linux Runtime used by VPX. The suite compares the
sparse sampler binding, a layout with only that binding changed to 1, and a
sampler-only layout. Each Vulkan case runs in its own timed child process, so a
driver SIGSEGV is reported and the remaining binding-layout cases still run.
"""

from __future__ import annotations

import argparse
import ctypes as C
import ctypes.util
import os
import resource
import signal
import subprocess
import sys
from dataclasses import dataclass


VK_SUCCESS = 0
VK_API_VERSION_1_2 = (1 << 22) | (2 << 12)
VK_VENDOR_ID_QUALCOMM = 0x5143
VK_DEVICE_ID_ADRENO_750 = 0x43051401
VK_DRIVER_ID_MESA_TURNIP = 18

VK_STRUCTURE_TYPE_APPLICATION_INFO = 0
VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO = 1
VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO = 2
VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO = 3
VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO = 31
VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO = 32
VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO = 33
VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO = 34
VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET = 35
VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2 = 1000059001
VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DRIVER_PROPERTIES = 1000196000

VK_QUEUE_GRAPHICS_BIT = 0x1
VK_DESCRIPTOR_POOL_CREATE_FREE_DESCRIPTOR_SET_BIT = 0x1
BGFX_DESCRIPTOR_POOL_MAX_SETS = 1024
CASE_TIMEOUT_SECONDS = 30
VK_DESCRIPTOR_TYPE_SAMPLER = 0
VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE = 2
VK_DESCRIPTOR_TYPE_STORAGE_IMAGE = 3
VK_DESCRIPTOR_TYPE_STORAGE_BUFFER = 7
VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER_DYNAMIC = 8
VK_SHADER_STAGE_VERTEX_BIT = 0x1
VK_SHADER_STAGE_FRAGMENT_BIT = 0x10

VK_FILTER_LINEAR = 1
VK_SAMPLER_MIPMAP_MODE_LINEAR = 1
VK_SAMPLER_ADDRESS_MODE_REPEAT = 0
VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE = 2
VK_BORDER_COLOR_FLOAT_OPAQUE_BLACK = 2
VK_IMAGE_LAYOUT_UNDEFINED = 0


class VkApplicationInfo(C.Structure):
    _fields_ = [
        ("sType", C.c_uint32),
        ("pNext", C.c_void_p),
        ("pApplicationName", C.c_char_p),
        ("applicationVersion", C.c_uint32),
        ("pEngineName", C.c_char_p),
        ("engineVersion", C.c_uint32),
        ("apiVersion", C.c_uint32),
    ]


class VkInstanceCreateInfo(C.Structure):
    _fields_ = [
        ("sType", C.c_uint32),
        ("pNext", C.c_void_p),
        ("flags", C.c_uint32),
        ("pApplicationInfo", C.POINTER(VkApplicationInfo)),
        ("enabledLayerCount", C.c_uint32),
        ("ppEnabledLayerNames", C.POINTER(C.c_char_p)),
        ("enabledExtensionCount", C.c_uint32),
        ("ppEnabledExtensionNames", C.POINTER(C.c_char_p)),
    ]


class VkDeviceQueueCreateInfo(C.Structure):
    _fields_ = [
        ("sType", C.c_uint32),
        ("pNext", C.c_void_p),
        ("flags", C.c_uint32),
        ("queueFamilyIndex", C.c_uint32),
        ("queueCount", C.c_uint32),
        ("pQueuePriorities", C.POINTER(C.c_float)),
    ]


class VkDeviceCreateInfo(C.Structure):
    _fields_ = [
        ("sType", C.c_uint32),
        ("pNext", C.c_void_p),
        ("flags", C.c_uint32),
        ("queueCreateInfoCount", C.c_uint32),
        ("pQueueCreateInfos", C.POINTER(VkDeviceQueueCreateInfo)),
        ("enabledLayerCount", C.c_uint32),
        ("ppEnabledLayerNames", C.POINTER(C.c_char_p)),
        ("enabledExtensionCount", C.c_uint32),
        ("ppEnabledExtensionNames", C.POINTER(C.c_char_p)),
        ("pEnabledFeatures", C.c_void_p),
    ]


class VkExtent3D(C.Structure):
    _fields_ = [("width", C.c_uint32), ("height", C.c_uint32), ("depth", C.c_uint32)]


class VkQueueFamilyProperties(C.Structure):
    _fields_ = [
        ("queueFlags", C.c_uint32),
        ("queueCount", C.c_uint32),
        ("timestampValidBits", C.c_uint32),
        ("minImageTransferGranularity", VkExtent3D),
    ]


class VkPhysicalDeviceDriverProperties(C.Structure):
    _fields_ = [
        ("sType", C.c_uint32),
        ("pNext", C.c_void_p),
        ("driverID", C.c_uint32),
        ("driverName", C.c_char * 256),
        ("driverInfo", C.c_char * 256),
        ("conformanceVersion", C.c_uint8 * 4),
    ]


class VkPhysicalDeviceProperties2(C.Structure):
    # The core VkPhysicalDeviceProperties payload is larger than needed here;
    # keep a correctly aligned oversized block while reading its fixed prefix.
    _fields_ = [
        ("sType", C.c_uint32),
        ("pNext", C.c_void_p),
        ("properties", C.c_uint8 * 4096),
    ]


class VkDescriptorPoolSize(C.Structure):
    _fields_ = [("type", C.c_uint32), ("descriptorCount", C.c_uint32)]


class VkDescriptorPoolCreateInfo(C.Structure):
    _fields_ = [
        ("sType", C.c_uint32),
        ("pNext", C.c_void_p),
        ("flags", C.c_uint32),
        ("maxSets", C.c_uint32),
        ("poolSizeCount", C.c_uint32),
        ("pPoolSizes", C.POINTER(VkDescriptorPoolSize)),
    ]


class VkDescriptorSetLayoutBinding(C.Structure):
    _fields_ = [
        ("binding", C.c_uint32),
        ("descriptorType", C.c_uint32),
        ("descriptorCount", C.c_uint32),
        ("stageFlags", C.c_uint32),
        ("pImmutableSamplers", C.POINTER(C.c_void_p)),
    ]


class VkDescriptorSetLayoutCreateInfo(C.Structure):
    _fields_ = [
        ("sType", C.c_uint32),
        ("pNext", C.c_void_p),
        ("flags", C.c_uint32),
        ("bindingCount", C.c_uint32),
        ("pBindings", C.POINTER(VkDescriptorSetLayoutBinding)),
    ]


class VkDescriptorSetAllocateInfo(C.Structure):
    _fields_ = [
        ("sType", C.c_uint32),
        ("pNext", C.c_void_p),
        ("descriptorPool", C.c_void_p),
        ("descriptorSetCount", C.c_uint32),
        ("pSetLayouts", C.POINTER(C.c_void_p)),
    ]


class VkSamplerCreateInfo(C.Structure):
    _fields_ = [
        ("sType", C.c_uint32),
        ("pNext", C.c_void_p),
        ("flags", C.c_uint32),
        ("magFilter", C.c_uint32),
        ("minFilter", C.c_uint32),
        ("mipmapMode", C.c_uint32),
        ("addressModeU", C.c_uint32),
        ("addressModeV", C.c_uint32),
        ("addressModeW", C.c_uint32),
        ("mipLodBias", C.c_float),
        ("anisotropyEnable", C.c_uint32),
        ("maxAnisotropy", C.c_float),
        ("compareEnable", C.c_uint32),
        ("compareOp", C.c_uint32),
        ("minLod", C.c_float),
        ("maxLod", C.c_float),
        ("borderColor", C.c_uint32),
        ("unnormalizedCoordinates", C.c_uint32),
    ]


class VkDescriptorImageInfo(C.Structure):
    _fields_ = [
        ("sampler", C.c_void_p),
        ("imageView", C.c_void_p),
        ("imageLayout", C.c_uint32),
    ]


class VkWriteDescriptorSet(C.Structure):
    _fields_ = [
        ("sType", C.c_uint32),
        ("pNext", C.c_void_p),
        ("dstSet", C.c_void_p),
        ("dstBinding", C.c_uint32),
        ("dstArrayElement", C.c_uint32),
        ("descriptorCount", C.c_uint32),
        ("descriptorType", C.c_uint32),
        ("pImageInfo", C.POINTER(VkDescriptorImageInfo)),
        ("pBufferInfo", C.c_void_p),
        ("pTexelBufferView", C.c_void_p),
    ]


@dataclass(frozen=True)
class DescriptorCase:
    name: str
    bindings: tuple[tuple[int, int, int], ...]
    sampler_binding: int


# These are the exact descriptor-set layout bindings from the first crashing
# BGFX write, with only the sampler binding changed in the dense case.
CASES = (
    DescriptorCase(
        "sparse_sampler_19",
        (
            (0, VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER_DYNAMIC, VK_SHADER_STAGE_VERTEX_BIT),
            (3, VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE, VK_SHADER_STAGE_FRAGMENT_BIT),
            (19, VK_DESCRIPTOR_TYPE_SAMPLER, VK_SHADER_STAGE_FRAGMENT_BIT),
        ),
        19,
    ),
    DescriptorCase(
        "dense_sampler_1",
        (
            (0, VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER_DYNAMIC, VK_SHADER_STAGE_VERTEX_BIT),
            (3, VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE, VK_SHADER_STAGE_FRAGMENT_BIT),
            (1, VK_DESCRIPTOR_TYPE_SAMPLER, VK_SHADER_STAGE_FRAGMENT_BIT),
        ),
        1,
    ),
    DescriptorCase(
        "single_sampler_19",
        ((19, VK_DESCRIPTOR_TYPE_SAMPLER, VK_SHADER_STAGE_FRAGMENT_BIT),),
        19,
    ),
)
CASES_BY_NAME = {case.name: case for case in CASES}


def make_layout_bindings(case: DescriptorCase):
    """Build bindings while retaining the supplied order and exact metadata."""
    bindings = (VkDescriptorSetLayoutBinding * len(case.bindings))()
    for index, (binding, descriptor_type, stage_flags) in enumerate(case.bindings):
        bindings[index] = VkDescriptorSetLayoutBinding(
            binding,
            descriptor_type,
            1,
            stage_flags,
            None,
        )
    return bindings


def make_bgfx_pool_sizes():
    """Return the 1,024-set BGFX pool captured from the crashing run."""
    values = (
        (VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE, 16384),
        (VK_DESCRIPTOR_TYPE_SAMPLER, 16384),
        (VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER_DYNAMIC, 2048),
        (VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 16384),
        (VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, 16384),
    )
    sizes = (VkDescriptorPoolSize * len(values))()
    for index, (descriptor_type, count) in enumerate(values):
        sizes[index] = VkDescriptorPoolSize(descriptor_type, count)
    return sizes


def make_bgfx_pool_info(pool_sizes):
    return VkDescriptorPoolCreateInfo(
        VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
        None,
        VK_DESCRIPTOR_POOL_CREATE_FREE_DESCRIPTOR_SET_BIT,
        BGFX_DESCRIPTOR_POOL_MAX_SETS,
        len(pool_sizes),
        pool_sizes,
    )


def make_sampler_create_info():
    """Mirror the sampler parameters recorded in the failing API trace."""
    info = VkSamplerCreateInfo()
    info.sType = VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO
    info.pNext = None
    info.flags = 0
    info.magFilter = VK_FILTER_LINEAR
    info.minFilter = VK_FILTER_LINEAR
    info.mipmapMode = VK_SAMPLER_MIPMAP_MODE_LINEAR
    info.addressModeU = VK_SAMPLER_ADDRESS_MODE_REPEAT
    info.addressModeV = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE
    info.addressModeW = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE
    info.mipLodBias = 0.0
    info.anisotropyEnable = 0
    info.maxAnisotropy = 16.0
    info.compareEnable = 0
    info.compareOp = 0
    info.minLod = 0.0
    info.maxLod = 1000.0
    info.borderColor = VK_BORDER_COLOR_FLOAT_OPAQUE_BLACK
    info.unnormalizedCoordinates = 0
    return info


def make_sampler_write(descriptor_set, sampler, binding):
    """Build a valid sampler-only write; unused image members remain null."""
    image_info = VkDescriptorImageInfo(sampler, None, VK_IMAGE_LAYOUT_UNDEFINED)
    write = VkWriteDescriptorSet()
    write.sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET
    write.pNext = None
    write.dstSet = descriptor_set
    write.dstBinding = binding
    write.dstArrayElement = 0
    write.descriptorCount = 1
    write.descriptorType = VK_DESCRIPTOR_TYPE_SAMPLER
    write.pImageInfo = C.pointer(image_info)
    write.pBufferInfo = None
    write.pTexelBufferView = None
    return image_info, write


def _function(address, result_type, argument_types):
    if not address:
        raise RuntimeError("Vulkan loader returned a null function pointer")
    return C.CFUNCTYPE(result_type, *argument_types)(address)


def _load_instance_function(get_instance_proc_addr, instance, name, result_type, argument_types):
    return _function(
        get_instance_proc_addr(instance, name.encode("ascii")),
        result_type,
        argument_types,
    )


def _load_device_function(get_device_proc_addr, device, name, result_type, argument_types):
    return _function(get_device_proc_addr(device, name.encode("ascii")), result_type, argument_types)


def _check(result, operation):
    if result != VK_SUCCESS:
        raise RuntimeError(f"{operation} failed with VkResult {result}")


def _device_info(physical_device, get_properties2):
    # VkPhysicalDeviceProperties is intentionally held as an oversized byte
    # buffer: only its fixed leading identity fields are needed by this probe.
    driver_properties = VkPhysicalDeviceDriverProperties()
    driver_properties.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DRIVER_PROPERTIES
    properties = VkPhysicalDeviceProperties2()
    properties.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2
    properties.pNext = C.cast(C.pointer(driver_properties), C.c_void_p)
    get_properties2(physical_device, C.byref(properties))
    api_version, driver_version, vendor_id, device_id, device_type = C.cast(
        C.pointer(properties.properties), C.POINTER(C.c_uint32 * 5)
    ).contents
    name = bytes(properties.properties[20:276]).split(b"\0", 1)[0].decode("utf-8", "replace")
    driver_name = bytes(driver_properties.driverName).split(b"\0", 1)[0].decode("utf-8", "replace")
    driver_info = bytes(driver_properties.driverInfo).split(b"\0", 1)[0].decode("utf-8", "replace")
    return (
        api_version,
        driver_version,
        vendor_id,
        device_id,
        device_type,
        name,
        driver_properties.driverID,
        driver_name,
        driver_info,
    )


def _select_graphics_queue(physical_device, get_queue_properties):
    count = C.c_uint32()
    print("CALL vkGetPhysicalDeviceQueueFamilyProperties(count)", flush=True)
    get_queue_properties(physical_device, C.byref(count), None)
    if not count.value:
        return None
    properties = (VkQueueFamilyProperties * count.value)()
    print("CALL vkGetPhysicalDeviceQueueFamilyProperties(list)", flush=True)
    get_queue_properties(physical_device, C.byref(count), properties)
    for index, item in enumerate(properties):
        if item.queueCount and item.queueFlags & VK_QUEUE_GRAPHICS_BIT:
            return index
    return None


def is_expected_turnip_device(vendor_id, device_id, driver_id, driver_name, api_version):
    major, minor = (api_version >> 22) & 0x7F, (api_version >> 12) & 0x3FF
    return (
        vendor_id == VK_VENDOR_ID_QUALCOMM
        and device_id == VK_DEVICE_ID_ADRENO_750
        and driver_id == VK_DRIVER_ID_MESA_TURNIP
        and "turnip" in driver_name.lower()
        and (major, minor) >= (1, 2)
    )


def run_case(case: DescriptorCase):
    # A driver crash must not leave a large core file on the device.
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))

    library_name = ctypes.util.find_library("vulkan")
    if not library_name:
        raise RuntimeError("system Vulkan loader not found (libvulkan.so.1)")
    library = C.CDLL(library_name)
    get_instance_proc_addr = library.vkGetInstanceProcAddr
    get_instance_proc_addr.argtypes = [C.c_void_p, C.c_char_p]
    get_instance_proc_addr.restype = C.c_void_p

    create_instance = _load_instance_function(
        get_instance_proc_addr,
        None,
        "vkCreateInstance",
        C.c_int32,
        [C.POINTER(VkInstanceCreateInfo), C.c_void_p, C.POINTER(C.c_void_p)],
    )
    app_name = b"VPX Frame sampler descriptor probe"
    app_info = VkApplicationInfo(
        VK_STRUCTURE_TYPE_APPLICATION_INFO,
        None,
        app_name,
        1,
        app_name,
        1,
        VK_API_VERSION_1_2,
    )
    instance_info = VkInstanceCreateInfo(
        VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
        None,
        0,
        C.pointer(app_info),
        0,
        None,
        0,
        None,
    )
    instance = C.c_void_p()
    print("CALL vkCreateInstance", flush=True)
    _check(create_instance(C.byref(instance_info), None, C.byref(instance)), "vkCreateInstance")

    device = C.c_void_p()
    descriptor_pool = C.c_void_p()
    descriptor_set_layout = C.c_void_p()
    sampler = C.c_void_p()
    destroy_instance = None
    destroy_device = None
    destroy_pool = None
    destroy_layout = None
    destroy_sampler = None

    try:
        enumerate_physical_devices = _load_instance_function(
            get_instance_proc_addr,
            instance,
            "vkEnumeratePhysicalDevices",
            C.c_int32,
            [C.c_void_p, C.POINTER(C.c_uint32), C.POINTER(C.c_void_p)],
        )
        get_properties2 = _load_instance_function(
            get_instance_proc_addr,
            instance,
            "vkGetPhysicalDeviceProperties2",
            None,
            [C.c_void_p, C.POINTER(VkPhysicalDeviceProperties2)],
        )
        get_queue_properties = _load_instance_function(
            get_instance_proc_addr,
            instance,
            "vkGetPhysicalDeviceQueueFamilyProperties",
            None,
            [C.c_void_p, C.POINTER(C.c_uint32), C.POINTER(VkQueueFamilyProperties)],
        )
        get_device_proc_addr = _load_instance_function(
            get_instance_proc_addr,
            instance,
            "vkGetDeviceProcAddr",
            C.c_void_p,
            [C.c_void_p, C.c_char_p],
        )
        destroy_instance = _load_instance_function(
            get_instance_proc_addr,
            instance,
            "vkDestroyInstance",
            None,
            [C.c_void_p, C.c_void_p],
        )

        physical_count = C.c_uint32()
        print("CALL vkEnumeratePhysicalDevices(count)", flush=True)
        _check(enumerate_physical_devices(instance, C.byref(physical_count), None), "vkEnumeratePhysicalDevices(count)")
        if not physical_count.value:
            raise RuntimeError("Vulkan instance reported no physical devices")
        physical_devices = (C.c_void_p * physical_count.value)()
        print("CALL vkEnumeratePhysicalDevices(list)", flush=True)
        _check(
            enumerate_physical_devices(instance, C.byref(physical_count), physical_devices),
            "vkEnumeratePhysicalDevices(list)",
        )

        selected = None
        selected_queue_family = None
        for physical_device in physical_devices:
            print("CALL vkGetPhysicalDeviceProperties2", flush=True)
            (
                api_version,
                driver_version,
                vendor_id,
                device_id,
                device_type,
                name,
                driver_id,
                driver_name,
                driver_info,
            ) = _device_info(physical_device, get_properties2)
            major, minor = (api_version >> 22) & 0x7F, (api_version >> 12) & 0x3FF
            print(
                f"DEVICE name={name!r} vendor=0x{vendor_id:04x} device=0x{device_id:08x} "
                f"api={major}.{minor} driverVersion=0x{driver_version:08x} "
                f"driverID={driver_id} driverName={driver_name!r} driverInfo={driver_info!r}",
                flush=True,
            )
            if not is_expected_turnip_device(vendor_id, device_id, driver_id, driver_name, api_version):
                continue
            queue_family = _select_graphics_queue(physical_device, get_queue_properties)
            if queue_family is not None:
                selected = physical_device
                selected_queue_family = queue_family
                break
        if selected is None:
            raise RuntimeError(
                "no expected Steam Frame device (Qualcomm 0x5143, Adreno 750 0x43051401, "
                "Mesa Turnip driverID 18, Vulkan 1.2+) with a graphics queue"
            )

        queue_priority = C.c_float(1.0)
        queue_info = VkDeviceQueueCreateInfo(
            VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
            None,
            0,
            selected_queue_family,
            1,
            C.pointer(queue_priority),
        )
        device_info = VkDeviceCreateInfo(
            VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
            None,
            0,
            1,
            C.pointer(queue_info),
            0,
            None,
            0,
            None,
            None,
        )
        create_device = _load_instance_function(
            get_instance_proc_addr,
            instance,
            "vkCreateDevice",
            C.c_int32,
            [C.c_void_p, C.POINTER(VkDeviceCreateInfo), C.c_void_p, C.POINTER(C.c_void_p)],
        )
        print("CALL vkCreateDevice", flush=True)
        _check(create_device(selected, C.byref(device_info), None, C.byref(device)), "vkCreateDevice")

        destroy_device = _load_device_function(
            get_device_proc_addr, device, "vkDestroyDevice", None, [C.c_void_p, C.c_void_p]
        )
        get_device_queue = _load_device_function(
            get_device_proc_addr,
            device,
            "vkGetDeviceQueue",
            None,
            [C.c_void_p, C.c_uint32, C.c_uint32, C.POINTER(C.c_void_p)],
        )
        queue = C.c_void_p()
        print("CALL vkGetDeviceQueue", flush=True)
        get_device_queue(device, selected_queue_family, 0, C.byref(queue))
        if not queue.value:
            raise RuntimeError("vkGetDeviceQueue returned a null graphics queue")

        create_pool = _load_device_function(
            get_device_proc_addr,
            device,
            "vkCreateDescriptorPool",
            C.c_int32,
            [C.c_void_p, C.POINTER(VkDescriptorPoolCreateInfo), C.c_void_p, C.POINTER(C.c_void_p)],
        )
        create_layout = _load_device_function(
            get_device_proc_addr,
            device,
            "vkCreateDescriptorSetLayout",
            C.c_int32,
            [C.c_void_p, C.POINTER(VkDescriptorSetLayoutCreateInfo), C.c_void_p, C.POINTER(C.c_void_p)],
        )
        allocate_sets = _load_device_function(
            get_device_proc_addr,
            device,
            "vkAllocateDescriptorSets",
            C.c_int32,
            [C.c_void_p, C.POINTER(VkDescriptorSetAllocateInfo), C.POINTER(C.c_void_p)],
        )
        create_sampler = _load_device_function(
            get_device_proc_addr,
            device,
            "vkCreateSampler",
            C.c_int32,
            [C.c_void_p, C.POINTER(VkSamplerCreateInfo), C.c_void_p, C.POINTER(C.c_void_p)],
        )
        update_sets = _load_device_function(
            get_device_proc_addr,
            device,
            "vkUpdateDescriptorSets",
            None,
            [C.c_void_p, C.c_uint32, C.POINTER(VkWriteDescriptorSet), C.c_uint32, C.c_void_p],
        )
        destroy_pool = _load_device_function(
            get_device_proc_addr, device, "vkDestroyDescriptorPool", None, [C.c_void_p, C.c_void_p, C.c_void_p]
        )
        destroy_layout = _load_device_function(
            get_device_proc_addr,
            device,
            "vkDestroyDescriptorSetLayout",
            None,
            [C.c_void_p, C.c_void_p, C.c_void_p],
        )
        destroy_sampler = _load_device_function(
            get_device_proc_addr, device, "vkDestroySampler", None, [C.c_void_p, C.c_void_p, C.c_void_p]
        )

        pool_sizes = make_bgfx_pool_sizes()
        pool_info = make_bgfx_pool_info(pool_sizes)
        print("CALL vkCreateDescriptorPool", flush=True)
        _check(create_pool(device, C.byref(pool_info), None, C.byref(descriptor_pool)), "vkCreateDescriptorPool")

        bindings = make_layout_bindings(case)
        layout_info = VkDescriptorSetLayoutCreateInfo(
            VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
            None,
            0,
            len(bindings),
            bindings,
        )
        print("CALL vkCreateDescriptorSetLayout", flush=True)
        _check(
            create_layout(device, C.byref(layout_info), None, C.byref(descriptor_set_layout)),
            "vkCreateDescriptorSetLayout",
        )

        layouts = (C.c_void_p * 1)(descriptor_set_layout.value)
        allocate_info = VkDescriptorSetAllocateInfo(
            VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
            None,
            descriptor_pool,
            1,
            layouts,
        )
        descriptor_set = C.c_void_p()
        print("CALL vkAllocateDescriptorSets", flush=True)
        _check(allocate_sets(device, C.byref(allocate_info), C.byref(descriptor_set)), "vkAllocateDescriptorSets")

        sampler_info = make_sampler_create_info()
        print("CALL vkCreateSampler", flush=True)
        _check(create_sampler(device, C.byref(sampler_info), None, C.byref(sampler)), "vkCreateSampler")
        image_info, write = make_sampler_write(descriptor_set, sampler, case.sampler_binding)
        print(f"CALL vkUpdateDescriptorSets(binding={case.sampler_binding}, type=SAMPLER)", flush=True)
        update_sets(device, 1, C.byref(write), 0, None)
        print(
            f"UPDATED case={case.name} binding={case.sampler_binding} "
            f"sampler=0x{sampler.value:x} queueFamily={selected_queue_family}",
            flush=True,
        )
        del image_info  # Keep the image-info storage alive through vkUpdateDescriptorSets.
    finally:
        if device.value:
            if descriptor_pool.value and destroy_pool:
                print("CALL vkDestroyDescriptorPool", flush=True)
                destroy_pool(device, descriptor_pool, None)
            if sampler.value and destroy_sampler:
                print("CALL vkDestroySampler", flush=True)
                destroy_sampler(device, sampler, None)
            if descriptor_set_layout.value and destroy_layout:
                print("CALL vkDestroyDescriptorSetLayout", flush=True)
                destroy_layout(device, descriptor_set_layout, None)
            if destroy_device:
                print("CALL vkDestroyDevice", flush=True)
                destroy_device(device, None)
        if instance.value and destroy_instance:
            print("CALL vkDestroyInstance", flush=True)
            destroy_instance(instance, None)


def run_suite():
    failed = False
    for case in CASES:
        command = [sys.executable, "-u", os.path.abspath(__file__), "--case", case.name]
        print(f"CASE {case.name}: starting", flush=True)
        try:
            completed = subprocess.run(
                command,
                capture_output=True,
                text=True,
                check=False,
                timeout=CASE_TIMEOUT_SECONDS,
            )
        except subprocess.TimeoutExpired:
            print(f"CASE {case.name}: timed out after {CASE_TIMEOUT_SECONDS}s", flush=True)
            failed = True
            continue
        if completed.stdout:
            print(completed.stdout, end="" if completed.stdout.endswith("\n") else "\n")
        if completed.stderr:
            print(completed.stderr, file=sys.stderr, end="" if completed.stderr.endswith("\n") else "\n")
        if completed.returncode == 0:
            print(f"CASE {case.name}: returned normally", flush=True)
        elif completed.returncode < 0:
            signum = -completed.returncode
            try:
                signal_name = signal.Signals(signum).name
            except ValueError:
                signal_name = f"signal {signum}"
            print(f"CASE {case.name}: terminated by {signal_name}", flush=True)
            failed = True
        else:
            print(f"CASE {case.name}: exited {completed.returncode}", flush=True)
            failed = True
    return 1 if failed else 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    selection = parser.add_mutually_exclusive_group(required=True)
    selection.add_argument("--suite", action="store_true", help="run all cases as isolated child processes")
    selection.add_argument("--case", choices=tuple(CASES_BY_NAME), help="run one Vulkan case")
    args = parser.parse_args()
    if args.suite:
        return run_suite()
    try:
        run_case(CASES_BY_NAME[args.case])
    except Exception as error:
        print(f"ERROR case={args.case}: {error}", file=sys.stderr, flush=True)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
