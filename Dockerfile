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

# runtime deps: mpich runtime + sshd + small tooling for host discovery
RUN apt-get update && apt-get install -y --no-install-recommends \
    mpich openssh-server ca-certificates dnsutils net-tools iproute2 \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /app
# copy only the binary and needed runtime files
COPY --from=build /src/build/matrix-mul /app/matrix-mul
COPY start.sh /app/start.sh
RUN chmod +x /app/start.sh

EXPOSE 22
ENTRYPOINT ["/app/start.sh"]