# postgres-pitch — Patroni-managed PostgreSQL node image
#
# Built on the official postgres image so we get exact upstream PostgreSQL
# packaging/binaries. Patroni replaces the image's default entrypoint and
# owns initdb, startup, and replication instead.
#
# The container starts as root (not a permanent `USER postgres`) so that
# entrypoint.sh can fix ownership on whatever gets bind-mounted over
# /home/postgres/data at runtime — see entrypoint.sh for why this is
# necessary. gosu then drops to the postgres user before exec'ing
# Patroni, exactly like the official postgres image's own entrypoint does.

ARG POSTGRES_VERSION=16
FROM postgres:${POSTGRES_VERSION}-bookworm

ARG PATRONI_VERSION=4.1.3

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        python3 \
        python3-pip \
        python3-venv \
        curl \
        gosu \
    && rm -rf /var/lib/apt/lists/*

# Patroni lives in its own venv so its pinned dependencies never collide
# with anything apt installs into system Python.
RUN python3 -m venv /opt/patroni \
    && /opt/patroni/bin/pip install --no-cache-dir --upgrade pip \
    && /opt/patroni/bin/pip install --no-cache-dir \
        "patroni[etcd3]==${PATRONI_VERSION}" \
        psycopg2-binary

ENV PATH="/opt/patroni/bin:${PATH}"

COPY patroni/patroni.yml /etc/patroni.yml
COPY patroni/post_bootstrap.sh /home/postgres/post_bootstrap.sh
COPY entrypoint.sh /usr/local/bin/entrypoint.sh

RUN mkdir -p /home/postgres/data \
    && chown -R postgres:postgres /home/postgres \
    && chmod +x /home/postgres/post_bootstrap.sh /usr/local/bin/entrypoint.sh

WORKDIR /home/postgres

# 5432 — PostgreSQL, 8008 — Patroni REST API (health checks, patronictl)
EXPOSE 5432 8008

ENTRYPOINT ["entrypoint.sh"]
CMD ["/etc/patroni.yml"]
