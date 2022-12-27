FROM tiryoh/mkdocs-builder:debian

# Copy only requirements to cache them in docker layer

# Install system deps
RUN apt-get update && \
    apt-get install --no-install-recommends -y \
    libcairo2 gnupg2 && \
    apt-get purge -y curl && \
    apt-get purge -y --auto-remove -o APT::AutoRemove::RecommendsImportant=false && \
    apt-get clean -y && \
    rm -rf rm -rf /var/lib/apt/lists/*

# Set working directory
WORKDIR /docs

# Initialize project
RUN poetry install \
    --no-interaction --no-ansi

COPY ./entrypoint.sh /entrypoint.sh
ENTRYPOINT ["/bin/bash ./devcontainer/entrypoint.sh"]