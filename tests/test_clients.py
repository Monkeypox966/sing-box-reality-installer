"""Test the real POSIX-shell renderers with deterministic network responses."""
import ipaddress
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "setup-sing-box.sh"


class ClientOutputTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="sing-box-output-test-")
        self.addCleanup(self.temp.cleanup)
        self.mockbin = Path(self.temp.name)
        wget = self.mockbin / "wget"
        wget.write_text('''#!/bin/sh
case "$1" in
  -4) [ -n "${TEST_IPV4:-}" ] || exit 1; printf '%s' "$TEST_IPV4" ;;
  -6) [ -n "${TEST_IPV6:-}" ] || exit 1; printf '%s' "$TEST_IPV6" ;;
  *) exit 99 ;;
esac
''', encoding="utf-8")
        wget.chmod(0o755)
        self.env = dict(os.environ, SING_BOX_SETUP_LIBRARY_ONLY="1")
        self.env["PATH"] = str(self.mockbin) + os.pathsep + self.env["PATH"]

    def shell(self, code, **env):
        return subprocess.run(
            ["sh", "-eu", "-c", '. "$1"; ' + code, "test", str(SCRIPT)],
            env=dict(self.env, **env), capture_output=True, text=True, check=True,
        )

    def render(self, ipv4="198.51.100.10", ipv6="2606:4700:4700::1111", mode="dual", host=""):
        code = '''IP_MODE="$TEST_MODE"; CUSTOM_HOST="$TEST_HOST";
EXT_PORT=57111; UUID=11111111-1111-4111-8111-111111111111;
SNI=amd.com; PUBLIC_KEY=test-public-key; SHORT_ID=0012; print_client_yaml'''
        result = self.shell(code, TEST_IPV4=ipv4, TEST_IPV6=ipv6, TEST_MODE=mode, TEST_HOST=host)
        return yaml.safe_load(result.stdout)["proxies"], result

    def test_dual_stack_is_two_independent_yaml_nodes(self):
        nodes, result = self.render()
        self.assertEqual([node["name"] for node in nodes], ["reality-ipv4", "reality-ipv6"])
        self.assertEqual(ipaddress.ip_address(nodes[0]["server"]).version, 4)
        self.assertEqual(ipaddress.ip_address(nodes[1]["server"]).version, 6)
        self.assertNotIn('server: [', result.stdout)
        for key in ("port", "uuid", "servername", "reality-opts", "flow"):
            self.assertEqual(nodes[0][key], nodes[1][key])
        self.assertEqual(nodes[1]["reality-opts"]["short-id"], "0012")
        self.assertIsInstance(nodes[1]["server"], str)

    def test_ipv4_only_when_ipv6_unavailable(self):
        nodes, _ = self.render(ipv6="")
        self.assertEqual([node["name"] for node in nodes], ["reality-ipv4"])

    def test_ipv6_only_host(self):
        nodes, _ = self.render(ipv4="")
        self.assertEqual([node["name"] for node in nodes], ["reality-ipv6"])

    def test_listen_modes_limit_automatic_output(self):
        for mode, expected in (("4", "reality-ipv4"), ("6", "reality-ipv6")):
            with self.subTest(mode=mode):
                nodes, _ = self.render(mode=mode)
                self.assertEqual([node["name"] for node in nodes], [expected])

    def test_custom_ipv4_keeps_nat_endpoint_and_adds_ipv6(self):
        nodes, _ = self.render(host="203.0.113.20")
        self.assertEqual(nodes[0]["server"], "203.0.113.20")
        self.assertEqual(nodes[1]["name"], "reality-ipv6")

    def test_custom_ipv6_is_not_duplicated_or_bracketed(self):
        nodes, _ = self.render(host="[2606:4700:4700::1111]")
        self.assertEqual(len(nodes), 2)
        self.assertEqual(nodes[1]["server"], "2606:4700:4700::1111")

    def test_domain_is_preserved_with_ipv6_alternative(self):
        nodes, _ = self.render(host="proxy.example.com")
        self.assertEqual([node["name"] for node in nodes], ["reality-custom", "reality-ipv6"])
        self.assertEqual(nodes[0]["server"], "proxy.example.com")

    def test_explicit_host_in_single_family_mode_is_single_node(self):
        for mode in ("4", "6"):
            nodes, _ = self.render(mode=mode, host="proxy.example.com")
            self.assertEqual(len(nodes), 1)

    def test_invalid_or_nonpublic_ipv6_is_not_printed(self):
        for candidate in ("::1", "::", "fe80::1", "fd00::1", "fc00::1", "ff02::1", "::ffff:192.0.2.1", "<html>oops</html>", "2001:::1", "2001:db8:1:2:3:4:5:6:7", "2001:db8:1:2:3:4:5", "2001:db8:1:2:3:4:5:00000"):
            with self.subTest(candidate=candidate):
                nodes, _ = self.render(ipv6=candidate)
                self.assertEqual(len(nodes), 1)

    def test_malformed_ipv4_is_not_printed(self):
        for candidate in ("256.1.1.1", "1.2.3", "bad response"):
            nodes, _ = self.render(ipv4=candidate, ipv6="")
            self.assertEqual(nodes[0]["name"], "reality-manual")

    def test_both_probes_failed_yields_marked_placeholder(self):
        nodes, result = self.render(ipv4="", ipv6="")
        self.assertEqual(nodes[0]["server"], "<server-ip-or-domain>")
        self.assertIn("detection failed", result.stderr)

    def test_server_config_is_valid_json_and_ipv6_listens_on_all_interfaces(self):
        result = self.shell('''DNS_SERVER=8.8.8.8; STRATEGY=prefer_ipv6; LISTEN_ADDR=::;
PORT=57111; UUID=11111111-1111-4111-8111-111111111111; SNI=amd.com;
PRIVATE_KEY=test-private-key; SHORT_ID=0012; write_server_config''')
        config = json.loads(result.stdout)
        self.assertEqual(config["inbounds"][0]["listen"], "::")
        self.assertEqual(config["inbounds"][0]["listen_port"], 57111)
        self.assertEqual([outbound["type"] for outbound in config["outbounds"]], ["direct"])

    def test_help_needs_no_root_and_invalid_arguments_fail_early(self):
        result = subprocess.run(["sh", str(SCRIPT), "-h"], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0)
        result = subprocess.run(["sh", str(SCRIPT), "-p", "70000"], capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("internal port", result.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)
