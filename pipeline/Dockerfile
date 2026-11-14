FROM ghcr.io/osgeo/gdal:ubuntu-small-3.13.3@sha256:64250faf833c06d4b21afce4c27190039ba7ab58d70f0eebc87cf77d929c0b40
# Lets our own dead images be pruned by label without touching anyone else's.
LABEL app=chartpipe

# osmium-tool cuts the airport detail out of the OpenStreetMap extract. poppler-utils reads the airport diagrams' printed latitude and longitude labels and draws the page.
RUN apt-get update && apt-get install -y --no-install-recommends python3-pip git curl unzip ca-certificates poppler-utils osmium-tool \
    && rm -rf /var/lib/apt/lists/*

# pmtiles CLI
RUN arch=$(uname -m | sed 's/aarch64/arm64/') \
    && curl -fsSL "https://github.com/protomaps/go-pmtiles/releases/download/v1.31.2/go-pmtiles_1.31.2_Linux_${arch}.tar.gz" \
       | tar -xz -C /usr/local/bin pmtiles

# Chart outlines, pinned. Fetched here so they are never stored in this repo.
RUN git clone -q https://github.com/n129bz/chartmaker /tmp/chartmaker \
    && git -C /tmp/chartmaker checkout -q 1d71db443916b8052dde41d612c3311bac25a5ae \
    && mkdir -p /opt/outlines \
    && cp -r /tmp/chartmaker/clipshapes/sectional /tmp/chartmaker/clipshapes/terminal \
             /tmp/chartmaker/clipshapes/enroute_low /opt/outlines/ \
    && cp /tmp/chartmaker/LICENSE /opt/outlines/LICENSE \
    && rm -rf /tmp/chartmaker

# US state boundaries (public domain, US Census Bureau)
RUN mkdir -p /opt/states && cd /opt/states \
    && curl -fsSL -o s.zip https://www2.census.gov/geo/tiger/GENZ2023/shp/cb_2023_us_state_500k.zip \
    && unzip -q s.zip && rm s.zip

# Vector tile builder, pinned to a release tag.
RUN apt-get update && apt-get install -y --no-install-recommends build-essential libsqlite3-dev zlib1g-dev \
    && git clone -q --depth 1 --branch 2.79.0 https://github.com/felt/tippecanoe /tmp/tippecanoe \
    && make -C /tmp/tippecanoe -j"$(nproc)" \
    && make -C /tmp/tippecanoe install \
    && rm -rf /tmp/tippecanoe /var/lib/apt/lists/*

WORKDIR /app
COPY requirements.txt .
RUN pip3 install --no-cache-dir --break-system-packages -r requirements.txt
COPY chartpipe chartpipe
COPY navpipe navpipe
COPY tppipe tppipe
COPY wxpipe wxpipe
COPY tests tests
ENTRYPOINT ["python3", "-m", "chartpipe"]
