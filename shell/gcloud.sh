#!/usr/bin/env bash
# shell/gcloud.sh — workbench-cloud
# Puts the Google Cloud CLI (installed by `wb tools install gcloud` into
# ~/google-cloud-sdk) on PATH. Tier: env, so later tiers and installed-gcloud
# see it. No Core API calls: the env tier runs before core's are loaded.
if [[ -d "${HOME}/google-cloud-sdk/bin" ]]; then
    case ":${PATH}:" in
        *":${HOME}/google-cloud-sdk/bin:"*) ;;
        *) PATH="${HOME}/google-cloud-sdk/bin:${PATH}"; export PATH ;;
    esac
fi
