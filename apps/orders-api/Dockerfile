# Distroless python: no shell or package manager at runtime, runs as non-root 65532; the builder stage must use the same Python minor version (3.13).
FROM python:3.13.18-slim-trixie AS builder
ARG PIP_INDEX_URL
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir --target /deps -r requirements.txt

FROM gcr.io/distroless/python3-debian13:nonroot@sha256:6c4cb3bfa4b555429dd19541796a6ba6b30c84675b460bd0bd5072f7d5bdae71
ENV PYTHONPATH=/deps PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
WORKDIR /app
COPY --from=builder /deps /deps
COPY main.py .
USER 65532:65532
EXPOSE 8080
CMD ["-m", "uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8080"]
