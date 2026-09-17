#!/usr/bin/env python3
"""Run the boot script against temporary sysfs/procfs fixtures, never the host."""

import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "overlay/data/live-build-config/includes.chroot/usr/local/sbin/rockchip-net-tune.sh"


class NetTuneTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="rockchip-net-tune-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.put("etc/rockchip/net-tune.conf", "")
        self.put("proc/sys/net/core/rps_sock_flow_entries", "65536\n")
        self.put("calls", "")
        for cpu in range(8):
            base = f"sys/devices/system/cpu/cpu{cpu}"
            self.put(f"{base}/cpu_capacity", "397\n" if cpu < 4 else "1024\n")
            self.put(f"{base}/cpufreq/scaling_governor", "ondemand\n")
        for index in range(2):
            base = f"sys/class/net/eth{index}"
            self.put(f"{base}/flags", "0x1003\n")
            for vector in range(32):
                irq = 101 + index * 32 + vector
                self.put(f"{base}/device/msi_irqs/{irq}", "msix\n")
                self.put(f"proc/irq/{irq}/smp_affinity_list", "0-7\n")
            for queue in range(4):
                self.put(f"{base}/queues/rx-{queue}/rps_cpus", "0\n")
                self.put(f"{base}/queues/rx-{queue}/rps_flow_cnt", "0\n")
            for queue in range(2):
                self.put(f"{base}/queues/tx-{queue}/xps_cpus", "00\n")
        self.command("nproc", "printf '8\\n'\n")
        self.command("sleep", ":\n")
        self.command("ethtool", 'printf "%s\\n" "$*" >> "$CALLS"\n')

    def put(self, name, text):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
        return path

    def command(self, name, body):
        self.put(f"bin/{name}", "#!/bin/sh\n" + body).chmod(0o755)

    def run_script(self):
        # Keep test-only path injection outside the deployed script. All reads
        # and writes to Linux pseudo-filesystems and config target the fixture.
        source = SCRIPT.read_text()
        source = re.sub(r"/(?:sys|proc|etc)/", lambda match: str(self.root) + match[0], source)
        script = self.put("net-tune.sh", source)
        environment = os.environ.copy()
        environment.pop("IFACE_CPU", None)
        environment.pop("GOVERNOR", None)
        environment.update(PATH=f"{self.root}/bin:{os.environ['PATH']}", CALLS=str(self.root / "calls"))
        result = subprocess.run(["/bin/sh", str(script)], env=environment,
                                text=True, capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return (self.root / "calls").read_text().splitlines()

    def test_preserves_board_defaults(self):
        self.run_script()
        self.assert_irq_targets((4, 5, 6, 7))
        for cpu in range(8):
            path = self.root / f"sys/devices/system/cpu/cpu{cpu}/cpufreq/scaling_governor"
            self.assertEqual(path.read_text(), "performance\n")
        for index in range(2):
            for queue in range(2):
                path = self.root / f"sys/class/net/eth{index}/queues/tx-{queue}/xps_cpus"
                self.assertEqual(path.read_text(), "fe\n")

    def test_preserves_explicit_board_overrides(self):
        self.put("etc/rockchip/net-tune.conf", 'GOVERNOR="ondemand"\nIFACE_CPU="eth0:6 eth1:7"\n')
        self.run_script()
        for index in range(2):
            for vector in range(32):
                path = self.root / f"proc/irq/{101 + index * 32 + vector}/smp_affinity_list"
                self.assertEqual(path.read_text(), f"{6 + index}\n")
        for cpu in range(8):
            path = self.root / f"sys/devices/system/cpu/cpu{cpu}/cpufreq/scaling_governor"
            self.assertEqual(path.read_text(), "ondemand\n")

    def assert_irq_targets(self, targets):
        for index in range(2):
            for vector in range(32):
                path = self.root / f"proc/irq/{101 + index * 32 + vector}/smp_affinity_list"
                self.assertEqual(path.read_text(), f"{targets[(index + vector) % len(targets)]}\n", str(path))

    def test_reserved_vectors_do_not_shift_next_interface(self):
        # The first interface's vector count is not a CPU offset for the second.
        for vector in range(5, 32):
            (self.root / f"sys/class/net/eth0/device/msi_irqs/{101 + vector}").unlink()
        self.run_script()
        for vector in range(32):
            path = self.root / f"proc/irq/{133 + vector}/smp_affinity_list"
            self.assertEqual(path.read_text(), f"{(5, 6, 7, 4)[vector % 4]}\n")

    def test_offline_big_core_is_not_selected(self):
        self.put("sys/devices/system/cpu/cpu7/online", "0\n")
        self.command("nproc", "printf '7\\n'\n")
        self.run_script()
        self.assert_irq_targets((4, 5, 6))

    def test_missing_capacity_uses_homogeneous_fallback(self):
        for cpu in range(8):
            (self.root / f"sys/devices/system/cpu/cpu{cpu}/cpu_capacity").unlink()
        self.run_script()
        self.assert_irq_targets((1, 2, 3, 4, 5, 6, 7))

    def test_noncontiguous_online_cores_and_restricted_nproc(self):
        for cpu in (1, 2, 3, 4, 6):
            self.put(f"sys/devices/system/cpu/cpu{cpu}/online", "0\n")
        # An affinity-limited caller's nproc does not describe system topology.
        self.command("nproc", "printf '1\\n'\n")
        self.run_script()
        self.assert_irq_targets((5, 7))

    def test_cpu_zero_reservation_uses_online_core_count(self):
        self.put("sys/devices/system/cpu/cpu0/cpu_capacity", "2048\n")
        self.command("nproc", "printf '1\\n'\n")
        self.run_script()
        self.assert_irq_targets((4, 5, 6, 7))

    def test_single_online_cpu_zero_is_available(self):
        for cpu in range(1, 8):
            self.put(f"sys/devices/system/cpu/cpu{cpu}/online", "0\n")
        self.run_script()
        self.assert_irq_targets((0,))

    def test_irq_order_is_numeric_across_digit_boundaries(self):
        directory = self.root / "sys/class/net/eth0/device/msi_irqs"
        shutil.rmtree(directory)
        for irq in (9, 10, 99, 100):
            self.put(f"sys/class/net/eth0/device/msi_irqs/{irq}", "msix\n")
            self.put(f"proc/irq/{irq}/smp_affinity_list", "0-7\n")
        self.run_script()
        for irq, cpu in zip((9, 10, 99, 100), (4, 5, 6, 7)):
            self.assertEqual((self.root / f"proc/irq/{irq}/smp_affinity_list").read_text(), f"{cpu}\n")

    def test_legacy_interrupt_lookup_is_preserved(self):
        for index in range(2):
            shutil.rmtree(self.root / f"sys/class/net/eth{index}/device/msi_irqs")
        self.put("proc/interrupts", "133: 0 0 GIC eth1\n101: 0 0 GIC eth0\n")
        self.run_script()
        self.assertEqual((self.root / "proc/irq/101/smp_affinity_list").read_text(), "4\n")
        self.assertEqual((self.root / "proc/irq/133/smp_affinity_list").read_text(), "5\n")

    def test_leaves_vyos_steering_values_untouched(self):
        for mask, count in (("0\n", "0\n"), ("fe\n", "8192\n")):
            with self.subTest(mask=mask, count=count):
                paths = {"proc/sys/net/core/rps_sock_flow_entries": "65536\n"}
                for index in range(2):
                    for queue in range(4):
                        base = f"sys/class/net/eth{index}/queues/rx-{queue}"
                        paths[f"{base}/rps_cpus"] = mask
                        paths[f"{base}/rps_flow_cnt"] = count
                for path, value in paths.items():
                    self.put(path, value)
                self.run_script()
                for path, value in paths.items():
                    self.assertEqual((self.root / path).read_text(), value, path)

    def test_only_retains_udp_gro_offload_override(self):
        calls = self.run_script()
        self.assertEqual(calls, [f"-K eth{i} rx-udp-gro-forwarding on" for i in range(2)])

    def test_unsupported_udp_gro_does_not_abort_board_settings(self):
        self.command("ethtool", 'printf "%s\\n" "$*" >> "$CALLS"\nexit 1\n')
        self.test_preserves_board_defaults()

    def test_preserves_xps_masks_on_small_boards(self):
        for count, mask in ((1, "1"), (2, "3"), (3, "7"), (4, "e")):
            with self.subTest(cpus=count):
                shutil.rmtree(self.root / "sys/devices/system/cpu")
                for cpu in range(count):
                    base = f"sys/devices/system/cpu/cpu{cpu}"
                    self.put(f"{base}/cpu_capacity", "1024\n")
                    self.put(f"{base}/cpufreq/scaling_governor", "ondemand\n")
                self.command("nproc", f"printf '{count}\\n'\n")
                self.run_script()
                self.assert_irq_targets(tuple(range(1 if count >= 3 else 0, count)))
                for index in range(2):
                    for queue in range(2):
                        path = self.root / f"sys/class/net/eth{index}/queues/tx-{queue}/xps_cpus"
                        self.assertEqual(path.read_text(), mask + "\n")

    def test_skips_unmanaged_and_virtual_interfaces(self):
        self.put("sys/class/net/wlan0/device/msi_irqs/200", "msix\n")
        self.put("proc/irq/200/smp_affinity_list", "0-7\n")
        for name in ("wlan0", "eth9"):
            self.put(f"sys/class/net/{name}/queues/tx-0/xps_cpus", "0\n")
        calls = self.run_script()
        self.assertEqual(calls, [f"-K eth{i} rx-udp-gro-forwarding on" for i in range(2)])
        self.assertEqual((self.root / "proc/irq/200/smp_affinity_list").read_text(), "0-7\n")
        for name in ("wlan0", "eth9"):
            self.assertEqual((self.root / f"sys/class/net/{name}/queues/tx-0/xps_cpus").read_text(), "0\n")


if __name__ == "__main__":
    unittest.main()
