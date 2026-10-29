# Falco from the official distroless image (Wolfi-based, published as falcosecurity/falco
# since 0.40; the older falcosecurity/falco-distroless repo stopped at 0.39.2)
#
# Build:
#   docker build -t falco:0.45.1 .
#   docker build --build-arg FALCO_VERSION=0.45.1 -t falco .
#
# Run (modern eBPF driver, no kernel headers or driver build needed; kernel >= 5.8):
#   docker run --rm -it --privileged \
#     -v /sys/kernel/tracing:/sys/kernel/tracing:ro \
#     -v /var/run/docker.sock:/host/var/run/docker.sock \
#     -v /proc:/host/proc:ro \
#     -v /etc:/host/etc:ro \
#     falco:0.45.1

ARG FALCO_VERSION=0.45.1

FROM docker.io/falcosecurity/falco:${FALCO_VERSION}

# Rulesets from https://github.com/falcosecurity/rules, pinned to release tags
ARG FALCO_RULES_VERSION=5.2.0
ARG FALCO_INCUBATING_RULES_VERSION=6.0.1
ARG FALCO_SANDBOX_RULES_VERSION=6.2.0
ARG RULES_BASE_URL=https://raw.githubusercontent.com/falcosecurity/rules

# Stable rules replace the copy bundled with the image; falco.yaml loads
# /etc/falco/falco_rules.yaml first, then the files in /etc/falco/rules.d in
# alphabetical order. The 00-/01- prefixes keep the upstream rulesets ahead of
# the custom rules so those can override or append to them.
ADD --chmod=644 ${RULES_BASE_URL}/falco-rules-${FALCO_RULES_VERSION}/rules/falco_rules.yaml \
    /etc/falco/falco_rules.yaml
ADD --chmod=644 ${RULES_BASE_URL}/falco-incubating-rules-${FALCO_INCUBATING_RULES_VERSION}/rules/falco-incubating_rules.yaml \
    /etc/falco/rules.d/00-falco-incubating_rules.yaml
ADD --chmod=644 ${RULES_BASE_URL}/falco-sandbox-rules-${FALCO_SANDBOX_RULES_VERSION}/rules/falco-sandbox_rules.yaml \
    /etc/falco/rules.d/01-falco-sandbox_rules.yaml

# Custom rules: every rules/*.yaml file next to this Dockerfile, loaded after
# the upstream rulesets in filename order
COPY --chmod=644 rules/*.yaml /etc/falco/rules.d/

# Config overrides (uncomment and add files alongside this Dockerfile)
# COPY config/  /etc/falco/config.d/

# Expose the embedded webserver (health endpoint on /healthz)
EXPOSE 8765

CMD ["/usr/bin/falco", "-o", "engine.kind=modern_ebpf"]
