#!/usr/bin/env python3
# Copyright (c) Huawei Technologies Co., Ltd. 2026. All rights reserved.
"""Apply node-local ADX tool connectivity before starting AgentServer."""
import os
import sys



if __name__ == "__main__":
    if len(sys.argv) < 3 or sys.argv[1] != "--node-ingress":
        raise SystemExit("node ingress argument is required")
    environment = dict(os.environ, JIUWENSWARM_ADX_NODE_INGRESS_URL=sys.argv[2])
    args = [sys.executable, "-m", "jiuwenswarm.server.app_agentserver", *sys.argv[3:]]
    os.execve(sys.executable, args, environment)
