# syntax=docker/dockerfile:1

# ---- build stage: compile the React app to static assets ----
FROM node:24-alpine AS build
WORKDIR /app

COPY package.json package-lock.json ./
RUN npm ci

COPY . .
ARG APP_VERSION=dev
ENV APP_VERSION=$APP_VERSION
RUN npm run build

# ---- runtime stage: serve static assets + reverse-proxy /api via nginx ----
FROM nginx:1.27-alpine AS runtime

# Template is rendered at startup by the stock nginx entrypoint
# (/docker-entrypoint.d/20-envsubst-on-templates.sh). Our 15-*.envsh script
# (sourced before it) maps Aspire's service-discovery variable to ${API_URL}.
COPY nginx.conf.template /etc/nginx/templates/default.conf.template
COPY docker-entrypoint.d/15-api-url.envsh /docker-entrypoint.d/15-api-url.envsh
COPY --from=build /app/dist /usr/share/nginx/html

EXPOSE 8080
