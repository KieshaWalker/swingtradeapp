FROM python:3.12-slim AS builder
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir --prefix=/install -r requirements.txt

FROM python:3.12-slim
WORKDIR /app
COPY --from=builder /install /usr/local
COPY . .
# Cloud Run sets PORT; local dev defaults to 8000
ENV PORT=8000
EXPOSE $PORT
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s \
    CMD python -c "import urllib.request,os; urllib.request.urlopen('http://localhost:' + os.environ.get('PORT','8000') + '/health')" || exit 1
CMD ["sh", "-c", "uvicorn main:app --host 0.0.0.0 --port $PORT"]
