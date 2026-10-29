# Falco from the official distroless image (Wolfi-based, published as falcosecurity/falco
# since 0.40; the older falcosecurity/falco-distroless repo stopped at 0.39.2)
#
# Build:
#   docker build -t falco:0.45.1 .
#   docker build --build-arg FALCO_VERSION=0.45.1 -t falco .
#
# Run (driver comes from engine.kind in the Falco config; the default, modern_ebpf,
# needs no kernel headers or driver build, kernel >= 5.8):
#   docker run --rm -it --privileged \
#     -v /sys/kernel/tracing:/sys/kernel/tracing:ro \
#     -v /var/run/docker.sock:/host/var/run/docker.sock \
#     -v /proc:/host/proc:ro \
#     -v /etc:/host/etc:ro \
#     falco:0.45.1
#
# Once the k8saudit-aks plugin is enabled, also pass:
#     -e AKS_EVENTHUB_CONNECTION_STRING=... -e AKS_EVENTHUB_NAME=... \
#     -e AKS_BLOB_CONNECTION_STRING=... -e AKS_BLOB_CONTAINER_NAME=... \

ARG FALCO_VERSION=0.45.1

# ---- Stage 1: download rules and install plugins with falcoctl ----
# The Debian flavour of the Falco image ships falcoctl (the distroless one doesn't).
# Pulled for the build host so this stage runs natively.
FROM --platform=$BUILDPLATFORM docker.io/falcosecurity/falco:${FALCO_VERSION}-debian AS fetch

ARG TARGETOS
ARG TARGETARCH

# Rulesets from https://github.com/falcosecurity/rules, pinned to release tags
ARG FALCO_RULES_VERSION=5.2.0
ARG FALCO_INCUBATING_RULES_VERSION=6.0.1
ARG FALCO_SANDBOX_RULES_VERSION=6.2.0

# Plugins from https://github.com/falcosecurity/plugins, pinned to release tags
# (disabled for now, uncomment together with the matching lines below)
# ARG K8SAUDIT_AKS_PLUGIN_VERSION=0.6.0
# ARG JSON_PLUGIN_VERSION=0.7.4
# ARG K8SAUDIT_RULES_VERSION=0.18.0

ARG REGISTRY=ghcr.io/falcosecurity

# k8saudit-aks reads AKS audit logs from Azure Event Hub; the k8s audit ruleset
# it uses also needs the json plugin. Every dependency is listed explicitly, so
# falcoctl only checks them (k8saudit-aks satisfies the ruleset's k8saudit
# requirement as an alternative) and the build fails if they don't match.
# --platform selects the plugin build for the target image, not the build host.
# Separate /rules and /plugins dirs keep these apart from the files the Debian
# image already has under /etc/falco and /usr/share/falco/plugins.
RUN mkdir -p /rules /plugins && \
    falcoctl artifact install \
      --platform "${TARGETOS}/${TARGETARCH}" \
      --rulesfiles-dir /rules \
      --plugins-dir /plugins \
      --state-dir /tmp/falcoctl-state \
      # "${REGISTRY}/plugins/ruleset/k8saudit:${K8SAUDIT_RULES_VERSION}" \
      # "${REGISTRY}/plugins/plugin/k8saudit-aks:${K8SAUDIT_AKS_PLUGIN_VERSION}" \
      # "${REGISTRY}/plugins/plugin/json:${JSON_PLUGIN_VERSION}" \
      "${REGISTRY}/rules/falco-rules:${FALCO_RULES_VERSION}" \
      "${REGISTRY}/rules/falco-incubating-rules:${FALCO_INCUBATING_RULES_VERSION}" \
      "${REGISTRY}/rules/falco-sandbox-rules:${FALCO_SANDBOX_RULES_VERSION}"

# ---- Stage 2: official Falco image plus the rules, plugins and local files ----
FROM docker.io/falcosecurity/falco:${FALCO_VERSION}

# Plugins: libk8saudit-aks.so, libjson.so (disabled for now)
# COPY --from=fetch --chmod=644 /plugins/ /usr/share/falco/plugins/

# Stable rules replace the copy bundled with the image; falco.yaml loads
# /etc/falco/falco_rules.yaml first, then the files in /etc/falco/rules.d in
# alphabetical order. The 00-/01-/02- prefixes keep the upstream rulesets ahead
# of the custom rules so those can override or append to them.
COPY --from=fetch --chmod=644 /rules/falco_rules.yaml            /etc/falco/falco_rules.yaml
COPY --from=fetch --chmod=644 /rules/falco-incubating_rules.yaml /etc/falco/rules.d/00-falco-incubating_rules.yaml
COPY --from=fetch --chmod=644 /rules/falco-sandbox_rules.yaml    /etc/falco/rules.d/01-falco-sandbox_rules.yaml
# COPY --from=fetch --chmod=644 /rules/k8s_audit_rules.yaml        /etc/falco/rules.d/02-k8s_audit_rules.yaml

# Custom rules, loaded after the upstream rulesets in filename order
COPY --chmod=644 rules/*.yaml  /etc/falco/rules.d/

# Config overrides, merged into falco.yaml with the append strategy. Disabled
# for now: the only file is the k8saudit-aks setup, which needs the plugins above.
# COPY --chmod=644 config/*.yaml /etc/falco/config.d/

# Expose the embedded webserver (health endpoint on /healthz)
EXPOSE 8765

CMD ["/usr/bin/falco"]
