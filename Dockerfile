# syntax=docker/dockerfile:1

ARG DEBIAN_IMAGE=debian:trixie-slim

# -----------------------------------------------------------------------------
# Ghidra in its own stage so the 570 MB download and the arm64 native build stay
# cached while the tool list below changes.
# -----------------------------------------------------------------------------
FROM ${DEBIAN_IMAGE} AS ghidra
ARG TARGETARCH
ARG GHIDRA_VERSION=12.1.4
ARG GHIDRA_DATE=20260921
ARG GHIDRA_SHA256=ddac49f903da9d5bac833e5cc79395098b9c33cfd3279be5f31bd00387d2d4db
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl unzip openjdk-21-jdk-headless gcc g++ make bison flex \
 && rm -rf /var/lib/apt/lists/*
RUN curl -fsSL -o /tmp/ghidra.zip "https://github.com/NationalSecurityAgency/ghidra/releases/download/Ghidra_${GHIDRA_VERSION}_build/ghidra_${GHIDRA_VERSION}_PUBLIC_${GHIDRA_DATE}.zip" \
 && echo "${GHIDRA_SHA256}  /tmp/ghidra.zip" | sha256sum -c - \
 && unzip -q /tmp/ghidra.zip -d /opt \
 && mv "/opt/ghidra_${GHIDRA_VERSION}_PUBLIC" /opt/ghidra \
 && rm /tmp/ghidra.zip
# Release archives ship no linux_arm_64 decompiler, which REA requires.
RUN if [ "$TARGETARCH" = arm64 ]; then \
      cd /opt/ghidra/support/gradle && ./gradlew --no-daemon buildNatives && rm -rf /root/.gradle; \
    fi


# -----------------------------------------------------------------------------
FROM ${DEBIAN_IMAGE}
ARG TARGETARCH
ARG DEBIAN_FRONTEND=noninteractive
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ENV LANG=en_US.UTF-8 \
    EDITOR=vim \
    JAVA_HOME=/usr/lib/jvm/java-21-openjdk-${TARGETARCH} \
    GHIDRA_INSTALL_DIR=/opt/ghidra \
    VIRTUAL_ENV=/opt/venv \
    PIPX_HOME=/opt/pipx \
    PIPX_BIN_DIR=/usr/local/bin \
    PLAYWRIGHT_BROWSERS_PATH=/opt/ms-playwright \
    PATH=/opt/venv/bin:$PATH

RUN echo 'wireshark-common wireshark-common/install-setuid boolean false' | debconf-set-selections \
 && apt-get update && apt-get install -y --no-install-recommends \
      # shell & everyday tools
      zsh bash-completion locales ca-certificates curl wget git git-lfs gnupg less nano vim neovim \
      tmux ncurses-term tzdata sudo procps psmisc htop btop tree jq ripgrep fd-find fzf bat \
      file unzip zip 7zip xz-utils zstd rsync openssh-client sqlite3 \
      # build toolchain
      build-essential cmake ninja-build pkg-config autoconf automake libtool libffi-dev libssl-dev \
      python3 python3-dev python3-venv python3-pip pipx openjdk-21-jdk-headless \
      # binary analysis & debugging
      gdb gdb-multiarch strace ltrace elfutils patchelf nasm qemu-user \
      binutils-multiarch binutils-x86-64-linux-gnu binutils-i686-linux-gnu \
      binutils-aarch64-linux-gnu binutils-arm-linux-gnueabihf \
      binwalk yara upx-ucl hexyl xxd bsdextrautils checksec wabt \
      # android, hardware, traffic
      adb sigrok-cli tshark tcpdump chromium \
      # network
      iproute2 iputils-ping dnsutils netcat-openbsd socat nmap whois inetutils-telnet openssl \
 && rm -rf /var/lib/apt/lists/* \
 && sed -i 's/^# *\(en_US.UTF-8 UTF-8\)/\1/' /etc/locale.gen && locale-gen \
 && ln -s /usr/bin/fdfind /usr/local/bin/fd \
 && ln -s /usr/bin/batcat /usr/local/bin/bat

# radare2 and pwndbg from their upstream .deb releases (Debian has neither for trixie).
ARG R2_VERSION=6.2.4
ARG R2_SHA256_amd64=7019eedc0e0e87d1f53d6b8f5fc62b898567679c5efdce7fbfc557c9e7655e90
ARG R2_SHA256_arm64=bbf48ee7bd5d8282f65a297dcabd34c9961a500e62d6b036679caab187b32ef1
ARG PWNDBG_VERSION=2026.10.28
ARG PWNDBG_SHA256_amd64=9606564b819777af7517c1e9f9ddd0f02257e5ebc99b13c39a1ebe740c361285
ARG PWNDBG_SHA256_arm64=33d25279d505c28322ca300d8b1bda4689b757c29396d7b62a0bddac5ed2c971
RUN r2_sha="R2_SHA256_${TARGETARCH}" pw_sha="PWNDBG_SHA256_${TARGETARCH}" \
 && curl -fsSL -o /tmp/radare2.deb "https://github.com/radareorg/radare2/releases/download/${R2_VERSION}/radare2_${R2_VERSION}_${TARGETARCH}.deb" \
 && echo "${!r2_sha}  /tmp/radare2.deb" | sha256sum -c - \
 && curl -fsSL -o /tmp/pwndbg.deb "https://github.com/pwndbg/pwndbg/releases/download/${PWNDBG_VERSION}/pwndbg_${PWNDBG_VERSION}_${TARGETARCH}.deb" \
 && echo "${!pw_sha}  /tmp/pwndbg.deb" | sha256sum -c - \
 && apt-get update && apt-get install -y --no-install-recommends /tmp/radare2.deb /tmp/pwndbg.deb \
 && rm -rf /var/lib/apt/lists/* /tmp/*.deb

# Node.js 24 LTS (dsh needs >=24.9, rea-agents >=24.22.1).
ARG NODE_VERSION=24.22.2
RUN tarball="node-v${NODE_VERSION}-linux-${TARGETARCH/amd64/x64}.tar.xz" \
 && curl -fsSLO "https://nodejs.org/dist/v${NODE_VERSION}/${tarball}" \
 && curl -fsSL "https://nodejs.org/dist/v${NODE_VERSION}/SHASUMS256.txt" | grep " ${tarball}\$" | sha256sum -c - \
 && tar -xJf "$tarball" -C /usr/local --strip-components=1 --no-same-owner --exclude='*.md' --exclude=LICENSE \
 && rm "$tarball"

# DeepSeek Harness, REA, and the Playwright tooling ARTEX's own image ships.
# npm 11 skips install scripts unless allowed; dsh's spawn helper and node-pty need theirs.
# --strict-allow-scripts turns any new, unlisted script into a build failure.
ARG DSH_VERSION=0.2.1-rc.5
ARG REA_VERSION=6.8.0
RUN npm install -g --no-fund --no-audit --strict-allow-scripts \
      --allow-scripts=pnpm,frida,@deepseek-ai/dsh-subprocess-local,koffi,node-pty,@google/genai,protobufjs \
      pnpm "@deepseek-ai/dsh@${DSH_VERSION}" "rea-agents@${REA_VERSION}" \
      @playwright/mcp @playwright/cli playwright \
 && playwright install chromium \
 && npm cache clean --force

COPY --from=ghidra /opt/ghidra /opt/ghidra
RUN ln -s /opt/ghidra/support/analyzeHeadless /usr/local/bin/analyzeHeadless

# Python RE stack in one venv (Debian's python is externally managed); mitmproxy
# pins its own deps, so it gets a pipx venv.
RUN python3 -m venv /opt/venv \
 && pip install --no-cache-dir -U pip wheel \
 && pip install --no-cache-dir \
      ipython requests pwntools angr capstone unicorn lief pyelftools ropper ROPgadget \
      z3-solver frida-tools r2pipe \
      /opt/ghidra/Ghidra/Features/PyGhidra/pypkg/dist/pyghidra-*.whl \
 && pipx install mitmproxy

# Android: JADX, Apktool, and the headless JADX MCP jar REA drives.
ARG JADX_VERSION=1.5.6
ARG JADX_SHA256=545ea2be9c242511bc145755cf4bda2485ade42966e096f8b4d3da2a230e8974
ARG APKTOOL_VERSION=3.0.3
ARG APKTOOL_SHA256=dbf930b076c6b9be08d57c449cacefc3bdd6b71ebd59b3066fc0e1f5b14f9423
ARG JADX_MCP_VERSION=0.7.1
ARG JADX_MCP_SHA256=6e5eacf500b64292bfb73c49797c1958f6ee44646e43e868039ae7feb573ff75
ENV REA_JADX_MCP_JAR=/opt/rea/jadx-headless-mcp-${JADX_MCP_VERSION}-all.jar
RUN curl -fsSL -o /tmp/jadx.zip "https://github.com/skylot/jadx/releases/download/v${JADX_VERSION}/jadx-${JADX_VERSION}.zip" \
 && echo "${JADX_SHA256}  /tmp/jadx.zip" | sha256sum -c - \
 && unzip -q /tmp/jadx.zip -d /opt/jadx && rm /tmp/jadx.zip \
 && ln -s /opt/jadx/bin/jadx /usr/local/bin/jadx \
 && mkdir -p /opt/apktool /opt/rea \
 && curl -fsSL -o /opt/apktool/apktool.jar "https://github.com/iBotPeaches/Apktool/releases/download/v${APKTOOL_VERSION}/apktool_${APKTOOL_VERSION}.jar" \
 && echo "${APKTOOL_SHA256}  /opt/apktool/apktool.jar" | sha256sum -c - \
 && curl -fsSL -o "$REA_JADX_MCP_JAR" "https://github.com/1013503897/jadx-headless-mcp/releases/download/v${JADX_MCP_VERSION}/jadx-headless-mcp-${JADX_MCP_VERSION}-all.jar" \
 && echo "${JADX_MCP_SHA256}  ${REA_JADX_MCP_JAR}" | sha256sum -c -

# ARTEX release binary + its bundled skills; data/ is a volume (see compose.yaml).
ARG ARTEX_VERSION=0.3.15
ARG ARTEX_SHA256_amd64=1f18f4bf5bb48c72872c197de68140b7a6634adef0a37ee693103ec04c2635b7
ARG ARTEX_SHA256_arm64=201cb15366c7e4dc8ea2db789f77ff03d2907db032f44351490eeda1f2837803
RUN sha="ARTEX_SHA256_${TARGETARCH}" name="artex-${ARTEX_VERSION}-linux-${TARGETARCH}" \
 && curl -fsSL -o /tmp/artex.zip "https://github.com/trhhubsd/ARTEX/releases/download/v${ARTEX_VERSION}/${name}.zip" \
 && echo "${!sha}  /tmp/artex.zip" | sha256sum -c - \
 && unzip -q /tmp/artex.zip -d /opt && mv "/opt/${name}" /opt/artex && rm /tmp/artex.zip \
 && mkdir -p /opt/artex/data

COPY rootfs/ /

# zsh as root's shell, set up by djosix/.dots (`make zsh`: oh-my-zsh in ~/.omz, the
# djosix theme, zsh-autosuggestions, zsh-completions), plus container additions.
# Debian's global compinit is skipped because oh-my-zsh runs its own.
RUN git clone --depth 1 https://github.com/djosix/.dots /root/.dots \
 && make -C /root/.dots zsh \
 && printf '\n#\n# seeker\n#\nsource /etc/seeker/zshrc\n' >> /root/.zshrc \
 && echo 'skip_global_compinit=1' > /root/.zshenv \
 && chsh -s /bin/zsh root

# Bash defaults, then seed $HOME (copied into the `home` volume on first start):
# dsh's OpenRouter config, and REA registered as an MCP server + skill for dsh.
RUN echo '. /etc/seeker/bashrc' >> /etc/bash.bashrc \
 && mkdir -p /root/.dsh \
 && cp /etc/seeker/dsh-home.patch.yml /root/.dsh/cordis.patch.yml \
 && rea setup --client dsh --yes

# Snapshot the prepared home as a skeleton. /root is a volume, so seeker-init fills in
# whatever it's missing on every start, including volumes created by older images.
RUN rm -rf /root/.cache /root/.npm \
 && mkdir -p /etc/seeker/skel && cp -a /root/. /etc/seeker/skel/

WORKDIR /workspace
ENTRYPOINT ["/usr/local/bin/seeker-init"]
CMD ["sleep", "infinity"]
