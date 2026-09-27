FROM ubuntu:24.04

LABEL io.docker-codex-suite.codex-cli="true"

ARG USERNAME=codex
ARG USER_UID=1001
ARG USER_GID=1001
ARG SSH_PUBLIC_KEY=""

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        bash \
        bubblewrap \
        ca-certificates \
        curl \
        git \
        jq \
        less \
        nano \
        nodejs \
        npm \
        openssh-server \
        python3 \
        python3-pip \
        ripgrep \
        sudo \
    && rm -rf /var/lib/apt/lists/*

RUN groupadd --gid "${USER_GID}" "${USERNAME}" \
    && useradd --uid "${USER_UID}" --gid "${USER_GID}" --create-home --shell /usr/bin/bash "${USERNAME}" \
    && echo "${USERNAME} ALL=(ALL) NOPASSWD:ALL" >/etc/sudoers.d/"${USERNAME}" \
    && chmod 0440 /etc/sudoers.d/"${USERNAME}"

RUN mkdir -p /run/sshd /workspace /home/"${USERNAME}"/.ssh /home/"${USERNAME}"/.codex \
    && chown -R "${USERNAME}:${USERNAME}" /workspace /home/"${USERNAME}"/.ssh /home/"${USERNAME}"/.codex \
    && chmod 700 /home/"${USERNAME}"/.ssh

RUN printf '%s\n' 'PermitUserEnvironment yes' >/etc/ssh/sshd_config.d/90-codex-user-env.conf

RUN printf '%s\n' "${SSH_PUBLIC_KEY}" >/home/"${USERNAME}"/.ssh/authorized_keys \
    && chown "${USERNAME}:${USERNAME}" /home/"${USERNAME}"/.ssh/authorized_keys \
    && chmod 600 /home/"${USERNAME}"/.ssh/authorized_keys

RUN mkdir -p /opt/codex \
    && curl -fsSL https://chatgpt.com/codex/install.sh | CODEX_HOME=/opt/codex CODEX_NON_INTERACTIVE=1 CODEX_INSTALL_DIR=/usr/local/bin sh \
    && chmod -R a+rX /opt/codex

RUN printf '%s\n' \
    'export PATH="$HOME/.local/bin:/usr/local/bin:$PATH"' \
    'export CODEX_HOME="$HOME/.codex"' \
    >/etc/profile.d/codex.sh

ENV CODEX_HOME=/home/codex/.codex
ENV PATH=/home/codex/.local/bin:/usr/local/bin:/usr/local/sbin:/usr/sbin:/usr/bin:/sbin:/bin

COPY docker-entrypoint.sh /usr/local/bin/docker-codex-entrypoint
RUN chmod 755 /usr/local/bin/docker-codex-entrypoint

USER "${USERNAME}"
WORKDIR /workspace
RUN /usr/local/bin/codex --version >/dev/null

USER root
EXPOSE 22
ENTRYPOINT ["/usr/local/bin/docker-codex-entrypoint"]
CMD ["/usr/sbin/sshd", "-D", "-e"]
