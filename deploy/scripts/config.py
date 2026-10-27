# Copyright (c) Huawei Technologies Co., Ltd. 2026. All rights reserved.
"""AgentOS 集群配置解析与角色推导工具。

读取 ~/.agentos/deploy/config.yaml，提供：
- 本机 IP 获取
- 角色推导（is_etcd_node / is_function_master）
- etcd initial-cluster 字符串生成
- executor 所需 etcd address 列表生成

供 generate-systemd-units.py 和 agentos.sh 调用。
"""
import sys
import json
import socket
import argparse
import logging
from pathlib import Path

DEFAULT_CONFIG_PATH = Path.home() / ".agentos" / "deploy" / "config.yaml"
ETCD_PEER_PORT = 32380
ETCD_CLIENT_PORT = 32379

# CLI 结果走 stdout（pure message format，agentos.sh 用 $(...) 取值不受影响）；
# 诊断信息走 stderr，不污染结果输出。
_LOGGER = logging.getLogger("agentos.config")
_stdout_h = logging.StreamHandler(sys.stdout)
_stdout_h.setLevel(logging.INFO)
_stdout_h.setFormatter(logging.Formatter("%(message)s"))
_stderr_h = logging.StreamHandler(sys.stderr)
_stderr_h.setLevel(logging.WARNING)
_stderr_h.setFormatter(logging.Formatter("[%(levelname)s] %(message)s"))
_LOGGER.addHandler(_stdout_h)
_LOGGER.addHandler(_stderr_h)
_LOGGER.setLevel(logging.INFO)
_LOGGER.propagate = False

# 通配 IP：本机真实 IP 不在列表时按这些兜底匹配（单机调试默认 config 场景）
WILDCARD_IPS = ("127.0.0.1", "0.0.0.0")


def _strip_quotes(s: str) -> str:
    s = s.strip()
    if len(s) >= 2 and (s[0] == s[-1] == '"' or s[0] == s[-1] == "'"):
        return s[1:-1]
    return s


def _parse_flow_list(val: str) -> list | None:
    """解析流式列表值：[] / ["a", "b"] / [a, b]；非列表形态返回 None。

    按逗号切分，不支持元素内含逗号（需要时请用块状列表写法）——
    config.yaml 的列表用途（IP:port / IP）不会出现逗号。
    """
    v = val.strip()
    if not (v.startswith("[") and v.endswith("]")):
        return None
    inner = v[1:-1].strip()
    if not inner:
        return []
    items = []
    for part in inner.split(","):
        part = part.strip()
        if not part:
            raise ValueError(f"Invalid flow list item (empty): {val}")
        items.append(_strip_quotes(part))
    return items


def _parse_yaml_v2(text: str) -> dict:
    """两阶段 YAML 解析器：先 token 化，再组装。

    支持 config.yaml 用到的语法：dict、list（块状与流式）、scalar、注释。
    """
    tokens = []
    for raw in text.splitlines():
        stripped = raw.strip()
        # 整行注释
        if stripped.startswith("#"):
            continue
        # 去掉行尾注释
        line = raw.split(" #", 1)[0].rstrip()
        if not line.strip():
            continue
        indent = len(line) - len(line.lstrip())
        content = line.strip()
        if content.startswith("- "):
            tokens.append((indent, "list_item", content[2:].strip()))
        elif content == "-":
            tokens.append((indent, "list_item", ""))
        else:
            tokens.append((indent, "kv", content))

    def parse_block(start: int, parent_indent: int):
        obj = {}
        items = []
        i = start
        seen_kv = False
        seen_list = False
        while i < len(tokens):
            indent, kind, payload = tokens[i]
            if indent <= parent_indent:
                break
            if kind == "list_item":
                if seen_kv:
                    raise ValueError("Mixing list and dict at same level")
                seen_list = True
                items.append(_strip_quotes(payload))
                i += 1
            else:
                if seen_list:
                    raise ValueError("Mixing list and dict at same level")
                seen_kv = True
                if ":" not in payload:
                    raise ValueError(f"Invalid line (no key:value): {payload}")
                key, _, val = payload.partition(":")
                key = key.strip()
                val = val.strip()
                if val:
                    flow = _parse_flow_list(val)
                    if flow is not None:
                        obj[key] = flow
                    else:
                        obj[key] = _strip_quotes(val)
                    i += 1
                else:
                    if i + 1 < len(tokens) and tokens[i + 1][0] > indent:
                        sub, i = parse_block(i + 1, indent)
                        obj[key] = sub
                    else:
                        obj[key] = {}
                        i += 1
        if seen_list:
            return items, i
        return obj, i

    result, _ = parse_block(0, -1)
    if isinstance(result, list):
        raise ValueError("Top-level YAML cannot be a list")
    return result


def load_full_config(config_path: Path = DEFAULT_CONFIG_PATH) -> dict:
    """加载 config.yaml，返回完整顶层配置字典（cluster 及其余顶层字段）。

    优先用 PyYAML，未安装时回退到内联简单解析器（两者对 config.yaml 用到的
    dict/块状与流式 list/scalar/注释语法解析结果一致；内联解析器的流式列表
    不支持元素内含逗号，该场景请用块状写法）。
    """
    if not config_path.exists():
        raise FileNotFoundError(f"Config file not found: {config_path}")
    with open(config_path, "r", encoding="utf-8") as f:
        text = f.read()
    try:
        import yaml
        data = yaml.safe_load(text)
    except ImportError:
        data = _parse_yaml_v2(text)
    if not isinstance(data, dict):
        raise ValueError(f"Invalid config: top level must be a mapping in {config_path}")
    return data


def load_config(config_path: Path = DEFAULT_CONFIG_PATH) -> dict:
    """加载 config.yaml，校验并返回 cluster 配置字典。"""
    data = load_full_config(config_path)
    cluster = data.get("cluster")
    if not cluster or not isinstance(cluster, dict):
        raise ValueError(f"Invalid config: missing 'cluster' section in {config_path}")
    for field in ("etcd_nodes", "master_nodes", "ingress_virtual_ip"):
        if field not in cluster:
            raise ValueError(f"Invalid config: missing 'cluster.{field}' in {config_path}")
    if not isinstance(cluster["etcd_nodes"], list) or not cluster["etcd_nodes"]:
        raise ValueError("Invalid config: 'cluster.etcd_nodes' must be a non-empty list")
    if not isinstance(cluster["master_nodes"], list) or not cluster["master_nodes"]:
        raise ValueError("Invalid config: 'cluster.master_nodes' must be a non-empty list")
    # cluster_nodes 为可选字段：存在则必须是 non-empty list；缺失时不报错，
    # 以免破坏读取尚未更新的持久化 config.yaml 的其它调用方（如 autofs_program_map.sh）。
    if "cluster_nodes" in cluster:
        if not isinstance(cluster["cluster_nodes"], list) or not cluster["cluster_nodes"]:
            raise ValueError("Invalid config: 'cluster.cluster_nodes' must be a non-empty list when present")
    return cluster


def load_trace_endpoints(config_path: Path = DEFAULT_CONFIG_PATH) -> list:
    """读取顶层 trace_otlp_endpoints（collector OTLP gRPC 地址列表，主备语义）。

    - 缺省 / 空列表 / 空值 ⇒ 返回 []（tracing 关闭）
    - 必须为非空字符串列表；host:port 格式校验由部署脚本完成
    """
    data = load_full_config(config_path)
    endpoints = data.get("trace_otlp_endpoints", [])
    if endpoints is None:
        endpoints = []
    if not isinstance(endpoints, list) or not all(
        isinstance(e, str) and e.strip() for e in endpoints
    ):
        raise ValueError("Invalid config: 'trace_otlp_endpoints' must be a list of non-empty strings")
    return [e.strip() for e in endpoints]


def get_local_ip() -> str:
    """获取本机 IP（与 agentos.sh 角色推导用的 IP 对齐）。

    优先级：UDP socket 连接获取本机出口 IP > hostname -I > 127.0.0.1

    每一级探测都是"尽力而为"：失败则降级到下一级，最终回 127.0.0.1。
    降级时把原因记到 stderr，便于排查网络环境问题，但不抛异常。
    """
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]
        s.close()
        if ip and not ip.startswith("127."):
            return ip
    except OSError as e:
        _LOGGER.warning("get_local_ip UDP probe failed: %s", e)
    try:
        ips = socket.gethostbyname(socket.gethostname())
        if ips and not ips.startswith("127."):
            return ips.split()[0]
    except OSError as e:
        _LOGGER.warning("get_local_ip hostname lookup failed: %s", e)
    return "127.0.0.1"


def find_ip_index(ip: str, ip_list: list) -> int:
    """返回 ip 在 ip_list 中的索引，未找到返回 -1。"""
    for i, node_ip in enumerate(ip_list):
        if node_ip == ip:
            return i
    return -1


def find_local_match_index(local_ip: str, ip_list: list) -> int:
    """返回本机在 ip_list 中的匹配索引，未找到返回 -1。

    匹配优先级：真实本机 IP > 通配 IP（127.0.0.1 / 0.0.0.0）。
    通配 IP 视为本机匹配，用于单机调试默认 config 场景。
    """
    idx = find_ip_index(local_ip, ip_list)
    if idx >= 0:
        return idx
    for wildcard in WILDCARD_IPS:
        idx = find_ip_index(wildcard, ip_list)
        if idx >= 0:
            return idx
    return -1


def is_etcd_node(local_ip: str, cluster: dict) -> bool:
    return find_local_match_index(local_ip, cluster["etcd_nodes"]) >= 0


def is_function_master(local_ip: str, cluster: dict) -> bool:
    return find_local_match_index(local_ip, cluster["master_nodes"]) >= 0


def etcd_node_name(index: int) -> str:
    """etcd 节点名：etcd0, etcd1, ..."""
    return f"etcd{index}"


def build_initial_cluster(etcd_nodes: list) -> str:
    """生成 etcd --initial-cluster 参数值。

    格式：etcd0=http://IP0:32380,etcd1=http://IP1:32380,...
    """
    parts = []
    for i, ip in enumerate(etcd_nodes):
        parts.append(f"{etcd_node_name(i)}=http://{ip}:{ETCD_PEER_PORT}")
    return ",".join(parts)


def build_etcd_address_list(etcd_nodes: list) -> str:
    """生成 yr 配置所需的 etcd address 列表字符串。

    格式：[{ip="IP0",peer_port=32380,port=32379},...]
    yr 的 -s 覆盖语法要求 Python 字面量格式。
    """
    parts = ",".join(
        f'{{ip="{ip}",peer_port={ETCD_PEER_PORT},port={ETCD_CLIENT_PORT}}}'
        for ip in etcd_nodes
    )
    return f"[{parts}]"


def get_function_master_ip(cluster: dict) -> str:
    """返回 master_nodes[0]，agent 节点的 --master_address 用。"""
    return cluster["master_nodes"][0]


def get_etcd_advertise_ip(local_ip: str, cluster: dict) -> str:
    """返回本机 etcd advertise IP（etcd_nodes 中匹配到的 config IP）。

    通配匹配时返回通配 IP 本身（如 127.0.0.1），不能返回 get_local_ip 的真实 IP，
    否则 advertise 地址与 initial-cluster 不一致导致 etcd bootstrap 失败。
    """
    idx = find_local_match_index(local_ip, cluster["etcd_nodes"])
    if idx < 0:
        raise ValueError(f"local IP {local_ip} not in etcd_nodes")
    return cluster["etcd_nodes"][idx]


def main():
    parser = argparse.ArgumentParser(description="AgentOS config parser and role derivation")
    parser.add_argument(
        "--config",
        type=str,
        default=str(DEFAULT_CONFIG_PATH),
        help=f"Config file path (default: {DEFAULT_CONFIG_PATH})",
    )
    parser.add_argument(
        "--ip",
        type=str,
        default="",
        help="Override local IP detection (for multi-NIC environments)",
    )
    sub = parser.add_subparsers(dest="cmd", required=True)
    sub.add_parser("local-ip", help="Print local IP")
    sub.add_parser("is-etcd-node", help="Exit 0 if local IP is in etcd_nodes")
    sub.add_parser("is-master-node", help="Exit 0 if local IP is in master_nodes")
    sub.add_parser("etcd-name", help="Print etcd node name for this host")
    sub.add_parser("initial-cluster", help="Print etcd --initial-cluster value")
    sub.add_parser("etcd-address-list", help="Print yr etcd address list value")
    sub.add_parser("master-ip", help="Print master_nodes[0]")
    sub.add_parser("etcd-advertise-ip", help="Print this host's etcd advertise IP")
    sub.add_parser("etcd-nodes", help="Print all etcd node IPs, space-separated")
    sub.add_parser("cluster-nodes", help="Print all cluster node IPs (cluster_nodes), space-separated")
    sub.add_parser("ingress-vip", help="Print ingress_virtual_ip")
    sub.add_parser(
        "trace-endpoints",
        help="Print trace_otlp_endpoints, space-separated (empty line when tracing is off)",
    )
    sub.add_parser("all", help="Print all derived values as JSON")

    args = parser.parse_args()
    cluster = load_config(Path(args.config))
    local_ip = args.ip if args.ip else get_local_ip()

    if args.cmd == "local-ip":
        _LOGGER.info(local_ip)
        return
    if args.cmd == "is-etcd-node":
        sys.exit(0 if is_etcd_node(local_ip, cluster) else 1)
    if args.cmd == "is-master-node":
        sys.exit(0 if is_function_master(local_ip, cluster) else 1)
    if args.cmd == "etcd-name":
        idx = find_local_match_index(local_ip, cluster["etcd_nodes"])
        if idx < 0:
            _LOGGER.error("local IP %s not in etcd_nodes", local_ip)
            sys.exit(1)
        _LOGGER.info(etcd_node_name(idx))
        return
    if args.cmd == "initial-cluster":
        _LOGGER.info(build_initial_cluster(cluster["etcd_nodes"]))
        return
    if args.cmd == "etcd-address-list":
        _LOGGER.info(build_etcd_address_list(cluster["etcd_nodes"]))
        return
    if args.cmd == "master-ip":
        _LOGGER.info(get_function_master_ip(cluster))
        return
    if args.cmd == "etcd-advertise-ip":
        _LOGGER.info(get_etcd_advertise_ip(local_ip, cluster))
        return
    if args.cmd == "etcd-nodes":
        _LOGGER.info(" ".join(cluster["etcd_nodes"]))
        return
    if args.cmd == "cluster-nodes":
        nodes = cluster.get("cluster_nodes")
        if not nodes:
            _LOGGER.error("cluster.cluster_nodes is missing or empty in %s", args.config)
            sys.exit(1)
        _LOGGER.info(" ".join(nodes))
        return
    if args.cmd == "ingress-vip":
        _LOGGER.info(cluster["ingress_virtual_ip"])
        return
    if args.cmd == "trace-endpoints":
        _LOGGER.info(" ".join(load_trace_endpoints(Path(args.config))))
        return
    if args.cmd == "all":
        etcd_idx = find_local_match_index(local_ip, cluster["etcd_nodes"])
        result = {
            "local_ip": local_ip,
            "is_etcd_node": is_etcd_node(local_ip, cluster),
            "is_master_node": is_function_master(local_ip, cluster),
            "etcd_name": etcd_node_name(etcd_idx) if etcd_idx >= 0 else None,
            "etcd_index": etcd_idx,
            "initial_cluster": build_initial_cluster(cluster["etcd_nodes"]),
            "etcd_address_list": build_etcd_address_list(cluster["etcd_nodes"]),
            "master_ip": get_function_master_ip(cluster),
            "ingress_virtual_ip": cluster["ingress_virtual_ip"],
            "etcd_nodes": cluster["etcd_nodes"],
            "master_nodes": cluster["master_nodes"],
            "cluster_nodes": cluster.get("cluster_nodes", []),
        }
        _LOGGER.info(json.dumps(result, indent=2))
        return


if __name__ == "__main__":
    main()
