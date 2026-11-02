#!/usr/bin/env python3
import importlib.util
import pathlib
import sys
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
MODULE_PATH = REPO_ROOT / "tools/frame/vulkan_sampler_descriptor_probe.py"
SPEC = importlib.util.spec_from_file_location("vulkan_sampler_descriptor_probe", MODULE_PATH)
probe = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = probe
SPEC.loader.exec_module(probe)


class VulkanSamplerDescriptorProbeTests(unittest.TestCase):
    def test_ctypes_structures_match_64_bit_vulkan_abi(self):
        self.assertEqual(probe.C.sizeof(probe.C.c_void_p), 8)
        expected_sizes = {
            probe.VkApplicationInfo: 48,
            probe.VkInstanceCreateInfo: 64,
            probe.VkDeviceQueueCreateInfo: 40,
            probe.VkDeviceCreateInfo: 72,
            probe.VkPhysicalDeviceDriverProperties: 536,
            probe.VkPhysicalDeviceProperties2: 4112,
            probe.VkDescriptorPoolSize: 8,
            probe.VkDescriptorPoolCreateInfo: 40,
            probe.VkDescriptorSetLayoutBinding: 24,
            probe.VkDescriptorSetLayoutCreateInfo: 32,
            probe.VkDescriptorSetAllocateInfo: 40,
            probe.VkSamplerCreateInfo: 80,
            probe.VkDescriptorImageInfo: 24,
            probe.VkWriteDescriptorSet: 64,
        }
        for structure, expected_size in expected_sizes.items():
            with self.subTest(structure=structure.__name__):
                self.assertEqual(probe.C.sizeof(structure), expected_size)
        self.assertEqual(probe.VkWriteDescriptorSet.pImageInfo.offset, 40)
        self.assertEqual(probe.VkDescriptorSetLayoutCreateInfo.pBindings.offset, 24)

    def test_case_layouts_change_only_the_sampler_binding(self):
        sparse = probe.make_layout_bindings(probe.CASES_BY_NAME["sparse_sampler_19"])
        dense = probe.make_layout_bindings(probe.CASES_BY_NAME["dense_sampler_1"])
        single = probe.make_layout_bindings(probe.CASES_BY_NAME["single_sampler_19"])

        def rows(bindings):
            return [
                (item.binding, item.descriptorType, item.descriptorCount, item.stageFlags)
                for item in bindings
            ]

        sparse_rows = rows(sparse)
        dense_rows = rows(dense)
        self.assertEqual(
            sparse_rows,
            [
                (0, probe.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER_DYNAMIC, 1, probe.VK_SHADER_STAGE_VERTEX_BIT),
                (3, probe.VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE, 1, probe.VK_SHADER_STAGE_FRAGMENT_BIT),
                (19, probe.VK_DESCRIPTOR_TYPE_SAMPLER, 1, probe.VK_SHADER_STAGE_FRAGMENT_BIT),
            ],
        )
        self.assertEqual(dense_rows[0], sparse_rows[0])
        self.assertEqual(dense_rows[1], sparse_rows[1])
        self.assertEqual(dense_rows[2], (1, *sparse_rows[2][1:]))
        self.assertEqual(rows(single), [(19, probe.VK_DESCRIPTOR_TYPE_SAMPLER, 1, probe.VK_SHADER_STAGE_FRAGMENT_BIT)])

    def test_probe_rejects_unexpected_gpu_or_driver(self):
        api_1_2 = probe.VK_API_VERSION_1_2
        self.assertTrue(
            probe.is_expected_turnip_device(
                probe.VK_VENDOR_ID_QUALCOMM,
                probe.VK_DEVICE_ID_ADRENO_750,
                probe.VK_DRIVER_ID_MESA_TURNIP,
                "turnip",
                api_1_2,
            )
        )
        self.assertFalse(
            probe.is_expected_turnip_device(
                probe.VK_VENDOR_ID_QUALCOMM,
                0,
                probe.VK_DRIVER_ID_MESA_TURNIP,
                "turnip",
                api_1_2,
            )
        )
        self.assertFalse(
            probe.is_expected_turnip_device(
                probe.VK_VENDOR_ID_QUALCOMM,
                probe.VK_DEVICE_ID_ADRENO_750,
                0,
                "another driver",
                api_1_2,
            )
        )

    def test_bgfx_descriptor_pool_matches_captured_parameters(self):
        sizes = probe.make_bgfx_pool_sizes()
        pool_info = probe.make_bgfx_pool_info(sizes)
        self.assertEqual(pool_info.flags, probe.VK_DESCRIPTOR_POOL_CREATE_FREE_DESCRIPTOR_SET_BIT)
        self.assertEqual(pool_info.maxSets, 1024)
        self.assertEqual(pool_info.poolSizeCount, 5)
        self.assertEqual(
            [(item.type, item.descriptorCount) for item in sizes],
            [
                (probe.VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE, 16384),
                (probe.VK_DESCRIPTOR_TYPE_SAMPLER, 16384),
                (probe.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER_DYNAMIC, 2048),
                (probe.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 16384),
                (probe.VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, 16384),
            ],
        )

    def test_sampler_write_has_one_live_sampler_and_no_unused_image_handle(self):
        image_info, write = probe.make_sampler_write(0x1234, 0x5678, 19)
        self.assertEqual(write.sType, probe.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET)
        self.assertEqual(write.dstSet, 0x1234)
        self.assertEqual(write.dstBinding, 19)
        self.assertEqual(write.dstArrayElement, 0)
        self.assertEqual(write.descriptorCount, 1)
        self.assertEqual(write.descriptorType, probe.VK_DESCRIPTOR_TYPE_SAMPLER)
        self.assertEqual(write.pImageInfo.contents.sampler, 0x5678)
        self.assertIsNone(write.pImageInfo.contents.imageView)
        self.assertEqual(write.pImageInfo.contents.imageLayout, probe.VK_IMAGE_LAYOUT_UNDEFINED)
        self.assertIsNone(write.pBufferInfo)
        self.assertIsNone(write.pTexelBufferView)
        self.assertIsNotNone(image_info)

    def test_sampler_configuration_matches_the_failing_object(self):
        info = probe.make_sampler_create_info()
        self.assertEqual(info.magFilter, probe.VK_FILTER_LINEAR)
        self.assertEqual(info.minFilter, probe.VK_FILTER_LINEAR)
        self.assertEqual(info.mipmapMode, probe.VK_SAMPLER_MIPMAP_MODE_LINEAR)
        self.assertEqual(info.addressModeU, probe.VK_SAMPLER_ADDRESS_MODE_REPEAT)
        self.assertEqual(info.addressModeV, probe.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE)
        self.assertEqual(info.addressModeW, probe.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE)
        self.assertEqual(info.anisotropyEnable, 0)
        self.assertEqual(info.maxAnisotropy, 16.0)
        self.assertEqual(info.compareEnable, 0)
        self.assertEqual(info.minLod, 0.0)
        self.assertEqual(info.maxLod, 1000.0)
        self.assertEqual(info.borderColor, probe.VK_BORDER_COLOR_FLOAT_OPAQUE_BLACK)


if __name__ == "__main__":
    unittest.main(verbosity=2)
