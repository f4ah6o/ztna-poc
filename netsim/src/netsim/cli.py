from __future__ import annotations

import argparse
import ipaddress
import json
import subprocess
from dataclasses import dataclass
from typing import Any

import yaml
from pyroute2 import IPRoute, NetNS, netns


@dataclass(frozen=True)
class TopologyConfig:
    client_if: str
    client_ip_cidr: str
    client_gw: str
    gateway_client_if: str
    gateway_client_ip_cidr: str
    gateway_saas_if: str
    gateway_saas_ip_cidr: str
    saas_if: str
    saas_ip_cidr: str
    saas_gw: str


def run(cmd: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(cmd, check=True, text=True, capture_output=True)


def load_config(path: str) -> dict[str, Any]:
    with open(path, "r", encoding="utf-8") as f:
        return yaml.safe_load(f)


def parse_topology(cfg: dict[str, Any]) -> TopologyConfig:
    ns_cfg = cfg["topology"]["namespaces"]
    return TopologyConfig(
        client_if=ns_cfg["client"]["ifname"],
        client_ip_cidr=ns_cfg["client"]["ip_cidr"],
        client_gw=ns_cfg["client"]["gateway"],
        gateway_client_if=ns_cfg["gateway"]["ifname_client"],
        gateway_client_ip_cidr=ns_cfg["gateway"]["ip_client_cidr"],
        gateway_saas_if=ns_cfg["gateway"]["ifname_saas"],
        gateway_saas_ip_cidr=ns_cfg["gateway"]["ip_saas_cidr"],
        saas_if=ns_cfg["saas"]["ifname"],
        saas_ip_cidr=ns_cfg["saas"]["ip_cidr"],
        saas_gw=ns_cfg["saas"]["gateway"],
    )


def ensure_namespace(name: str) -> None:
    if name not in netns.listnetns():
        netns.create(name)


def configure_interface(ns_name: str, ifname: str, ip_cidr: str) -> None:
    with NetNS(ns_name) as ns:
        ns.link("set", index=ns.link_lookup(ifname="lo")[0], state="up")
        idx = ns.link_lookup(ifname=ifname)[0]
        ns.addr("replace", index=idx, address=ip_cidr.split("/")[0], prefixlen=int(ip_cidr.split("/")[1]))
        ns.link("set", index=idx, state="up")


def add_default_route(ns_name: str, gw: str) -> None:
    with NetNS(ns_name) as ns:
        ns.route("replace", dst="default", gateway=gw)


def create_topology(topo: TopologyConfig) -> None:
    # Recreate deterministically to keep "create" idempotent for demos.
    destroy_topology()

    ensure_namespace("client")
    ensure_namespace("gateway")
    ensure_namespace("saas")

    ipr = IPRoute()
    try:
        if not ipr.link_lookup(ifname=topo.client_if):
            ipr.link(
                "add",
                ifname=topo.client_if,
                kind="veth",
                peer={"ifname": topo.gateway_client_if},
            )
        if not ipr.link_lookup(ifname=topo.gateway_saas_if):
            ipr.link(
                "add",
                ifname=topo.gateway_saas_if,
                kind="veth",
                peer={"ifname": topo.saas_if},
            )

        for ifname, ns_name in (
            (topo.client_if, "client"),
            (topo.gateway_client_if, "gateway"),
            (topo.gateway_saas_if, "gateway"),
            (topo.saas_if, "saas"),
        ):
            idx = ipr.link_lookup(ifname=ifname)
            if idx:
                ipr.link("set", index=idx[0], net_ns_fd=ns_name)
    finally:
        ipr.close()

    configure_interface("client", topo.client_if, topo.client_ip_cidr)
    configure_interface("gateway", topo.gateway_client_if, topo.gateway_client_ip_cidr)
    configure_interface("gateway", topo.gateway_saas_if, topo.gateway_saas_ip_cidr)
    configure_interface("saas", topo.saas_if, topo.saas_ip_cidr)

    add_default_route("client", topo.client_gw)
    add_default_route("saas", topo.saas_gw)

    try:
        run(["ip", "netns", "exec", "gateway", "sysctl", "-w", "net.ipv4.ip_forward=1"])
    except subprocess.CalledProcessError:
        pass


def ensure_nat_rule(topo: TopologyConfig) -> None:
    client_subnet = str(ipaddress.ip_interface(topo.client_ip_cidr).network)
    check_cmd = [
        "ip",
        "netns",
        "exec",
        "gateway",
        "iptables",
        "-t",
        "nat",
        "-C",
        "POSTROUTING",
        "-s",
        client_subnet,
        "-o",
        topo.gateway_saas_if,
        "-j",
        "MASQUERADE",
    ]
    add_cmd = [
        "ip",
        "netns",
        "exec",
        "gateway",
        "iptables",
        "-t",
        "nat",
        "-A",
        "POSTROUTING",
        "-s",
        client_subnet,
        "-o",
        topo.gateway_saas_if,
        "-j",
        "MASQUERADE",
    ]
    try:
        run(check_cmd)
    except subprocess.CalledProcessError:
        run(add_cmd)


def apply_fault(ns_name: str, ifname: str, delay_ms: int, loss_pct: float) -> None:
    cmd = [
        "ip",
        "netns",
        "exec",
        ns_name,
        "tc",
        "qdisc",
        "replace",
        "dev",
        ifname,
        "root",
        "netem",
    ]
    if delay_ms > 0:
        cmd.extend(["delay", f"{delay_ms}ms"])
    if loss_pct > 0:
        cmd.extend(["loss", f"{loss_pct}%"])
    if delay_ms <= 0 and loss_pct <= 0:
        cmd = ["ip", "netns", "exec", ns_name, "tc", "qdisc", "del", "dev", ifname, "root"]
    try:
        run(cmd)
    except subprocess.CalledProcessError as exc:
        # No qdisc to delete should not fail reset flows.
        if "No such file or directory" not in (exc.stderr or ""):
            raise


def set_link_state(ns_name: str, ifname: str, state: str) -> None:
    with NetNS(ns_name) as ns:
        idx = ns.link_lookup(ifname=ifname)[0]
        ns.link("set", index=idx, state=state)


def print_status() -> None:
    payload: dict[str, Any] = {"namespaces": {}}
    for ns_name in ("client", "gateway", "saas"):
        if ns_name not in netns.listnetns():
            continue
        links = run(["ip", "netns", "exec", ns_name, "ip", "-j", "addr", "show"]).stdout
        routes = run(["ip", "netns", "exec", ns_name, "ip", "-j", "route", "show"]).stdout
        qdisc = run(["ip", "netns", "exec", ns_name, "tc", "-j", "qdisc", "show"]).stdout
        payload["namespaces"][ns_name] = {
            "links": json.loads(links),
            "routes": json.loads(routes),
            "qdisc": json.loads(qdisc),
        }
    print(json.dumps(payload, indent=2))


def destroy_topology() -> None:
    for ns_name in ("client", "gateway", "saas"):
        if ns_name in netns.listnetns():
            netns.remove(ns_name)


def apply_preset(cfg: dict[str, Any], preset: str, topo: TopologyConfig) -> None:
    preset_cfg = cfg.get("fault_presets", {}).get(preset)
    if not preset_cfg:
        raise ValueError(f"Unknown preset: {preset}")

    if preset_cfg.get("link_state"):
        set_link_state("gateway", topo.gateway_saas_if, preset_cfg["link_state"])
        return

    apply_fault(
        ns_name="gateway",
        ifname=topo.gateway_saas_if,
        delay_ms=int(preset_cfg.get("delay_ms", 0)),
        loss_pct=float(preset_cfg.get("loss_pct", 0)),
    )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="pyroute2 based virtual network simulator")
    parser.add_argument("--config", default="/app/config.yaml", help="Path to config.yaml")

    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("create")
    sub.add_parser("destroy")
    sub.add_parser("status")

    fault = sub.add_parser("apply-fault")
    fault.add_argument("--ns", required=True)
    fault.add_argument("--if", dest="ifname", required=True)
    fault.add_argument("--delay-ms", type=int, default=0)
    fault.add_argument("--loss-pct", type=float, default=0)

    link = sub.add_parser("link")
    link.add_argument("--ns", required=True)
    link.add_argument("--if", dest="ifname", required=True)
    link.add_argument("--state", required=True, choices=["up", "down"])

    preset = sub.add_parser("apply-preset")
    preset.add_argument("--name", required=True)

    return parser.parse_args()


def main() -> None:
    args = parse_args()
    cfg = load_config(args.config)
    topo = parse_topology(cfg)

    if args.command == "create":
        create_topology(topo)
        ensure_nat_rule(topo)
        return

    if args.command == "destroy":
        destroy_topology()
        return

    if args.command == "status":
        print_status()
        return

    if args.command == "apply-fault":
        apply_fault(args.ns, args.ifname, args.delay_ms, args.loss_pct)
        return

    if args.command == "link":
        set_link_state(args.ns, args.ifname, args.state)
        return

    if args.command == "apply-preset":
        apply_preset(cfg, args.name, topo)
        return

    raise ValueError(f"Unsupported command: {args.command}")


if __name__ == "__main__":
    main()
