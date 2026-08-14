FROM python:3.12-slim

WORKDIR /srv/relay
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY . .

ENV RELAY_JWT_SECRET=change-me-in-production
ENV RELAY_DB=/data/relay.db

EXPOSE 8000
CMD ["python", "main.py"]
