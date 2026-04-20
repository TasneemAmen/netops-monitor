FROM python:3.11-alpine

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

# Security: non-root user
RUN adduser -D appuser
USER appuser

EXPOSE 5000

CMD ["python", "app.py"]
