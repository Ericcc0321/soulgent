"""helper/install.sh --print: SOULGENT_* variables from the install environment are persisted into the plist EnvironmentVariables."""
import os
import plistlib
import subprocess
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
INSTALL = os.path.join(ROOT, "helper", "install.sh")


def printed(extra):
    env = {k: v for k, v in os.environ.items() if not k.startswith("SOULGENT_")}
    env.update(extra)
    out = subprocess.run(["bash", INSTALL, "--print"], env=env, capture_output=True, check=True).stdout
    return plistlib.loads(out)


class InstallEnvTest(unittest.TestCase):
    def test_supported_vars_reach_plist(self):
        p = printed({"SOULGENT_PANEL": "/Apps/Custom/Soulgent.app", "SOULGENT_ORCA_BIN": "/opt/custom/orca"})
        e = p["EnvironmentVariables"]
        self.assertEqual(e["SOULGENT_PANEL"], "/Apps/Custom/Soulgent.app")
        self.assertEqual(e["SOULGENT_ORCA_BIN"], "/opt/custom/orca")
        self.assertEqual(e["PYTHONUTF8"], "1")

    def test_values_are_xml_escaped(self):
        p = printed({"SOULGENT_PANEL": "/Apps/A&B <x>/S.app"})
        self.assertEqual(p["EnvironmentVariables"]["SOULGENT_PANEL"], "/Apps/A&B <x>/S.app")

    def test_unset_empty_and_unknown_are_not_written(self):
        p = printed({"SOULGENT_CLAUDE_DIR": "", "SOULGENT_NOT_A_SETTING": "x"})
        self.assertEqual(p["EnvironmentVariables"], {"PYTHONUTF8": "1"})
        self.assertEqual(p["Label"], "io.github.ericcc0321.soulgent.helper")


if __name__ == "__main__":
    unittest.main()
