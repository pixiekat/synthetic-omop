# Small, pinned Python image for the calibration step.
FROM python:3.12-slim

# Don't write .pyc files, and flush logs immediately so `docker compose run` shows progress.
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Run as non-root.
RUN useradd --create-home calib
USER calib
