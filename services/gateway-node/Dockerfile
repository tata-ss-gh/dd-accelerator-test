FROM node:24-alpine
WORKDIR /app
COPY package*.json ./
RUN npm ci --omit=dev
COPY . .
COPY --from=frontend . /frontend
ENV LOG_DIR=/var/log/shoplite DD_SERVICE=gateway DD_LOGS_INJECTION=true DD_RUNTIME_METRICS_ENABLED=true \
    DD_TRACE_MIDDLEWARE_TRACING_ENABLED=false
EXPOSE 3000
# The Datadog tracer is preloaded with -r; DD_AGENT_HOST points it at the Agent container.
CMD ["node", "-r", "dd-trace/init", "server.js"]
