#!/usr/bin/env python3
# Copyright (c) Huawei Technologies Co., Ltd. 2026. All rights reserved.
"""从 npmmirror 下载两个 revision 的 playwright chromium 到标准缓存路径。

node 侧(1200) 与 python 侧(1234) 各用一套, 目录按 revision 隔离互不冲突。
下载目标: /opt/ms-playwright/{chromium-<rev>,chromium_headless_shell-<rev>}
"""
import logging
import os
import ssl
import zipfile
import urllib.request

logger = logging.getLogger(__name__)

DEST = "/opt/ms-playwright"

# revision -> 用途说明
REVISIONS = {
    "1200": "node-side playwright 1.57.0 (html2pptx engine)",
    "1234": "python-side playwright (QC render)",
}


def _opener():
    ctx = ssl.create_default_context()
    return urllib.request.build_opener(
        urllib.request.HTTPSHandler(context=ctx),
    )


def main():
    opener = _opener()
    os.makedirs(DEST, exist_ok=True)
    for revision, purpose in REVISIONS.items():
        logger.info("downloading revision %s (%s)", revision, purpose)
        base = f"https://cdn.npmmirror.com/binaries/playwright/builds/chromium/{revision}"
        # folder -> zip (均在 builds/chromium/{revision}/ 下)
        browsers = {
            f"chromium-{revision}": "chromium-linux-arm64.zip",
            f"chromium_headless_shell-{revision}": "chromium-headless-shell-linux-arm64.zip",
        }
        for folder, filename in browsers.items():
            url = f"{base}/{filename}"
            logger.info("downloading %s", url)
            with opener.open(url, timeout=600) as resp:
                data = resp.read()
            target = os.path.join(DEST, folder)
            os.makedirs(target, exist_ok=True)
            zf = os.path.join(os.path.dirname(DEST), filename)
            with open(zf, "wb") as f:
                f.write(data)
            with zipfile.ZipFile(zf) as z:
                z.extractall(target)
            os.remove(zf)
            binary = os.path.join(
                target, "chrome-linux",
                "chrome" if "headless" not in folder else "headless_shell",
            )
            if os.path.exists(binary):
                os.chmod(binary, os.stat(binary).st_mode | 0o111)
                logger.info("installed binary %s", binary)
            else:
                logger.warning("missing binary in %s", target)
    logger.info("all playwright browsers installed")


if __name__ == "__main__":
    main()
