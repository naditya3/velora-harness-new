# Dockerfile for shopify__liquid - UBUNTU VERSION
# Base image: Ubuntu 24.04 (Noble) with Ruby 3.2.10 development environment
# Multi-architecture support: linux/amd64, linux/arm64
# NOTE: This is an alternative version. Debian version is recommended.

FROM ubuntu:24.04

# Build arguments for multi-architecture support
ARG TARGETPLATFORM
ARG BUILDPLATFORM
ARG TARGETARCH
ARG TARGETOS

# Set environment variables
ENV LANG=C.UTF-8 \
    DEBIAN_FRONTEND=noninteractive \
    RUBY_VERSION=3.2.10 \
    RUBY_DOWNLOAD_URL=https://cache.ruby-lang.org/pub/ruby/3.2/ruby-3.2.10.tar.xz \
    RUBY_DOWNLOAD_SHA256=a64a8a910ac2f28834b2170dedea688f06cbc6431fcd65eb18cc49ddbf3826ae \
    GEM_HOME=/usr/local/bundle \
    BUNDLE_SILENCE_ROOT_WARNING=1 \
    BUNDLE_APP_CONFIG=/usr/local/bundle \
    PATH=/usr/local/bundle/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# Install basic tools and dependencies
RUN set -eux; \
    echo "Building for platform: ${TARGETPLATFORM:-unknown}"; \
    echo "Build platform: ${BUILDPLATFORM:-unknown}"; \
    echo "Target architecture: $(dpkg --print-architecture)"; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        gnupg \
        netbase \
        wget \
    ; \
    rm -rf /var/lib/apt/lists/*

# Install version control and process tools
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        git \
        mercurial \
        openssh-client \
        subversion \
        procps \
    ; \
    rm -rf /var/lib/apt/lists/*

# Install build dependencies and development libraries
RUN set -ex; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        autoconf \
        automake \
        bzip2 \
        libmysqlclient-dev \
        dpkg-dev \
        file \
        g++ \
        gcc \
        imagemagick \
        libbz2-dev \
        libc6-dev \
        libcurl4-openssl-dev \
        libdb-dev \
        libevent-dev \
        libffi-dev \
        libgdbm-dev \
        libglib2.0-dev \
        libgmp-dev \
        libjpeg-dev \
        libkrb5-dev \
        liblzma-dev \
        libmagickcore-dev \
        libmagickwand-dev \
        libmaxminddb-dev \
        libncurses5-dev \
        libncursesw5-dev \
        libpng-dev \
        libpq-dev \
        libreadline-dev \
        libsqlite3-dev \
        libssl-dev \
        libtool \
        libwebp-dev \
        libxml2-dev \
        libxslt1-dev \
        libyaml-dev \
        make \
        patch \
        unzip \
        xz-utils \
        zlib1g-dev \
    ; \
    rm -rf /var/lib/apt/lists/*

# Configure gem to skip documentation
RUN set -eux; \
    mkdir -p /usr/local/etc; \
    echo 'gem: --no-document' >> /usr/local/etc/gemrc

# Build and install Ruby from source with YJIT support
RUN set -eux; \
    savedAptMark="$(apt-mark showmanual)"; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        bison \
        dpkg-dev \
        libgdbm-dev \
        ruby \
    ; \
    \
    # Install Rust for YJIT support
    rustArch=; \
    dpkgArch="$(dpkg --print-architecture)"; \
    case "$dpkgArch" in \
        'amd64') \
            rustArch='x86_64-unknown-linux-gnu'; \
            rustupUrl='https://static.rust-lang.org/rustup/archive/1.28.2/x86_64-unknown-linux-gnu/rustup-init'; \
            rustupSha256='20a06e644b0d9bd2fbdbfd52d42540bdde820ea7df86e92e533c073da0cdd43c' \
            ;; \
        'arm64') \
            rustArch='aarch64-unknown-linux-gnu'; \
            rustupUrl='https://static.rust-lang.org/rustup/archive/1.28.2/aarch64-unknown-linux-gnu/rustup-init'; \
            rustupSha256='e3853c5a252fca15252d07cb23a1bdd9377a8c6f3efa01531109281ae47f841c' \
            ;; \
    esac; \
    \
    if [ -n "$rustArch" ]; then \
        mkdir -p /tmp/rust; \
        wget -O /tmp/rust/rustup-init "$rustupUrl"; \
        echo "$rustupSha256 */tmp/rust/rustup-init" | sha256sum --check --strict; \
        chmod +x /tmp/rust/rustup-init; \
        export RUSTUP_HOME='/tmp/rust/rustup' CARGO_HOME='/tmp/rust/cargo'; \
        export PATH="$CARGO_HOME/bin:$PATH"; \
        /tmp/rust/rustup-init -y --no-modify-path --profile minimal --default-toolchain '1.91.1' --default-host "$rustArch"; \
        rustc --version; \
        cargo --version; \
    fi; \
    \
    # Download and extract Ruby
    wget -O ruby.tar.xz "$RUBY_DOWNLOAD_URL"; \
    echo "$RUBY_DOWNLOAD_SHA256 *ruby.tar.xz" | sha256sum --check --strict; \
    mkdir -p /usr/src/ruby; \
    tar -xJf ruby.tar.xz -C /usr/src/ruby --strip-components=1; \
    rm ruby.tar.xz; \
    \
    # Build Ruby
    cd /usr/src/ruby; \
    autoconf; \
    gnuArch="$(dpkg-architecture --query DEB_BUILD_GNU_TYPE)"; \
    ./configure \
        --build="$gnuArch" \
        --disable-install-doc \
        --enable-shared \
        ${rustArch:+--enable-yjit} \
    ; \
    make -j "$(nproc)"; \
    make install; \
    \
    # Cleanup
    rm -rf /tmp/rust; \
    apt-mark auto '.*' > /dev/null; \
    apt-mark manual $savedAptMark > /dev/null; \
    find /usr/local -type f -executable -not \( -name '*tkinter*' \) -exec ldd '{}' ';' \
        | awk '/=>/ { so = $(NF-1); if (index(so, "/usr/local/") == 1) { next }; gsub("^/(usr/)?", "", so); printf "*%s\n", so }' \
        | sort -u \
        | xargs -r dpkg-query --search \
        | awk 'sub(":$", "", $1) { print $1 }' \
        | sort -u \
        | xargs -r apt-mark manual \
    ; \
    apt-get purge -y --auto-remove -o APT::AutoRemove::RecommendsImportant=false; \
    rm -rf /var/lib/apt/lists/*; \
    \
    cd /; \
    rm -r /usr/src/ruby; \
    \
    # Verify Ruby installation
    if dpkg -l | grep -i ruby; then exit 1; fi; \
    [ "$(command -v ruby)" = '/usr/local/bin/ruby' ]; \
    ruby --version; \
    gem --version; \
    bundle --version

# Setup bundler directory
RUN set -eux; \
    mkdir "$GEM_HOME"; \
    chmod 1777 "$GEM_HOME"

# Create working directory for repository code
RUN mkdir -p /app/repo

# Set working directory
WORKDIR /app/repo

# Default command - keep container running
CMD ["sleep", "infinity"]
