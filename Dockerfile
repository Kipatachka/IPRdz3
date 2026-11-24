FROM python:3.13-slim
WORKDIR /app
COPY app/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app/app.py .
RUN groupadd --gid 67 appuser && useradd --uid 67 --gid appuser --create-home appuser
USER appuser
CMD ["python", "app.py"]