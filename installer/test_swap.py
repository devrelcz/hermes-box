import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


LIB = Path(__file__).resolve().parent.parent / "lib/swap.sh"
HOST_TOOLS = ("flock", "findmnt", "mkswap", "blkid", "stat")


@unittest.skipUnless(all(shutil.which(tool) for tool in HOST_TOOLS), "requires Linux swap tools")
class SetupSwapTest(unittest.TestCase):
    def setUp(self):
        directory = Path(self.enterContext(tempfile.TemporaryDirectory()))
        self.swap = directory / "hobcrew-box.swap"
        self.fstab = directory / "fstab"
        self.swaps = directory / "swaps"
        self.fstab.write_text("# test fstab")
        self.swaps.write_text("Filename Type Size Used Priority\n")

    def ensure_swap(self, available=6000, fail_activation=False):
        # Format a small real swap file; never change the host's active swap.
        return subprocess.run(
            ["bash", "-euc", r'''
                . "$1"
                fixture_available="$5"
                fixture_fail_activation="$6"
                fixture_active_swaps="$4"
                df() { printf 'Filesystem 1M-blocks Used Available Capacity Mounted on\ndisk 8000 0 %s 0%% /\n' "$fixture_available"; }
                dd() { command dd if=/dev/zero "$2" bs=1M count=4 status=none; }
                swapon() {
                  [ "$fixture_fail_activation" -eq 0 ] || return 1
                  printf '%s file 4092 0 -2\n' "$2" >> "$fixture_active_swaps"
                }
                ensure_swap "$2" "$3" "$4"
            ''', "swap-test", str(LIB), str(self.swap), str(self.fstab), str(self.swaps),
             str(available), str(int(fail_activation))],
            capture_output=True, text=True, timeout=10,
        )

    def test_creates_and_persists_swap_once(self):
        result = self.ensure_swap()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.swap.stat().st_mode & 0o777, 0o600)
        self.assertIn(f"{self.swap} none swap defaults 0 0", self.fstab.read_text())
        original = self.fstab.read_text()
        result = self.ensure_swap(fail_activation=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.fstab.read_text(), original)

    def test_preserves_existing_swap_configuration(self):
        existing = "UUID=custom none swap noauto 0 0\n"
        self.fstab.write_text(existing)
        result = self.ensure_swap()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.swap.exists())
        self.assertEqual(self.fstab.read_text(), existing)

    def test_preserves_active_swap(self):
        self.swaps.write_text("Filename Type Size Used Priority\n/dev/zram0 partition 2048 0 -2\n")
        result = self.ensure_swap()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.swap.exists())
        self.assertEqual(self.fstab.read_text(), "# test fstab")

    def test_insufficient_disk_or_failed_activation_leaves_no_swap_file(self):
        for options in ({"available": 2000}, {"fail_activation": True}):
            with self.subTest(options=options):
                result = self.ensure_swap(**options)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(list(self.swap.parent.glob("hobcrew-box.swap*")), [])
                self.assertEqual(self.fstab.read_text(), "# test fstab")

    @unittest.skipUnless(os.getuid() == 0, "installer resumes only root-owned files")
    def test_resumes_a_formatted_swap_without_reallocating_it(self):
        self.assertEqual(self.ensure_swap().returncode, 0)
        inode = self.swap.stat().st_ino
        self.fstab.write_text("# test fstab")
        self.swaps.write_text("Filename Type Size Used Priority\n")
        result = self.ensure_swap(available=0)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.swap.stat().st_ino, inode)
        self.assertIn(f"{self.swap} none swap defaults 0 0", self.fstab.read_text())
