# Synthea runs on Java 17 (LTS). The upstream project recommends an LTS JDK.
FROM eclipse-temurin:17-jre

ARG SYNTHEA_VERSION=v3.3.0
WORKDIR /synthea

# --chmod needs BuildKit (the default in modern Docker). Remote ADD would
# otherwise save the file as 600 root:root, which only root can read.
# Pull the release jar (bundled with dependencies) for a pinned version.
# VERIFY the asset name on the release page; it has been
# "synthea-with-dependencies.jar" for the 3.x line.
ADD --chmod=0644 https://github.com/synthetichealth/synthea/releases/download/${SYNTHEA_VERSION}/synthea-with-dependencies.jar /synthea/synthea.jar

COPY run.sh /synthea/run.sh
RUN chmod 0755 /synthea/run.sh \
  && useradd --create-home synthea
USER synthea

ENTRYPOINT ["/synthea/run.sh"]
