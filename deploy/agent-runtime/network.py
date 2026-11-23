"""AgentOS-owned sandboxd network settings, policies and host containment."""
from __future__ import annotations

import ipaddress
import json
import re
import os
from pathlib import Path
import shutil
import subprocess
import socket
from urllib.parse import urlsplit


def _supervisor_default_pools():
    from jiuwenbox.supervisor.network import _resolve_uplink_pools

    return _resolve_uplink_pools('')


def supervisor_network(configured, previous, sandboxd_cidr):
    """Select the node's pool and retain Relay access to existing Supervisor links."""
    routes = json.loads(subprocess.check_output(['ip', '-j', '-4', 'route', 'show', 'table', 'all'], text=True))
    conflicts = [ipaddress.IPv4Network(sandboxd_cidr)]
    active = set()
    for route in routes:
        destination = route.get('dst', 'default')
        if destination == 'default' or route.get('type') in ('local', 'broadcast', 'unreachable', 'blackhole', 'prohibit', 'throw'):
            continue
        network = ipaddress.IPv4Network(destination, strict=False)
        if (network.prefixlen == 30 and route.get('protocol') == 'kernel' and route.get('scope') == 'link'
                and re.fullmatch(r'jwbH[0-9a-f]{8}', route.get('dev', ''))):
            active.add(network)
        else:
            conflicts.append(network)

    requested = configured or previous
    for cidr in (requested,) if requested else _supervisor_default_pools():
        pool = ipaddress.IPv4Network(cidr)
        # is_link_local checks containment, so split broader pools at the IPv4 link-local prefix.
        subnets = (pool,) if pool.prefixlen >= 16 else pool.subnets(new_prefix=16)
        if pool.prefixlen > 24 or any(subnet.is_link_local for subnet in subnets):
            raise ValueError(f'Invalid Supervisor address pool {pool}; use an IPv4 subnet of /24 or larger')
        conflict = next((route for route in conflicts if pool.overlaps(route)), None)
        if conflict is None:
            legacy = [str(link) for link in sorted(active) if not link.subnet_of(pool)]
            return str(pool), legacy
        if requested:
            raise ValueError(f'Supervisor address pool {pool} overlaps {conflict}; configure a different pool')
    raise ValueError('No available Supervisor address pool; check conflicting host routes')


def node_context(sandboxd, *, ingress_port=8080, runtime_control_port=19103, node_id=None):
    interface = ipaddress.IPv4Interface(sandboxd['plugin']['network']['ip_range'])
    if interface.ip.is_loopback or interface.ip.is_unspecified or interface.ip in (interface.network.network_address, interface.network.broadcast_address):
        raise ValueError('sandboxd must configure an explicit usable bridge IPv4 address')
    for port in (ingress_port, runtime_control_port):
        if isinstance(port, bool) or not isinstance(port, int) or not 1 <= port <= 65535:
            raise ValueError('bridge service ports must be in 1..65535')
    if node_id is not None and (not isinstance(node_id, str) or not node_id.strip()):
        raise ValueError('node_id must be a nonempty string')
    return {'node_id': node_id or socket.gethostname(), 'bridge_ip': str(interface.ip), 'sandbox_cidr': str(interface.network),
            'bridge_name': 'sandbox0', 'ingress_port': ingress_port, 'runtime_control_port': runtime_control_port,
            'ingress_url': f'http://{interface.ip}:{ingress_port}',
            'runtime_control_url': f'http://{interface.ip}:{runtime_control_port}'}


def enable_network_acl(text):
    match = re.search(r'(?ms)^\[plugin\.network\][ \t]*\n(.*?)(?=^\[|\Z)', text)
    if match is None:
        raise ValueError('sandboxd package must expose [plugin.network]')
    block = match.group(1)
    for key, value in (('nat_backend', '"iptables"'), ('enable_network_acl', 'true'), ('enable_local_dnat', 'false')):
        pattern = rf'(?m)^{key}[ \t]*=.*$'
        line = f'{key} = {value}'
        if re.search(pattern, block):
            block = re.sub(pattern, line, block)
        else:
            block += line + '\n'
    return text[:match.start(1)] + block + text[match.end(1):]


def _empty_policy():
    return {'traffic': {'ingress_default_action': 'deny', 'egress_default_action': 'deny',
                        'rules': [], 'mode': 'stateful'}, 'dns': {'default_action': 'deny', 'rules': []}}


def _origin(value):
    url = urlsplit(value)
    if url.scheme not in ('http', 'https') or not url.hostname or url.username or url.password:
        raise ValueError('egress targets must be HTTP(S) URLs without credentials')
    return url.hostname, url.port or (443 if url.scheme == 'https' else 80)


def _grant(value, *, allow_private=False):
    host, port = _origin(value)
    rule = {'action': 'allow', 'direction': 'egress', 'protocol': 'tcp',
            'port_range': {'first': port, 'last': port}, 'priority': 100}
    try:
        ip = ipaddress.IPv4Address(host)
    except ipaddress.AddressValueError:
        if ':' in host:
            raise ValueError('AgentOS egress policy supports IPv4 and DNS names') from None
        rule['domain'] = host
        if allow_private:
            rule['priority'] = 300
    else:
        if not ip.is_global and not allow_private:
            raise ValueError('internal service origins require an explicit allowed origin')
        rule['cidr'] = f'{ip}/32'
        if not ip.is_global:
            rule['priority'] = 300
    return rule


def tool_policy(targets):
    policy = _empty_policy()
    for target in targets:
        rule = _grant(target, allow_private=True)
        policy['traffic']['rules'].append(rule)
        if rule.get('domain'):
            policy['dns']['rules'].append({'action': 'allow', 'pattern': rule['domain']})
    return policy


def agent_policy(context, models, allowed_internal_origins):
    policy = tool_policy([context['ingress_url']])
    internal = {_origin(value) for value in allowed_internal_origins}
    for value in models:
        rule = _grant(value, allow_private=_origin(value) in internal)
        policy['traffic']['rules'].append(rule)
        if rule.get('domain'):
            policy['dns']['rules'].append({'action': 'allow', 'pattern': rule['domain']})
    return policy


def preflight():
    if os.geteuid() != 0:
        raise PermissionError('sandboxd ACL deployment requires root')
    for name in ('ip', 'iptables', 'ip6tables', 'ipset'):
        if shutil.which(name) is None:
            raise RuntimeError(f'{name} is required for sandboxd ACL; run AgentOS system dependency installation first')
    for command in (['ipset', 'list', '-n'], ['iptables', '-t', 'filter', '-S'], ['ip6tables', '-t', 'filter', '-S']):
        result = subprocess.run(command, capture_output=True, text=True, check=False)
        if result.returncode:
            raise RuntimeError(f'{command[0]} prerequisite check failed: {result.stderr.strip()}')


def remove_host_firewall():
    """Remove only tables created by the earlier AgentOS host guard."""
    nft = shutil.which('nft')
    if nft is None:
        return
    if os.geteuid() != 0:
        raise PermissionError('AgentOS host rule cleanup requires root')
    result = subprocess.run([nft, '-j', 'list', 'tables'],
                            capture_output=True, text=True, check=False)
    if result.returncode:
        # A kernel without nf_tables cannot contain any of the old tables.
        if any(message in result.stderr.lower() for message in
               ('operation not supported', 'protocol not supported')):
            return
        raise RuntimeError('Cannot inspect old AgentOS host rules: ' + result.stderr.strip())
    tables = {(entry['table']['family'], entry['table']['name'])
              for entry in json.loads(result.stdout).get('nftables', []) if 'table' in entry}
    for family in ('inet', 'bridge'):
        if (family, 'agentos_sandbox') in tables:
            subprocess.run([nft, 'delete', 'table', family, 'agentos_sandbox'],
                           capture_output=True, text=True, check=True)


if __name__ == '__main__':
    import argparse
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('remove',))
    parser.parse_args()
    remove_host_firewall()
