# Non-root nginx image listening on 8080
FROM nginxinc/nginx-unprivileged:1.27-alpine

ARG APP_VERSION=dev
LABEL org.opencontainers.image.title="nginx-cicd-demo" \
      org.opencontainers.image.version="${APP_VERSION}"

COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY html/ /usr/share/nginx/html/

USER root
RUN sed -i "s/__APP_VERSION__/${APP_VERSION}/g" /usr/share/nginx/html/index.html
USER 101

EXPOSE 8080
