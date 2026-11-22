# syntax=docker/dockerfile:1
# Patch the distro packages before splitting the build and runtime stages.
FROM python:3.12-alpine3.24 AS base
RUN apk upgrade --no-cache && apk add --no-cache libstdc++

# --- build stage: install dependencies into a virtualenv ---
FROM base AS build
WORKDIR /build
RUN apk add --no-cache build-base
RUN python -m venv /venv
COPY requirements.txt .
RUN /venv/bin/pip install --no-cache-dir -r requirements.txt

# --- runtime stage: only the venv + the app, running as non-root ---
FROM base AS runtime
ENV PATH="/venv/bin:$PATH" \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1
RUN adduser -D -u 10001 app
WORKDIR /app
COPY --from=build /venv /venv
COPY app ./app
RUN mkdir -p /app/data/uploads && chown -R app:app /app/data
USER app
EXPOSE 8000
HEALTHCHECK --interval=15s --timeout=3s --start-period=20s --retries=3 \
  CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/healthz', timeout=2)" || exit 1
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000", "--timeout-graceful-shutdown", "10"]
