# Copyright (c) Huawei Technologies Co., Ltd. 2026. All rights reserved.
# ============================================================
# ppt-pipeline-swarm runtime —— 预装全部运行依赖
# 基础镜像: yr-runtime-sandbox:latest (openEuler, aarch64, py3.11)
# 交付: npm引擎依赖->/opt/html2pptx/node_modules
#       python包->/usr/local/lib/python3.11/site-packages
#       playwright->/opt/ms-playwright (rev 1200/1234)
# ============================================================
FROM swr.cn-southwest-2.myhuaweicloud.com/yuanrong-dev/yr-runtime-sandbox:latest

# 构建期环境（无代理，直连内网镜像源；免校验自签名证书）
ENV GIT_SSL_NO_VERIFY=true \
    PLAYWRIGHT_BROWSERS_PATH=/opt/ms-playwright

# 1) 系统依赖: nodejs/npm + chromium 运行库 (openEuler 仓库自签名, 需 sslverify=0)
RUN printf '[main]\nsslverify=0\n' > /etc/dnf/dnf.conf && \
    dnf clean all && \
    dnf makecache --refresh && \
    dnf -y install nodejs nss nspr atk at-spi2-atk cups-libs libdrm git iputils\
        libxkbcommon libXcomposite libXdamage libXfixes libXrandr \
        mesa-libgbm libXext libX11 pango cairo alsa-lib fontconfig \
        freetype libXrender libXt libXScrnSaver findutils graphviz && \
    dnf clean all

# 1.5) 中文字体 (Noto Sans CJK SC) —— 解决 WPS/PPT 中文渲染缺字
RUN dnf -y makecache && \
    ( dnf -y install \
        google-noto-sans-cjk-sc-fonts \
    || ( dnf clean all && rm -rf /var/cache/dnf/* && \
         dnf -y install \
           google-noto-sans-cjk-sc-fonts ) ) && \
    fc-cache -f

# 验证中文字体已生效（构建期打印，便于排障）
RUN fc-list 2>/dev/null | grep -ciE 'Noto Sans CJK SC|WenQuanYi|UKai' \
    || echo 'WARN: CJK fonts not found'

# 2) npm 引擎依赖: npm ci 按 lock 精确安装 (走华为云 npm 镜像)
WORKDIR /opt/html2pptx
ENV NODE_PATH=/opt/html2pptx/node_modules
COPY package.json ./
COPY package-lock.json ./
RUN npm config set strict-ssl false && \
    npm ci --registry=https://mirrors.huaweicloud.com/repository/npm/ && \
    npm install katex@0.18.4 docx@9.7.1 --no-save --registry=https://mirrors.huaweicloud.com/repository/npm/ && \
    npm cache clean --force

# 3) Playwright Chromium (rev 1234): 用 python 脚本直连 npmmirror 下载到 /opt/ms-playwright
COPY download_playwright_browsers.py /usr/local/bin/download_playwright_browsers.py
RUN python3 /usr/local/bin/download_playwright_browsers.py && \
    rm -f /usr/local/bin/download_playwright_browsers.py

# 4) Python 依赖 (走华为云 pypi 镜像源, 加速下载)
RUN pip3 config set global.index-url https://mirrors.huaweicloud.com/repository/pypi/simple/ && \
    pip3 install \
        python-pptx requests pypdf pdfplumber pymupdf firecrawl-anydoc\
        playwright==1.62.0 markitdown markdown-it-py Pillow fake-useragent \
        imapclient>=3.1.0 PySocks>=1.7.1 markdown>=3.4 \
        PyPDF2>=3.0.1 python-docx>=1.2.0 openpyxl>=3.1.0 \
        reportlab==5.0.0 matplotlib==3.11.1 pandas==3.0.5 \
        pdfkit==1.0.0 graphviz==0.21 latex2mathml==3.81.0 \
        scrapling[rag]==0.4.15 patchright==1.62.3 && \
    pip3 cache purge && \
    pip3 config unset global.index-url


# 5) Conch 兼容：Conch 起沙箱时不传递镜像配置里的 ENV（只带宿主进程环境），
#    而且沙箱里 /tmp 是空 tmpfs（镜像放在 /tmp 的内容会被盖掉）。
#    因此浏览器在 3) 里直接装到 /opt/ms-playwright（不经 /tmp、无需搬移），
#    并把关键查找路径用文件系统软链固化，不依赖 ENV。
# 5.1 不依赖 NODE_PATH：node 从任意目录 require 都会逐级向上找到 /node_modules，
#     agent 在别的目录调用该引擎也能命中
RUN ln -sfn /opt/html2pptx/node_modules /node_modules

# 5.2 不依赖 PLAYWRIGHT_BROWSERS_PATH：软链到 Playwright 默认查找路径 ~/.cache/ms-playwright
#     Conch 里 HOME=/，所以 /.cache 是关键；另两条兼容其他 HOME
RUN set -eux; \
    mkdir -p /.cache /root/.cache /etc/skel/.cache; \
    ln -sfn /opt/ms-playwright /.cache/ms-playwright; \
    ln -sfn /opt/ms-playwright /root/.cache/ms-playwright; \
    ln -sfn /opt/ms-playwright /etc/skel/.cache/ms-playwright; \
    ls -ld /.cache/ms-playwright /root/.cache/ms-playwright /etc/skel/.cache/ms-playwright /node_modules
WORKDIR /
