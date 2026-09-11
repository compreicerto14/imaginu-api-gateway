# Replica o Dockerfile gerado pelo script oficial gcloud_build_image
# (GoogleCloudPlatform/esp-v2/docker/serverless). Com ENDPOINTS_SERVICE_PATH
# definido, o ESPv2 lê a config local e não chama o Service Management no cold start.
ARG ESP_VERSION
FROM gcr.io/endpoints-release/endpoints-runtime-serverless:${ESP_VERSION}

USER root
ENV ENDPOINTS_SERVICE_PATH=/etc/endpoints/service.json
COPY service.json ${ENDPOINTS_SERVICE_PATH}
RUN chown -R envoy:envoy ${ENDPOINTS_SERVICE_PATH} && chmod -R 755 ${ENDPOINTS_SERVICE_PATH}
USER envoy

ENTRYPOINT ["/env_start_proxy.py"]
