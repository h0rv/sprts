FROM alpine:3.22 AS build
ARG ZIG_VERSION=0.16.0
RUN apk add --no-cache curl xz
RUN curl -fsSLo /tmp/zig.tar.xz "https://ziglang.org/download/${ZIG_VERSION}/zig-x86_64-linux-${ZIG_VERSION}.tar.xz" \
    && mkdir /opt/zig \
    && tar -xJf /tmp/zig.tar.xz -C /opt/zig --strip-components=1
WORKDIR /src
COPY . .
RUN /opt/zig/zig build -Doptimize=ReleaseSafe

FROM alpine:3.22
RUN apk add --no-cache ca-certificates
COPY --from=build /src/zig-out/bin/sprts /usr/local/bin/sprts
ENV PORT=8080
EXPOSE 8080
USER nobody
ENTRYPOINT ["/usr/local/bin/sprts"]

