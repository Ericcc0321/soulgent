import json
import os
import sys
import tempfile
import unittest

from PIL import Image

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "tools"))
import build_pets  # noqa: E402


def make_sheet(path, row=3, frames=5):
    img = Image.new("RGBA", (1536, 1872), (0, 0, 0, 0))
    for i in range(frames):
        img.paste((255, 0, 0, 255), (i * 192 + 10, row * 208 + 10, i * 192 + 100, row * 208 + 100))
    if path.endswith(".png"):
        img.save(path, "PNG")
    else:
        img.save(path, "WEBP", lossless=True)
    return img


class PetsTest(unittest.TestCase):
    def test_count_frames(self):
        with tempfile.TemporaryDirectory() as d:
            img = make_sheet(os.path.join(d, "s.webp"))
            self.assertEqual(build_pets.count_frames(img, 3), 5)
            self.assertEqual(build_pets.count_frames(img, 0), 1)

    def test_png_spritesheet_used_when_no_webp(self):
        with tempfile.TemporaryDirectory() as d:
            src = os.path.join(d, "src")
            os.makedirs(os.path.join(src, "p-png"))
            make_sheet(os.path.join(src, "p-png", "spritesheet.png"))
            os.makedirs(os.path.join(src, "p-both"))
            make_sheet(os.path.join(src, "p-both", "spritesheet.webp"))
            make_sheet(os.path.join(src, "p-both", "spritesheet.png"))
            m = build_pets.build([src], os.path.join(d, "out"))
            self.assertEqual(m["p-png"]["3"], 5)
            self.assertIn("p-both", m)
            self.assertTrue(build_pets._find_sources([src])["p-both"].endswith(".webp"))

    def test_build(self):
        with tempfile.TemporaryDirectory() as d:
            src = os.path.join(d, "src")
            os.makedirs(os.path.join(src, "test-pet"))
            make_sheet(os.path.join(src, "test-pet", "spritesheet.webp"))
            out = os.path.join(d, "out")
            m = build_pets.build([src], out)
            self.assertEqual(m["test-pet"]["3"], 5)
            self.assertEqual(Image.open(os.path.join(out, "test-pet", "3.webp")).size, (480, 104))
            self.assertEqual(Image.open(os.path.join(out, "test-pet", "still.webp")).size, (96, 104))
            with open(os.path.join(out, "manifest.json")) as f:
                self.assertEqual(json.load(f), m)
            # unchanged source is skipped
            p = os.path.join(out, "test-pet", "3.webp")
            os.utime(p, (1, 1))
            m2 = build_pets.build([src], out)
            self.assertEqual(m2, m)
            self.assertEqual(os.stat(p).st_mtime, 1)

    def test_caps_and_figure(self):
        """caps.json is aggregated into the entry; the one chosen by --figure carries figure (figure.json verbatim); a re-run reuses it without re-cutting the image."""
        with tempfile.TemporaryDirectory() as d:
            src = os.path.join(d, "src")
            for name in ("pet-one", "pet-two"):
                os.makedirs(os.path.join(src, name))
                make_sheet(os.path.join(src, name, "spritesheet.webp"))
            out = os.path.join(d, "out")
            build_pets.build([src], out)
            with open(os.path.join(out, "pet-one", "caps.json"), "w") as f:
                json.dump({"walk": True}, f)
            with open(os.path.join(out, "pet-two", "figure.json"), "w") as f:
                json.dump({"top": 50, "dockClip": 3}, f)
            p = os.path.join(out, "pet-two", "3.webp")
            os.utime(p, (1, 1))
            m = build_pets.build([src], out, figure="pet-two")
            self.assertEqual(m["pet-one"]["caps"], {"walk": True})
            self.assertNotIn("figure", m["pet-one"])
            self.assertEqual(m["pet-two"]["figure"], {"top": 50, "dockClip": 3})
            self.assertEqual(m["pet-two"]["3"], 5)
            self.assertEqual(os.stat(p).st_mtime, 1)  # adding caps / figure to the entry does not trigger a re-cut
            m2 = build_pets.build([src], out)  # no --figure given: reuse the previous one
            self.assertEqual(m2, m)
            m3 = build_pets.build([src], out, figure="")
            self.assertNotIn("figure", m3["pet-two"])
            self.assertEqual(m3["pet-one"]["caps"], {"walk": True})

    def test_first_source_wins(self):
        with tempfile.TemporaryDirectory() as d:
            for name, n in (("s1", 2), ("s2", 4)):
                os.makedirs(os.path.join(d, name, "p"))
                make_sheet(os.path.join(d, name, "p", "spritesheet.webp"), frames=n)
            m = build_pets.build([os.path.join(d, "s1"), os.path.join(d, "s2")], os.path.join(d, "o"))
            self.assertEqual(m["p"]["3"], 2)


if __name__ == "__main__":
    unittest.main()
