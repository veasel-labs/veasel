FROM ubuntu:24.04

# Install or copy over any environment dependencies here.

WORKDIR /app
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl python3 \
	&& useradd --create-home --shell /bin/bash veasel \
	&& chown veasel:veasel /app \
	&& rm -rf /var/lib/apt/lists/*
COPY model-fixture/server.py /usr/local/bin/veasel-harbor-model-fixture.py
USER veasel
