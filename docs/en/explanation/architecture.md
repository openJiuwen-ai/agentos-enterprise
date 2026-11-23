# Deployment Architecture Explained

This page explains the composition of AgentOS and the design decisions behind its deployment architecture: why submodules are used for aggregation, why the deploy script uses module hooks, and why the lifecycle has three layers.

## Where AgentOS sits in the openJiuwen ecosystem

AgentOS is an **integration and delivery repository** — it implements no functional components itself. Instead it pins, builds, and deploys four openJiuwen components together:

| Component | Source | Role |
|-----------|--------|------|
| agent-runtime | Git submodule | distributed agent runtime (faas / sdk / runtime / datasystem / functionsystem) |
| jiuwenswarm | submodule [jiuwenswarm/](../../../jiuwenswarm/) | agent gateway + web frontend + TUI client |
| Conch | submodule [Conch/](../../../Conch/) | optional sandbox engine (source retained; runtime artifacts excluded from the server package; not deployed by default) |
| agent-protocol | submodule [agent-protocol/](../../../agent-protocol/) | A2X protocol and registry (a2x-registry) |

Submodules rather than bare package references keep "source traceability" and "reproducible delivery" together: the main repository records each component's exact commit, while the build scripts pull the corresponding prebuilt artifacts from OBS.

## Build and distribution model

The build does not compile source code; it **aggregates** each component's prebuilt OBS artifacts (wheels / rpms) together with the `deploy/` directory into two tarballs:

```
OBS (per-component CI archives last_successful_build)
        │  build/build.sh (or build-v2.sh)
        ▼
AgentOS-Client.tgz          # all-platform TUI wheels, distributed to end users
AgentOS-Server-<arch>.tgz   # server wheels/rpms + deploy/ scripts, distributed to deployers
```

The v2 build line (b050) further decouples "solution packaging" from "component builds" via the `last_successful_build` directory: component CIs archive builds on schedule, and solution packaging just pulls the latest successful archive — eliminating hardcoded versions and timestamps. The full design is in [build/README-v2.zh.md](../../../build/README-v2.zh.md).

## Deployment architecture: module registration + hooks + scheduling engine

`deploy/agentos.sh` only schedules; it contains no component-specific logic:

1. **Module registration**: the `MODULES` array at the top declares all modules and their deployment order.
2. **Hook contract**: each module implements `<module>_up / _down / _install / _uninstall / _status` in `deploy/<module>/module.sh`.
3. **Scheduling engine**: `run_hooks` iterates modules and invokes hooks — `up` / `install` in declaration order, `down` / `uninstall` in automatic reverse order.

Why it is designed this way:

- **Pluggable**: adding a component is zero-intrusive (a directory + an array entry); components remain unaware of each other.
- **Reverse teardown**: dependencies naturally flow "later starters depend on earlier ones"; reverse `down` stops dependents before their dependencies.
- **Directory as contract**: `module.sh` is the module's only external interface; the engine does not care about internals.

## Why the lifecycle has three layers

```
install  ↔  uninstall     install/uninstall wheels (outermost)
  init   ↔  deinit        bootstrap / tear down etcd (middle, one-time)
    up   ↔  down          start/stop application services (innermost, repeatable)
```

The layers map to three change frequencies: wheels barely change (install once); etcd is a one-time cluster bootstrap and persistent infrastructure (init once, data survives up/down); application services restart repeatedly across releases (up / down at will). Hence `down` leaves etcd alone, `init` keeps existing data for smooth upgrades, and a full rebuild requires `etcd.sh clean`.

## Ingress VIP and role determination

In a multi-node deployment, gateway / registry / web should start on exactly one entry point. AgentOS adds no extra election component; it reuses the network-layer VIP:

- `config.yaml` declares `ingress_virtual_ip`; a node whose NIC holds that VIP is the ingress master.
- agent-gateway gates on a systemd `ExecStartPre` (`check-ingress-master.sh`): a node not holding the VIP fails its start outright (fail-closed) rather than silently skipping — making "who is serving" observable at the network layer.
- Listen address resolution priority: `ingress_virtual_ip` > `--ip` > `hostname -I` detection > `127.0.0.1`.

## Global state persistence

`install` persists `deploy/` to `~/.agentos/`: subsequent `init` / `up` read the persisted copy (`config.py` derives roles from it), so the deployment stays controllable and reversible even after the extracted directory is deleted.
