#!/usr/bin/env python3
# ---------------------------------------------------------------------------
# hotkey-capture.py 的单元测试。
#
# 只测纯函数（像素转换 / 模块加载），不需要运行中的 VM；
# fb-shm 抓帧、XRecord、触发 socket 这些 I/O 路径已在实机验证。
#
# 运行: python3 deploy/scripts/tests/test_hotkey_capture.py
# ---------------------------------------------------------------------------
import importlib.util
import os
import unittest

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
HC_PATH = os.path.join(HERE, "..", "hotkey-capture.py")


def _load_hc():
    spec = importlib.util.spec_from_file_location("hc_under_test", HC_PATH)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


hc = _load_hc()


class ToRgbTest(unittest.TestCase):
    """fb-shm 像素是 BGR0（字节序 B,G,R,X），转出来必须是正确的 RGB。"""

    def test_bgr0_no_padding(self):
        # 2x1 两个像素：纯红 (R=255) 与纯蓝 (B=255)，BGR0 字节排列。
        w, h, stride = 2, 1, 8
        buf = bytes([0, 0, 255, 0,    # 像素0: B=0 G=0 R=255 -> 红
                     255, 0, 0, 0])   # 像素1: B=255 G=0 R=0 -> 蓝
        rgb = hc.Capturer._to_rgb(buf, w, h, stride,
                                  hc.fbshm.FB_SHM_FOURCC_BGR0)
        self.assertEqual(rgb.shape, (1, 2, 3))
        np.testing.assert_array_equal(rgb[0, 0], [255, 0, 0])  # 红
        np.testing.assert_array_equal(rgb[0, 1], [0, 0, 255])  # 蓝

    def test_stride_padding_stripped(self):
        # 1 个像素但 stride=8（行尾 4 字节 padding 必须被丢掉）。
        w, h, stride = 1, 1, 8
        buf = bytes([10, 20, 30, 0,   # 有效像素 B=10 G=20 R=30
                     99, 99, 99, 99])  # padding，不能进结果
        rgb = hc.Capturer._to_rgb(buf, w, h, stride,
                                  hc.fbshm.FB_SHM_FOURCC_BGR0)
        self.assertEqual(rgb.shape, (1, 1, 3))
        np.testing.assert_array_equal(rgb[0, 0], [30, 20, 10])

    def test_bad_fourcc_raises(self):
        with self.assertRaises(RuntimeError):
            hc.Capturer._to_rgb(b"\0\0\0\0", 1, 1, 4, 0xDEADBEEF)

    def test_short_buffer_raises(self):
        with self.assertRaises(RuntimeError):
            hc.Capturer._to_rgb(b"\0\0\0", 1, 1, 4,
                                hc.fbshm.FB_SHM_FOURCC_BGR0)


class ModuleTest(unittest.TestCase):
    def test_fbshm_loaded(self):
        # importlib 装载 + sys.modules 登记必须成功，否则 @dataclass 会炸。
        self.assertTrue(hasattr(hc.fbshm, "FrameReader"))
        self.assertTrue(hasattr(hc.fbshm, "hello"))

    def test_capturer_constructs(self):
        cap = hc.Capturer("/tmp/does-not-exist.fb", "/tmp/hc-unittest-out")
        # socket 不存在时 capture() 应安全返回 None，不抛异常。
        self.assertIsNone(cap.capture("unittest"))


if __name__ == "__main__":
    unittest.main(verbosity=2)
