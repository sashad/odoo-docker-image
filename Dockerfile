# syntax=docker/dockerfile:1
# Сборочный этап.
# В качестве базового образа используем Ubuntu, так как в основном разработка у нас ведётся на этой ОС.
# При этом ничто не мешает использовать официальные образы Python от Docker.
FROM ubuntu:noble AS build

# Generate locale C.UTF-8 for postgres and general locale data
ENV LANG=en_US.UTF-8

ARG python_version=3.10

# Переопределяем стандартную команду запуска шелла для выполнения команд в форме "shell".
# https://docs.docker.com/reference/dockerfile/#shell-and-exec-form
# Опция `-e` включает мгновенный выход после ошибки для любой непроверенной команды.
#   Команда считается проверенной, если она используется в условии оператора ветвления (например, `if`)
#   или является левым операндом `&&` либо `||` оператора.
# Опция `-x` включает печать каждой команды в поток stderr перед её выполнением. Она очень полезна при отладке.
# https://manpages.ubuntu.com/manpages/noble/en/man1/sh.1.html
SHELL ["/bin/sh", "-exc"]

# Устанавливаем системные пакеты для сборки проекта.
# Используем команду `apt-get`, а не `apt`, так как у последней нестабильный интерфейс.
# `libpq-dev` — это зависимость `psycopg2` — пакета Python для работы с БД, который будет компилироваться при установке.
RUN <<EOF
    apt-get update --quiet
    apt-get install --quiet --no-install-recommends --assume-yes \
        supervisor \
        build-essential wget git python3-pip python3-dev python3-venv \
        python3-wheel libfreetype6-dev libxml2-dev libzip-dev libsasl2-dev \
        python3-setuptools node-less libjpeg-dev zlib1g-dev libpq-dev \
        libxslt1-dev libldap2-dev libtiff5-dev libopenjp2-7-dev libcap-dev \
        ca-certificates fontconfig libfreetype6 libjpeg-turbo8 libpng16-16 libstdc++6 libx11-6 libxcb1 libxext6 libxrender1 xfonts-75dpi xfonts-base zlib1g \
        locales \
        libldap-dev \
        libsasl2-dev \
        node-less \
        npm \
        nginx \
        mc \
        sudo \
        net-tools \
        iproute2 \
        iputils-ping \
        python-dev-is-python3
    rm -rf /var/lib/apt/lists/*
EOF

RUN rm -f /etc/nginx/sites-enabled/*
COPY etc /etc
COPY debs /tmp/debs
RUN locale-gen
RUN useradd -ms /bin/bash odoo
COPY --chown=odoo:odoo ./entrypoint.sh /

# Копируем утилиту `uv` из официального Docker-образа.
# https://github.com/astral-sh/uv/pkgs/container/uv
# опция `--link` позволяет переиспользовать слой, даже если предыдущие слои изменились.
# https://docs.docker.com/reference/dockerfile/#copy---link
COPY --link --from=ghcr.io/astral-sh/uv:0.7.21 /uv /usr/local/bin/uv

COPY wait-for-psql.py /usr/local/bin/wait-for-psql.py

# Install rtlcss (on Debian buster)
RUN npm install -g rtlcss

# Install Odoo
ENV ODOO_VERSION="17.0" \
    DIR_PROJECT="_project"

# Set permissions and Mount /var/lib/odoo to allow restoring filestore and /mnt/extra-addons for users addons
RUN chown odoo /etc/odoo/odoo.conf \
    && mkdir -p /mnt/extra-addons \
    && chown -R odoo /mnt/extra-addons
VOLUME ["/var/lib/odoo", "/mnt/extra-addons"]

# Set the default config file
ENV ODOO_RC=/etc/odoo/odoo.conf

USER odoo
WORKDIR /home/odoo
COPY --link --chown=odoo:odoo vendor vendor
#COPY src src

# Загружаем нужные репы odoo из OCA
RUN --mount=type=cache,destination=~/.cache/gitlab <<EOF
    git clone https://github.com/OCA/OCB.git --branch 17.0 vendor/OCA/OCB
    git clone https://github.com/OCA/web.git --branch 17.0 vendor/OCA/web
    git clone https://github.com/OCA/website.git --branch 17.0 vendor/OCA/website
    git clone https://github.com/OCA/reporting-engine.git --branch 17.0 vendor/OCA/reporting-engine
    git clone https://github.com/OCA/multi-company.git --branch 17.0 vendor/OCA/multi-company
    git clone https://github.com/OCA/contract.git --branch 17.0 vendor/OCA/contract
    git clone https://github.com/OCA/knowledge.git --branch 17.0 vendor/OCA/knowledge
EOF

# Задаём переменные окружения.
# UV_PYTHON — фиксирует версию Python.
# UV_PYTHON_DOWNLOADS — отключает автоматическую загрузку отсутствующих версий Python.
# UV_PROJECT_ENVIRONMENT — указывает путь к виртуальному окружению Python.
# UV_LINK_MODE — меняет способ установки пакетов из глобального кэша.
#   Вместо создания жёстких ссылок, файлы пакета копируются в директорию  виртуального окружения `site-packages`.
#   Это необходимо для будущего копирования изолированной `/app` директории из  стадии `build` в финальный Docker-образ.
# UV_COMPILE_BYTECODE — включает компиляцию файлов Python в байт-код после установки.
# https://docs.astral.sh/uv/configuration/environment/
# PYTHONOPTIMIZE — убирает инструкции `assert` и код, зависящий от значения  константы `__debug__`,
#   при компиляции файлов Python в байт-код.
# https://docs.python.org/3/using/cmdline.html#environment-variables
ENV UV_PYTHON="python$python_version" \
    UV_PROJECT_ENVIRONMENT=.venv \
    UV_LINK_MODE=copy \
    UV_COMPILE_BYTECODE=1 \
    PYTHONOPTIMIZE=1

# Копируем файлы, необходимые для установки зависимостей без кода проекта, так как обычно зависимости меняются реже кода.
COPY --chown=odoo:odoo pyproject.toml OCB_requirements.txt .

# Для быстрой локальной установки зависимостей монтируем кэш-директорию, в которой будет храниться глобальный кэш uv.
# Первый вызов `uv sync` создаёт виртуальное окружение и устанавливает зависимости без текущего проекта.
# Опция `--frozen` запрещает обновлять `uv.lock` файл.
RUN --mount=type=cache,destination=~/.cache/uv <<EOF
uv sync \
    --no-dev \
    --no-install-project \
EOF

# Переключаемся на интерпретатор из виртуального окружения.
ENV UV_PYTHON=$UV_PROJECT_ENVIRONMENT

# Устанавливаем зависимости для базовых пакетов из vendor.
RUN --mount=type=cache,destination=~/.cache/uv <<EOF 
    uv pip install -r OCB_requirements.txt
    uv pip install -r vendor/OCA/web/requirements.txt
    uv pip install -r vendor/OCA/contract/requirements.txt
    uv pip install -r vendor/OCA/reporting-engine/requirements.txt
EOF
# end

# Выводим информацию о текущем окружении и проверяем работоспособность импорта модуля проекта.
RUN <<EOF
    python --version
    python -I -m site
EOF

USER root

# Доустанавливаем пакеты из vendor
RUN dpkg -i /home/odoo/vendor/OCA/website/pandoc-3.6-1-amd64.deb
RUN dpkg -i /tmp/debs/libssl1.1_1.1.0g-2ubuntu4_amd64.deb
RUN dpkg -i /tmp/debs/wkhtmltox_0.12.5-1.bionic_amd64.deb
RUN rm -f /tmp/debs/*
# end

USER odoo
ENTRYPOINT ["/entrypoint.sh"]

