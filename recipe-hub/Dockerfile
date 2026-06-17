# Blueberry Recipe Hub — single turnkey image.
#   docker build -t blueberry-recipe-hub .
#   docker run -d -p 8000:8000 -v bbrecipes:/data --name recipes blueberry-recipe-hub
# Then open http://localhost:8000 and register (first account = admin).
FROM python:3.12-slim

# Unprivileged runtime user; data lives in a mounted volume.
RUN useradd -r -u 10001 -d /data hub
WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app.py .
COPY templates ./templates

ENV RECIPE_HUB_DATA=/data PORT=8000
VOLUME ["/data"]
EXPOSE 8000
USER hub

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s \
  CMD python -c "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8000/healthz').read().startswith(b'ok') else 1)"

CMD ["python", "app.py"]
