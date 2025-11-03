# ---- builder ----
FROM debian:bookworm-slim AS build

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential cmake git ca-certificates mpich libmpich-dev \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /src
COPY . /src

# Release build (strip symbols)
RUN cmake -S . -B build -DCMAKE_BUILD_TYPE=Release && \
    cmake --build build -- -j && \
    strip build/matrix-mul

# ---- runtime ----
FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive

# Install runtime deps: mpich runtime + sshd + small tooling for host discovery
RUN apt-get update && apt-get install -y --no-install-recommends \
        mpich openssh-server ca-certificates dnsutils net-tools iproute2 netcat-openbsd \
      && rm -rf /var/lib/apt/lists/* \
    mkdir /var/run/sshd /root/.ssh

# Generate host SSH keys (for sshd)
RUN ssh-keygen -A

# Generate container's own identity key
RUN ssh-keygen -t rsa -f /root/.ssh/id_rsa -q -N "" && \
    cat /root/.ssh/id_rsa.pub >> /root/.ssh/authorized_keys && \
    chmod 600 /root/.ssh/authorized_keys

# Disable strict host checking
RUN echo "Host *" > /root/.ssh/config && \
    echo "  StrictHostKeyChecking no" >> /root/.ssh/config && \
    echo "  UserKnownHostsFile /dev/null" >> /root/.ssh/config && \
    chmod 600 /root/.ssh/config

# Copy app
WORKDIR /app
# copy only the binary and needed runtime files
COPY --from=build /src/build/matrix-mul /app/matrix-mul
COPY start.sh /app/start.sh
RUN chmod +x /app/start.sh

EXPOSE 22
ENTRYPOINT ["/app/start.sh"]