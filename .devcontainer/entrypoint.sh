#!/bin/bash
set -e

function print_info() {
    echo -e "\e[36mINFO: ${1}\e[m"
}

if [ -n "${INPUT_REQUIREMENTS}" ] && [ -f "${INPUT_REQUIREMENTS}" ]; then
      pip install -r ${INPUT_REQUIREMENTS}
fi

if [ -n "${INPUT_MKDOCS_VERSION}" ]; then
    if [ ! "${INPUT_MKDOCS_VERSION}" == "latest" ]; then
        poetry add mkdocs==${INPUT_MKDOCS_VERSION}
    fi
fi

if [ -n "${INPUT_CONFIGFILE}" ]; then
    print_info "Setting custom path for mkdocs config yml"
    export CONFIG_FILE="${INPUT_CONFIGFILE}"
else
    export CONFIG_FILE="mkdocs.yml"
fi

mkdocs build --config-file ${CONFIG_FILE}