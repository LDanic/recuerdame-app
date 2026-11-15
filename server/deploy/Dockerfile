FROM python:3.12-slim
# sqlite3 CLI: lo usa respaldo.sh para la copia en caliente.
RUN apt-get update && apt-get install -y --no-install-recommends sqlite3 \
    && rm -rf /var/lib/apt/lists/*
COPY deploy/requirements.txt /tmp/requirements.txt
RUN pip install --no-cache-dir -r /tmp/requirements.txt
WORKDIR /app
CMD ["uvicorn", "recuerdame.main:app", "--host", "127.0.0.1", "--port", "8791", "--proxy-headers"]
