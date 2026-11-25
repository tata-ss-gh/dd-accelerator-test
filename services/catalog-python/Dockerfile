FROM python:3.13-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app.py .
ENV LOG_DIR=/var/log/shoplite DD_SERVICE=catalog DD_LOGS_INJECTION=true DD_RUNTIME_METRICS_ENABLED=true
EXPOSE 8001
# ddtrace-run loads the Datadog tracer before the app starts.
CMD ["ddtrace-run", "uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8001"]
